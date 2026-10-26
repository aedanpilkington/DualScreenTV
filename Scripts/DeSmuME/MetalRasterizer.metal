// GPL-2.0-or-later. Fragment rules derived from DeSmuME rasterize.cpp.
#include <metal_stdlib>
using namespace metal;
struct Span { uint x, end, attr, flags, texture; float coord[4], delta[4], color[4], colorDelta[4]; };
struct Texture { uint offset, width, height, wrap, originalWidth, originalHeight; };
struct Pixel { uint color, depth, attrs; };
struct Config { uint width, height, color, depth, attrs, wbuffer, alphaTest, alphaRef, blend, highlight, samplingHack, clearImage; uint toon[32]; uint edgeEnabled,fogEnabled,fogAlpha,clearDepth,clearOpaque,fogColor,edge[8]; };
uint4 unpack(uint c) { return uint4(c & 255, (c >> 8) & 255, (c >> 16) & 255, c >> 24); }
uint pack(uint4 c) { return c.x | (c.y << 8) | (c.z << 16) | (c.w << 24); }
uint modulate(uint a, uint b) { return ((a+1)*(b+1)-1)>>6; }
uint expand5(uint a) { return a ? a*2+1 : 0; }
int wrapCoord(int v, uint size, bool repeat, bool mirror) {
    if (!repeat) return clamp(v, 0, int(size)-1);
    if (mirror && (v & int(size))) return int(size)-1-(v & (int(size)-1));
    return v & (int(size)-1);
}
kernel void raster(device const Span *spans [[buffer(0)]],
                   device const uint2 *ranges [[buffer(1)]],
                   device const uint *indices [[buffer(2)]],
                   device const Texture *textures [[buffer(3)]],
                   device const uint *texels [[buffer(4)]],
                   device Pixel *pixels [[buffer(5)]],
                   constant Config &cfg [[buffer(6)]], uint p [[thread_position_in_grid]]) {
    if (p >= cfg.width * cfg.height) return;
    uint x = p % cfg.width, y = p / cfg.width;
    uint4 dst = unpack(cfg.clearImage ? pixels[p].color : cfg.color);
    uint depth = cfg.clearImage ? pixels[p].depth : cfg.depth, a = cfg.clearImage ? pixels[p].attrs : cfg.attrs;
    uint opaqueID = a & 255, transID = (a>>8)&255, stencil=(a>>16)&1;
    uint fog=(a>>17)&1, translucent=(a>>18)&1, facing=(a>>19)&3;
    uint2 range = ranges[y * (cfg.width / 32) + x / 32];
    for (uint k = 0; k < range.y; ++k) {
        Span s = spans[indices[range.x+k]];
        if (x < s.x || x >= s.end) continue;
        float n = float(x-s.x);
        // Geometry/coverage remains the established CPU scan converter.
        float u = s.coord[0]+s.delta[0]*n, v=s.coord[1]+s.delta[1]*n;
        float z = s.coord[2]+s.delta[2]*n, iw=s.coord[3]+s.delta[3]*n;
        float w = 1.0f / iw;
        uint newDepth = cfg.wbuffer ? uint(w*4096.0f) : uint(z*4194303.0f)<<2;
        uint polyID=(s.attr>>24)&63, mode=(s.attr>>4)&3, alpha=(s.attr>>16)&31;
        bool front=s.flags&1, shadow=s.flags&2;
        bool fail;
        if (s.attr & (1<<14)) fail = newDepth < uint(max(0,int(depth)-255)) || newDepth > min(0xffffffu,depth+255);
        else if (front && facing==2 && dst.w==31) fail=newDepth>depth;
        else fail=newDepth>=depth;
        if (fail) { if (shadow && polyID==0) stencil=1; continue; }
        if (shadow) {
            if (polyID==0 || !stencil || opaqueID==polyID) continue;
            stencil=0;
        }
        uint4 src = uint4(uint3(clamp(float3(s.color[0]+s.colorDelta[0]*n,
                         s.color[1]+s.colorDelta[1]*n,s.color[2]+s.colorDelta[2]*n)*w+0.5f,0.0f,63.0f)),alpha);
        uint4 out=src;
        if (!shadow && mode!=3) {
            Texture t = textures[s.texture];
            uint4 tex=uint4(63,63,63,31);
            bool sampled=t.width!=0;
            if (sampled) {
                float2 uv=float2(u,v)*w*float2(t.width,t.height)/float2(t.originalWidth,t.originalHeight);
                int2 at;
                if (cfg.samplingHack) at=int2(sign(uv)*floor(abs(uv)*256.0f+0.5f)/256.0f);
                else at=int2(floor(uv));
                at.x=wrapCoord(at.x,t.width,t.wrap&1,t.wrap&4);
                at.y=wrapCoord(at.y,t.height,t.wrap&2,t.wrap&8);
                tex=unpack(texels[t.offset+uint(at.y)*t.width+uint(at.x)]);
            }
            if (mode==1) {
                if (sampled) out=uint4((tex.xyz*tex.w+src.xyz*(31-tex.w))>>5,src.w);
            } else {
                uint3 material=src.xyz, added=uint3(0);
                if (mode==2) {
                    uint3 toon=unpack(cfg.toon[src.x>>1]).xyz;
                    if (cfg.highlight) { material=uint3(src.x); added=toon; }
                    else material=toon;
                }
                out=uint4(min(uint3(modulate(tex.x,material.x),modulate(tex.y,material.y),modulate(tex.z,material.z))+added,uint3(63)),
                          modulate(expand5(tex.w),expand5(src.w))>>1);
            }
        }
        if (!out.w || (cfg.alphaTest && out.w<cfg.alphaRef)) continue;
        bool solid=out.w==31;
        uint polyFog=(s.attr>>15)&1;
        if (solid) { opaqueID=polyID; translucent=(s.flags>>2)&1; fog=polyFog; dst=out; }
        else {
            if (transID==polyID) continue;
            transID=polyID;
            if (!dst.w || !cfg.blend) dst=out;
            else { uint alpha=out.w+1; dst=uint4((out.xyz*alpha+dst.xyz*(32-alpha))>>5,max(out.w,dst.w)); }
            fog &= polyFog;
        }
        facing=front?1:2;
        if (solid || (s.attr&(1<<11))) depth=newDepth;
    }
    pixels[p]={pack(dst),depth,opaqueID|(transID<<8)|(stencil<<16)|(fog<<17)|(translucent<<18)|(facing<<19)};
}

