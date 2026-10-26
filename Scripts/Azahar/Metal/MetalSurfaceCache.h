// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <optional>
namespace AzaharMetal {
// Deliberately one owner: colour/depth planes of the retained framebuffer.
// No independently mutable aliases. Snapshots are immutable draw resources.
struct SurfaceRange {
    uint64_t address=0, bytes=0;
    bool CoveredBy(uint64_t start,uint64_t size) const {
        return bytes && size && start<=address && address-start<=size && bytes<=size-(address-start);
    }
    bool Overlaps(uint64_t start,uint64_t size) const {
        return bytes && size && start<address+bytes && address<start+size;
    }
};
struct SurfaceMetadata {
    SurfaceRange range;
    unsigned width=0,height=0,bytesPerPixel=0,format=0;
    bool tiled=true;
};
struct SurfaceAlias { unsigned x,y,width,height; bool depth; };
struct SurfaceOwner {
    SurfaceMetadata color,depth;
    uint64_t generation=0;
    // Conservative whole-plane dirty intervals. Partial masks retain the other
    // components from the imported image; CPU writes resolve before modifying RAM.
    SurfaceRange dirtyColor,dirtyDepth,dirtyStencil;
    bool valid=false;
    std::optional<SurfaceAlias> FindRGBA8(uint64_t address,unsigned width,unsigned height) const {
        if(!valid || !width || !height || width>4096 || height>4096 || width%8 || height%8 || color.range.Overlaps(depth.range.address,depth.range.bytes))return {};
        for(unsigned plane=0;plane<2;++plane) {
            const auto& s=plane?depth:color;
            // RGBA8 colour or D24S8 byte reinterpretation only (framebuffer enums).
            if(!s.tiled || s.bytesPerPixel!=4 || s.format!=(plane?3u:0u) || !s.width ||
               address<s.range.address || uint64_t(width)*height*4>s.range.bytes ||
               address-s.range.address>s.range.bytes-uint64_t(width)*height*4)continue;
            const auto offset=address-s.range.address;
            if(offset%256)continue; // Complete 8x8 Morton tiles.
            const auto pixel=offset/4;
            const unsigned x=(pixel%(uint64_t(s.width)*8))/8;
            const unsigned y=(pixel/(uint64_t(s.width)*8))*8;
            if((width!=s.width && height>8) || uint64_t(x)+width>s.width || uint64_t(y)+height>s.height)continue;
            return SurfaceAlias{x,y,width,height,bool(plane)};
        }
        return {};
    }
    // Display transfers use input width as tiled stride but sample only the
    // output footprint. A nominal 256x512 input at row 112 may read 240x400.
    std::optional<SurfaceAlias> FindColorTransfer(uint64_t address,unsigned stride,unsigned width,unsigned height,unsigned bytesPerPixel,unsigned format) const {
        const auto& s=color;
        if(!valid || !s.tiled || !width || !height || !bytesPerPixel || s.bytesPerPixel!=bytesPerPixel ||
           s.format!=format || stride!=s.width || address<s.range.address || address-s.range.address>=s.range.bytes ||
           color.range.Overlaps(depth.range.address,depth.range.bytes))return {};
        const auto offset=address-s.range.address;
        if(offset%(64*bytesPerPixel))return {};
        const auto pixel=offset/bytesPerPixel;
        const unsigned x=(pixel%(uint64_t(stride)*8))/8,y=(pixel/(uint64_t(stride)*8))*8;
        if(uint64_t(x)+width>s.width || uint64_t(y)+height>s.height)return {};
        return SurfaceAlias{x,y,width,height,false};
    }
    bool Overlaps(uint64_t address,uint64_t size) const {
        return valid && (color.range.Overlaps(address,size)||depth.range.Overlaps(address,size));
    }
    void Invalidate() { valid=false;dirtyColor={};dirtyDepth={};dirtyStencil={}; }
};
}
