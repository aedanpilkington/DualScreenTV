// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cstring>
#include <span>
#include <vector>
#include "common/color.h"
#include "video_core/pica/regs_external.h"
namespace AzaharMetal::Scanout {
struct Cache {
    std::vector<u8> original;
    unsigned lastWidth=0,lastHeight=0,lastFormat=0;
    std::array<u8,4> lastFill{};
    bool valid=false,filled=false;
    uint64_t decodes=0,hits=0;
    bool Update(std::span<u8> output,const u8* source,size_t sourceBytes,unsigned width,unsigned height,
                Pica::PixelFormat format,bool fill,std::array<u8,4> fillColor) {
        if(!width || !height || width>4096 || height>4096 || output.size()!=size_t(width)*height*4) {valid=false;return false;}
        const unsigned f=unsigned(format);
        if(f>=5) {valid=false;return false;}
        const unsigned bpp=f==0?4:f==1?3:2;
        // Preserve the pinned renderer's exact coordinate convention, including
        // the next-row pixel at x=0; do not fold a visual correction into this.
        const size_t required=(size_t(width)*height+1)*bpp;
        if(!fill && (!source || sourceBytes<required)) {valid=false;return false;}
        const bool same=valid && width==lastWidth && height==lastHeight && f==lastFormat && fill==filled;
        if(same && (fill?fillColor==lastFill:original.size()==required-bpp && std::memcmp(original.data(),source+bpp,required-bpp)==0)) {++hits;return true;}
        if(fill) {
            for(size_t i=0;i<output.size();i+=4)std::memcpy(output.data()+i,fillColor.data(),4);
        } else {
            auto decode=[&]<Pica::PixelFormat Format>() {
                constexpr unsigned bytes=Format==Pica::PixelFormat::RGBA8?4:Format==Pica::PixelFormat::RGB8?3:2;
                // A small transpose tile keeps both source and output cache lines
                // hot. Format dispatch happens once rather than for every pixel.
                for(unsigned tx=0;tx<width;tx+=8)for(unsigned ty=0;ty<height;ty+=8)
                for(unsigned x=tx;x<std::min(width,tx+8);++x)for(unsigned y=ty;y<std::min(height,ty+8);++y) {
                    const auto* p=source+(size_t(y)*width+width-x)*bytes;
                    Common::Vec4<u8> c;
                    if constexpr(Format==Pica::PixelFormat::RGBA8)c=Common::Color::DecodeRGBA8(p);
                    if constexpr(Format==Pica::PixelFormat::RGB8)c=Common::Color::DecodeRGB8(p);
                    if constexpr(Format==Pica::PixelFormat::RGB565)c=Common::Color::DecodeRGB565(p);
                    if constexpr(Format==Pica::PixelFormat::RGB5A1)c=Common::Color::DecodeRGB5A1(p);
                    if constexpr(Format==Pica::PixelFormat::RGBA4)c=Common::Color::DecodeRGBA4(p);
                    std::memcpy(output.data()+(size_t(x)*height+y)*4,c.AsArray(),4);
                }
            };
            switch(format) {
            case Pica::PixelFormat::RGBA8:decode.template operator()<Pica::PixelFormat::RGBA8>();break;
            case Pica::PixelFormat::RGB8:decode.template operator()<Pica::PixelFormat::RGB8>();break;
            case Pica::PixelFormat::RGB565:decode.template operator()<Pica::PixelFormat::RGB565>();break;
            case Pica::PixelFormat::RGB5A1:decode.template operator()<Pica::PixelFormat::RGB5A1>();break;
            case Pica::PixelFormat::RGBA4:decode.template operator()<Pica::PixelFormat::RGBA4>();break;
            default:valid=false;return false;
            }
            original.assign(source+bpp,source+required);
        }
        valid=true;filled=fill;lastWidth=width;lastHeight=height;lastFormat=f;lastFill=fillColor;++decodes;
        return true;
    }
};
}