kernel void postprocess(device const Pixel *pixels [[buffer(0)]], device uint *colors [[buffer(1)]],
                        device const uchar *fogTable [[buffer(2)]], constant Config &cfg [[buffer(3)]],
                        uint i [[thread_position_in_grid]]) {
    if (i >= cfg.width*cfg.height) return;
    Pixel p=pixels[i]; uint4 color=unpack(p.color);
    uint x=i%cfg.width,y=i/cfg.width, poly=p.attrs&255;
    if (cfg.edgeEnabled && !((p.attrs>>18)&1)) {
        bool outside=(poly!=cfg.clearOpaque && p.depth<cfg.clearDepth);
        bool right=x+1==cfg.width?outside:((pixels[i+1].attrs&255)!=poly && p.depth>=pixels[i+1].depth);
        bool down=y+1==cfg.height?outside:((pixels[i+cfg.width].attrs&255)!=poly && p.depth>=pixels[i+cfg.width].depth);
        bool left=x==0?outside:((pixels[i-1].attrs&255)!=poly && p.depth>=pixels[i-1].depth);
        bool up=y==0?outside:((pixels[i-cfg.width].attrs&255)!=poly && p.depth>=pixels[i-cfg.width].depth);
        uint edgeID=poly;
        if(right) { if(x+1<cfg.width) edgeID=pixels[i+1].attrs&255; }
        else if(down) { if(y+1<cfg.height) edgeID=pixels[i+cfg.width].attrs&255; }
        else if(left) { if(x>0) edgeID=pixels[i-1].attrs&255; }
        else if(up) { if(y>0) edgeID=pixels[i-cfg.width].attrs&255; }
        if(right||down||left||up) {
            uint4 edge=unpack(cfg.edge[edgeID>>3]);
            if(edge.w==31 || !color.w) color=edge;
            else { uint alpha=edge.w+1; color=uint4((edge.xyz*alpha+color.xyz*(32-alpha))>>5,max(edge.w,color.w)); }
        }
    }
    if(cfg.fogEnabled) {
        uint f=((p.attrs>>17)&1)?fogTable[min(p.depth>>9,32767u)]:0;
        uint4 fog=unpack(cfg.fogColor);
        if(!cfg.fogAlpha) color.xyz=((128-f)*color.xyz+fog.xyz*f)>>7;
        color.w=((128-f)*color.w+fog.w*f)>>7;
    }
    colors[i]=pack(color);
}
