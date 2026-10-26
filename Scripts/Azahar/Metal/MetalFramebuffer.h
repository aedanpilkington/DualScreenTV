// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalDraw.h"
#include "common/color.h"
#include "video_core/pica/regs_framebuffer.h"
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <optional>
namespace AzaharMetal {
namespace FramebufferTransfer {
using F=Pica::FramebufferRegs;
// Both Metal rows and the guest's tiled storage start at the top. The upstream
// software Framebuffer accessors invert Y, which the old import/export loops
// immediately inverted again. Walk each tile once and specialise formats outside
// the pixel loop, preserving upstream packing and depth/stencil values.
template<class Work> void Tiles(unsigned width,unsigned height,Work&& work) {
    if(!width || !height || width%8 || height%8) throw std::runtime_error("Invalid tiled framebuffer");
    static constexpr auto morton=[] {
        std::array<unsigned,64> result{};
        for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x)
            result[y*8+x]=(x&1)|((y&1)<<1)|((x&2)<<1)|((y&2)<<2)|((x&4)<<2)|((y&4)<<3);
        return result;
    }();
    for(unsigned ty=0;ty<height;ty+=8)for(unsigned tx=0;tx<width;tx+=8) {
        const size_t tile=(size_t(ty)*width+tx*8);
        for(unsigned y=0;y<8;++y)for(unsigned x=0;x<8;++x)
            work((size_t(ty+y)*width+tx+x),tile+morton[y*8+x]);
    }
}
template<class Work> void ColorFormat(F::ColorFormat format,Work&& work) {
    switch(format) {
    case F::ColorFormat::RGBA8: work.template operator()<F::ColorFormat::RGBA8,4>();break;
    case F::ColorFormat::RGB8: work.template operator()<F::ColorFormat::RGB8,3>();break;
    case F::ColorFormat::RGB565: work.template operator()<F::ColorFormat::RGB565,2>();break;
    case F::ColorFormat::RGB5A1: work.template operator()<F::ColorFormat::RGB5A1,2>();break;
    case F::ColorFormat::RGBA4: work.template operator()<F::ColorFormat::RGBA4,2>();break;
    default: throw std::runtime_error("Unsupported colour framebuffer format");
    }
}
template<F::ColorFormat Format> auto Decode(const uint8_t* pixel) {
    if constexpr(Format==F::ColorFormat::RGBA8) return Common::Color::DecodeRGBA8(pixel);
    if constexpr(Format==F::ColorFormat::RGB8) return Common::Color::DecodeRGB8(pixel);
    if constexpr(Format==F::ColorFormat::RGB565) return Common::Color::DecodeRGB565(pixel);
    if constexpr(Format==F::ColorFormat::RGB5A1) return Common::Color::DecodeRGB5A1(pixel);
    if constexpr(Format==F::ColorFormat::RGBA4) return Common::Color::DecodeRGBA4(pixel);
}
template<F::ColorFormat Format> void Encode(const Common::Vec4<u8>& color,uint8_t* pixel) {
    if constexpr(Format==F::ColorFormat::RGBA8) Common::Color::EncodeRGBA8(color,pixel);
    if constexpr(Format==F::ColorFormat::RGB8) Common::Color::EncodeRGB8(color,pixel);
    if constexpr(Format==F::ColorFormat::RGB565) Common::Color::EncodeRGB565(color,pixel);
    if constexpr(Format==F::ColorFormat::RGB5A1) Common::Color::EncodeRGB5A1(color,pixel);
    if constexpr(Format==F::ColorFormat::RGBA4) Common::Color::EncodeRGBA4(color,pixel);
}
template<class Work> void DepthFormat(F::DepthFormat format,Work&& work) {
    switch(format) {
    case F::DepthFormat::D16: work.template operator()<F::DepthFormat::D16,2,65535>();break;
    case F::DepthFormat::D24: work.template operator()<F::DepthFormat::D24,3,16777215>();break;
    case F::DepthFormat::D24S8: work.template operator()<F::DepthFormat::D24S8,4,16777215>();break;
    default: throw std::runtime_error("Unsupported depth framebuffer format");
    }
}
inline std::optional<SurfaceClear> UniformColorFill(F::ColorFormat format,unsigned pattern,uint32_t value) {
    if(pattern<2 || pattern>4)return {};
    std::optional<SurfaceClear> result;
    ColorFormat(format,[&]<auto Format,unsigned Bpp>() {
        if(Bpp%pattern)return;
        std::array<uint8_t,4> bytes{};
        for(unsigned i=0;i<Bpp;++i)bytes[i]=uint8_t(value>>((i%pattern)*8));
        SurfaceClear clear;clear.color=true;const auto color=Decode<Format>(bytes.data());
        std::memcpy(clear.rgba.data(),color.AsArray(),4);result=clear;
    });
    return result;
}
inline std::optional<SurfaceClear> UniformDepthFill(F::DepthFormat format,unsigned pattern,uint32_t value) {
    if(pattern<2 || pattern>4)return {};
    std::optional<SurfaceClear> result;
    DepthFormat(format,[&]<auto Format,unsigned Bpp,unsigned Maximum>() {
        if(Bpp%pattern)return;
        std::array<uint8_t,4> bytes{};
        for(unsigned i=0;i<Bpp;++i)bytes[i]=uint8_t(value>>((i%pattern)*8));
        SurfaceClear clear;clear.depth=true;clear.stencil=Format==F::DepthFormat::D24S8;
        const auto z=Format==F::DepthFormat::D16?Common::Color::DecodeD16(bytes.data()):Common::Color::DecodeD24(bytes.data());
        clear.depthValue=float(z)/Maximum;clear.stencilValue=bytes[3];result=clear;
    });
    return result;
}
inline void Import(Frame& frame,const uint8_t* color,const uint8_t* depth,F::ColorFormat colorFormat,F::DepthFormat depthFormat) {
    const size_t pixels=size_t(frame.width)*frame.height;
    frame.rgba.resize(pixels*4);frame.depth.resize(pixels);frame.stencil.assign(pixels,0);
    ColorFormat(colorFormat,[&]<auto Format,unsigned Bpp>() {
        Tiles(frame.width,frame.height,[&](size_t linear,size_t tiled) {
            const auto value=Decode<Format>(color+tiled*Bpp);
            std::memcpy(frame.rgba.data()+linear*4,value.AsArray(),4);
        });
    });
    DepthFormat(depthFormat,[&]<auto Format,unsigned Bpp,unsigned Maximum>() {
        Tiles(frame.width,frame.height,[&](size_t linear,size_t tiled) {
            const auto* pixel=depth+tiled*Bpp;
            uint32_t value;
            if constexpr(Format==F::DepthFormat::D16) value=Common::Color::DecodeD16(pixel);
            else value=Common::Color::DecodeD24(pixel);
            frame.depth[linear]=float(value)/Maximum;
            if constexpr(Format==F::DepthFormat::D24S8) frame.stencil[linear]=pixel[3];
        });
    });
}
inline void Export(const Frame& frame,uint8_t* color,uint8_t* depth,F::ColorFormat colorFormat,F::DepthFormat depthFormat,bool writeColor,bool writeDepth,bool writeStencil) {
    if(writeColor) ColorFormat(colorFormat,[&]<auto Format,unsigned Bpp>() {
        Tiles(frame.width,frame.height,[&](size_t linear,size_t tiled) {
            const auto* value=frame.rgba.data()+linear*4;
            Encode<Format>({value[0],value[1],value[2],value[3]},color+tiled*Bpp);
        });
    });
    if(writeDepth||writeStencil) DepthFormat(depthFormat,[&]<auto Format,unsigned Bpp,unsigned Maximum>() {
        Tiles(frame.width,frame.height,[&](size_t linear,size_t tiled) {
            auto* pixel=depth+tiled*Bpp;
            if(writeDepth) {
                const auto value=uint32_t(std::clamp(double(frame.depth[linear]),0.0,1.0)*Maximum);
                if constexpr(Format==F::DepthFormat::D16) Common::Color::EncodeD16(value,pixel);
                else Common::Color::EncodeD24(value,pixel);
            }
            if constexpr(Format==F::DepthFormat::D24S8) if(writeStencil) pixel[3]=frame.stencil[linear];
        });
    });
}
}
}
