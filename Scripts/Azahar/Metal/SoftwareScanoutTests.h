// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "SoftwareScanout.h"
#include <random>
#include <stdexcept>
inline void TestSoftwareScanout() {
    using P=Pica::PixelFormat;
    std::mt19937 random(123);
    auto check=[](bool ok,const char* message){if(!ok)throw std::runtime_error(message);};
    for(unsigned f=0;f<5;++f)for(auto [w,h]:{std::pair{8u,8u},std::pair{13u,17u},std::pair{240u,400u},std::pair{247u,321u}}) {
        const unsigned bpp=f==0?4:f==1?3:2;const P format=P(f);
        std::vector<u8> input((size_t(w)*h+1)*bpp);for(auto& c:input)c=u8(random());
        std::vector<u8> actual(size_t(w)*h*4),expected(actual.size());
        AzaharMetal::Scanout::Cache cache;
        auto reference=[&](bool fill,std::array<u8,4> fillColor) {
            for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
                const auto* p=input.data()+(size_t(y)*w+w-x)*bpp;
                Common::Vec4<u8> c;
                if(fill)c={fillColor[0],fillColor[1],fillColor[2],fillColor[3]};
                else switch(format) {
                case P::RGBA8:c=Common::Color::DecodeRGBA8(p);break;
                case P::RGB8:c=Common::Color::DecodeRGB8(p);break;
                case P::RGB565:c=Common::Color::DecodeRGB565(p);break;
                case P::RGB5A1:c=Common::Color::DecodeRGB5A1(p);break;
                case P::RGBA4:c=Common::Color::DecodeRGBA4(p);break;
                }
                std::memcpy(expected.data()+(size_t(x)*h+y)*4,c.AsArray(),4);
            }
        };
        reference(false,{});
        check(cache.Update(actual,input.data(),input.size(),w,h,format,false,{}),"Scanout rejected supported image");
        check(actual==expected,"Tiled scanout differs from pinned pixel traversal");
        const auto count=cache.decodes;
        check(cache.Update(actual,input.data(),input.size(),w,h,format,false,{}) && cache.decodes==count,"Unchanged scanout decoded again");
        input[w*bpp]^=127;reference(false,{});
        check(cache.Update(actual,input.data(),input.size(),w,h,format,false,{}) && actual==expected,"Scanout cache retained stale RAM");
        std::array<u8,4> fill{5,67,89,255};reference(true,fill);
        check(cache.Update(actual,nullptr,0,w,h,format,true,fill) && actual==expected,"LCD fill scanout differs");
        const auto filled=cache.decodes;
        check(cache.Update(actual,nullptr,0,w,h,format,true,fill) && cache.decodes==filled,"Unchanged LCD fill decoded again");
        reference(false,{});check(cache.Update(actual,input.data(),input.size(),w,h,format,false,{}) && actual==expected,"LCD fill disable retained stale image");
        check(!cache.Update(actual,input.data(),1,w,h,format,false,{}),"Truncated scanout input accepted");
        check(!cache.Update(actual,input.data(),input.size(),w,h,P(99),false,{}),"Unknown scanout format accepted");
    }
}
