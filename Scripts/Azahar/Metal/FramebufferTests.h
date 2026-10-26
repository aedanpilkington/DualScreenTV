// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalFramebuffer.h"
#include <random>
namespace AzaharMetal {
inline void TestFramebufferTransfers() {
    using F=Pica::FramebufferRegs;
    auto offset=[](unsigned x,unsigned y,unsigned width,unsigned bpp) {
        unsigned index=0;
        for(unsigned bit=0;bit<3;++bit) { index|=((x>>bit)&1)<<(bit*2);index|=((y>>bit)&1)<<(bit*2+1); }
        return (size_t(y/8)*(width/8)*64+size_t(x/8)*64+index)*bpp;
    };
    std::mt19937 random(12345);
    for(auto [width,height]:{std::pair{8u,8u},{16u,24u},{256u,192u},{256u,256u}})
    for(unsigned format=0;format<5;++format)for(unsigned df:{0u,2u,3u}) {
        const auto cf=F::ColorFormat(format);const auto depthFormat=F::DepthFormat(df);
        const unsigned colorBpp=format==0?4:(format==1?3:2),depthBpp=df==0?2:(df==2?3:4);
        const uint32_t maximum=df==0?65535:16777215;
        std::vector<uint8_t> color(size_t(width)*height*colorBpp),depth(size_t(width)*height*depthBpp);
        for(auto& value:color)value=uint8_t(random());for(auto& value:depth)value=uint8_t(random());
        Frame frame;frame.width=width;frame.height=height;
        FramebufferTransfer::Import(frame,color.data(),depth.data(),cf,depthFormat);
        for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x) {
            const size_t linear=size_t(y)*width+x;
            const auto* pixel=color.data()+offset(x,y,width,colorBpp);
            Common::Vec4<u8> expected;
            switch(cf) {
            case F::ColorFormat::RGBA8:expected=Common::Color::DecodeRGBA8(pixel);break;
            case F::ColorFormat::RGB8:expected=Common::Color::DecodeRGB8(pixel);break;
            case F::ColorFormat::RGB5A1:expected=Common::Color::DecodeRGB5A1(pixel);break;
            case F::ColorFormat::RGB565:expected=Common::Color::DecodeRGB565(pixel);break;
            default:expected=Common::Color::DecodeRGBA4(pixel);break;
            }
            if(std::memcmp(expected.AsArray(),frame.rgba.data()+linear*4,4))throw std::runtime_error("Framebuffer colour import differs from scalar reference");
            const auto* dp=depth.data()+offset(x,y,width,depthBpp);
            const uint32_t z=df==0?Common::Color::DecodeD16(dp):Common::Color::DecodeD24(dp);
            if(frame.depth[linear]!=float(z)/maximum || frame.stencil[linear]!=(df==3?dp[3]:0))throw std::runtime_error("Framebuffer depth/stencil import differs from scalar reference");
        }
        for(auto& value:frame.rgba)value=uint8_t(random());
        for(auto& value:frame.depth)value=float(random()%65536)/65535;
        for(auto& value:frame.stencil)value=uint8_t(random());
        for(unsigned mask=0;mask<8;++mask) {
            auto actualColor=color,actualDepth=depth,expectedColor=color,expectedDepth=depth;
            FramebufferTransfer::Export(frame,actualColor.data(),actualDepth.data(),cf,depthFormat,mask&1,mask&2,mask&4);
            for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x) {
                const size_t linear=size_t(y)*width+x;
                const auto* src=frame.rgba.data()+linear*4;
                const Common::Vec4<u8> value{src[0],src[1],src[2],src[3]};
                auto* pixel=expectedColor.data()+offset(x,y,width,colorBpp);
                if(mask&1) switch(cf) {
                case F::ColorFormat::RGBA8:Common::Color::EncodeRGBA8(value,pixel);break;
                case F::ColorFormat::RGB8:Common::Color::EncodeRGB8(value,pixel);break;
                case F::ColorFormat::RGB5A1:Common::Color::EncodeRGB5A1(value,pixel);break;
                case F::ColorFormat::RGB565:Common::Color::EncodeRGB565(value,pixel);break;
                default:Common::Color::EncodeRGBA4(value,pixel);break;
                }
                auto* dp=expectedDepth.data()+offset(x,y,width,depthBpp);
                if(mask&2) {
                    auto z=uint32_t(std::clamp(double(frame.depth[linear]),0.0,1.0)*maximum);
                    if(df==0)Common::Color::EncodeD16(z,dp);else Common::Color::EncodeD24(z,dp);
                }
                if((mask&4)&&df==3)dp[3]=frame.stencil[linear];
            }
            if(actualColor!=expectedColor || actualDepth!=expectedDepth)throw std::runtime_error("Framebuffer export/write permission differs from scalar reference");
        }
    }
}
}
