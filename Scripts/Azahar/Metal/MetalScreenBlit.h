// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <cstddef>
#include <cstring>
namespace AzaharMetal {
// ScreenInfo's transposed layout is already row-major landscape RGBA. Avoid
// coordinate divisions and per-channel byte stores for the common 1:1 blit.
inline bool BlitExactRGBA(const uint8_t* source,size_t sourceBytes,unsigned width,unsigned height,
    uint8_t* destination,size_t pitch,unsigned canvasHeight,unsigned left,unsigned top,unsigned rectWidth,unsigned rectHeight) {
    if(!source || !destination || !width || !height || width!=rectWidth || height!=rectHeight ||
       sourceBytes<size_t(width)*height*4 || (uint64_t(left)+width)*4>pitch || uint64_t(top)+height>canvasHeight)return false;
    for(unsigned y=0;y<height;++y) {
        const auto* input=source+size_t(y)*width*4;
        auto* output=destination+size_t(top+y)*pitch+size_t(left)*4;
        for(unsigned x=0;x<width;++x) {
            uint32_t rgba;std::memcpy(&rgba,input+size_t(x)*4,4);
            const uint32_t bgra=((rgba&255)<<16)|(rgba&0xff00)|((rgba>>16)&255);
            std::memcpy(output+size_t(x)*4,&bgra,4);
        }
    }
    return true;
}
}
