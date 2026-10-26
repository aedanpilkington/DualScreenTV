// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalDraw.h"
#include <stdexcept>
#include <cstring>
namespace AzaharMetal::Resolution {
inline std::vector<uint8_t> DownsampleRGBA(std::span<const uint8_t> source,unsigned width,unsigned height,unsigned scale,bool flipped=false) {
    if(!scale || width%scale || height%scale || source.size()!=size_t(width)*height*4)throw std::runtime_error("Invalid scaled RGBA surface");
    std::vector<uint8_t> result(size_t(width/scale)*(height/scale)*4);
    const unsigned phaseY=flipped?scale-1-scale/2:scale/2;
    for(unsigned y=0;y<height/scale;++y)for(unsigned x=0;x<width/scale;++x)
        std::memcpy(result.data()+(size_t(y)*(width/scale)+x)*4,source.data()+((size_t(y*scale+phaseY))*width+x*scale+scale/2)*4,4);
    return result;
}
inline void Upscale(Frame& frame,unsigned scale) {
    if(scale==1)return;
    const unsigned width=frame.width,height=frame.height;frame.width*=scale;frame.height*=scale;
    if(frame.rgba.empty())return; // Retained target: metadata only, no CPU copies.
    Frame output;output.width=frame.width;output.height=frame.height;
    const size_t count=size_t(output.width)*output.height;
    output.rgba.resize(count*4);output.depth.resize(count);output.stencil.resize(count);
    for(unsigned y=0;y<output.height;++y)for(unsigned x=0;x<output.width;++x) {
        const size_t src=size_t(y/scale)*width+x/scale,dst=size_t(y)*output.width+x;
        std::memcpy(output.rgba.data()+dst*4,frame.rgba.data()+src*4,4);
        output.depth[dst]=frame.depth[src];output.stencil[dst]=frame.stencil[src];
    }
    frame=std::move(output);
}
inline Frame Downsample(Frame frame,unsigned scale) {
    if(scale==1 || !frame.width || !frame.height)return frame;
    Frame result;result.width=frame.width/scale;result.height=frame.height/scale;
    if(!frame.rgba.empty())result.rgba=DownsampleRGBA(frame.rgba,frame.width,frame.height,scale);
    const size_t count=size_t(result.width)*result.height;
    if(!frame.depth.empty())result.depth.resize(count);
    if(!frame.stencil.empty())result.stencil.resize(count);
    for(unsigned y=0;y<result.height;++y)for(unsigned x=0;x<result.width;++x) {
        const size_t src=size_t(y*scale+scale/2)*frame.width+x*scale+scale/2,dst=size_t(y)*result.width+x;
        if(!result.depth.empty())result.depth[dst]=frame.depth[src];
        if(!result.stencil.empty())result.stencil[dst]=frame.stencil[src];
    }
    return result;
}
}
