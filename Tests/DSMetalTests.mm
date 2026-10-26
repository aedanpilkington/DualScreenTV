#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <cassert>
#include <vector>
#include <cstdio>
#include <cstring>
struct Span { uint32_t x,end,attr,flags,texture; float coord[4],delta[4],color[4],colorDelta[4]; };
struct Texture { uint32_t offset,width,height,wrap,originalWidth,originalHeight; };
struct Pixel { uint32_t color,depth,attrs; };
struct Config { uint32_t width,height,color,depth,attrs,wbuffer,alphaTest,alphaRef,blend,highlight,samplingHack,clearImage,toon[32],edgeEnabled,fogEnabled,fogAlpha,clearDepth,clearOpaque,fogColor,edge[8]; };
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);
    NSError *error=nil;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error]; assert(source);
    MTLCompileOptions *options=[MTLCompileOptions new]; options.fastMathEnabled=NO;
    id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
    if (!library) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
    auto pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"raster"] error:&error]; assert(pipeline);
    auto queue=[device newCommandQueue];
    auto run=[&](Config cfg,std::vector<Span> spans,std::vector<Texture> textures,std::vector<uint32_t> texels,std::vector<Pixel> initial,bool process=false) {
        struct Range { uint32_t start,count; };
        const size_t count=size_t(cfg.width)*cfg.height;
        std::vector<Range> ranges(cfg.height*(cfg.width/32),{0,(uint32_t)spans.size()});
        std::vector<uint32_t> indices;
        for (unsigned i=0;i<spans.size();++i) indices.push_back(i);
        if(indices.empty()) indices.push_back(0);
        if(spans.empty()) spans.push_back({});
        if(textures.empty()) textures.push_back({});
        if(texels.empty()) texels.push_back(0);
        initial.resize(count);
        id<MTLBuffer> b[6]={
            [device newBufferWithBytes:spans.data() length:spans.size()*sizeof(Span) options:MTLResourceStorageModeShared],
            [device newBufferWithBytes:ranges.data() length:ranges.size()*sizeof(Range) options:MTLResourceStorageModeShared],
            [device newBufferWithBytes:indices.data() length:indices.size()*4 options:MTLResourceStorageModeShared],
            [device newBufferWithBytes:textures.data() length:textures.size()*sizeof(Texture) options:MTLResourceStorageModeShared],
            [device newBufferWithBytes:texels.data() length:texels.size()*4 options:MTLResourceStorageModeShared],
            [device newBufferWithBytes:initial.data() length:initial.size()*sizeof(Pixel) options:MTLResourceStorageModeShared]};
        auto command=[queue commandBuffer]; auto encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        for(unsigned i=0;i<6;++i) [encoder setBuffer:b[i] offset:0 atIndex:i];
        [encoder setBytes:&cfg length:sizeof(cfg) atIndex:6];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
        [encoder endEncoding];
        id<MTLBuffer> finalColor=nil;
        if(process) {
            std::vector<uint8_t> fog(32768,64);
            auto fogBuffer=[device newBufferWithBytes:fog.data() length:fog.size() options:MTLResourceStorageModeShared];
            finalColor=[device newBufferWithLength:count*4 options:MTLResourceStorageModeShared];
            auto postPipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"postprocess"] error:&error]; assert(postPipeline);
            auto post=[command computeCommandEncoder];
            [post setComputePipelineState:postPipeline];
            [post setBuffer:b[5] offset:0 atIndex:0]; [post setBuffer:finalColor offset:0 atIndex:1];
            [post setBuffer:fogBuffer offset:0 atIndex:2]; [post setBytes:&cfg length:sizeof(cfg) atIndex:3];
            [post dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
            [post endEncoding];
        }
        [command commit]; [command waitUntilCompleted];
        assert(command.status==MTLCommandBufferStatusCompleted);
        auto p=(const Pixel*)b[5].contents;
        std::vector<Pixel> result(p,p+count);
        if(process) for(size_t i=0;i<count;++i) result[i].color=((const uint32_t*)finalColor.contents)[i];
        return result;
    };
    Config cfg={};cfg.width=256;cfg.height=192;cfg.depth=0xffffff;cfg.attrs=255<<8;cfg.blend=1;
    Span red={};red.end=256;red.attr=(31<<16)|(1<<24);red.flags=1;red.coord[2]=0.5;red.coord[3]=1;red.color[0]=63;
    auto out=run(cfg,{red},{},{},{});
    for(auto p:out) { assert(p.color==0x1f00003f); assert((p.attrs&255)==1); }
    Span blue=red;blue.color[0]=0;blue.color[2]=63;blue.attr=(15<<16)|(2<<24);blue.coord[2]=0.25;
    out=run(cfg,{red,blue,blue},{},{},{});
    assert(out[0].color==0x1f1f001f); // Half-alpha blue, duplicate translucent ID rejected.
    cfg.alphaTest=1;cfg.alphaRef=16;
    out=run(cfg,{red,blue},{},{},{});assert(out[0].color==0x1f00003f);
    cfg.alphaTest=0;
    blue.attr=(31<<16)|(2<<24);blue.coord[2]=0.75;
    out=run(cfg,{red,blue},{},{},{});assert(out[0].color==0x1f00003f); // Behind red.
    Span mask=blue;mask.attr=3<<4;mask.flags=3;
    blue.attr=(3<<4)|(15<<16)|(2<<24);blue.flags=3;blue.coord[2]=0.25;
    out=run(cfg,{red,mask,blue},{},{},{});assert(out[0].color==0x1f1f001f);
    cfg.wbuffer=1;red.coord[3]=1;
    out=run(cfg,{red},{},{},{});assert(out[0].depth==4096);
    cfg.wbuffer=0;
    Texture tex={0,2,1,1,2,1};
    red.coord[0]=2;red.color[0]=red.color[1]=red.color[2]=63;
    out=run(cfg,{red},{tex},{0x1f003f00,0x1f3f0000},{});assert(out[0].color==0x1f003f00); // Repeat.
    tex.wrap=5;
    out=run(cfg,{red},{tex},{0x1f003f00,0x1f3f0000},{});assert(out[0].color==0x1f3f0000); // Mirrored repeat.
    // DeSmuME's integer decal lookup deliberately divides by 32.
    red.coord[0]=0;red.attr=(31<<16)|(1<<24)|(1<<4);
    tex.wrap=0;
    out=run(cfg,{red},{tex},{0x1f003f00,0},{});assert(out[0].color==0x1f003d00);
    red.attr=(31<<16)|(1<<24)|(2<<4);cfg.toon[31]=0x1f00003f;
    out=run(cfg,{red},{},{},{});assert(out[0].color==0x1f00003f);
    cfg.highlight=1;
    out=run(cfg,{red},{},{},{});assert(out[0].color==0x1f3f3f3f);
    cfg.highlight=0;red.attr=(31<<16)|(1<<24);
    // Equal-depth tolerance and front-facing over opaque back-facing pixels.
    blue=red;blue.color[0]=blue.color[1]=0;blue.color[2]=63;
    blue.attr=(31<<16)|(2<<24)|(1<<14);
    out=run(cfg,{red,blue},{},{},{});assert(out[0].color==0x1f3f0000);
    red.flags=0;blue.attr=(31<<16)|(2<<24);blue.flags=1;
    out=run(cfg,{red,blue},{},{},{});assert(out[0].color==0x1f3f0000);
    red.flags=1;
    cfg.clearImage=1;
    std::vector<Pixel> clear(256*192,{0x1f003f00,0,0});
    out=run(cfg,{red},{},{},clear);assert(out[0].color==0x1f003f00); // Clear-image depth blocks polygon.
    cfg.clearImage=0;
    for(unsigned scale: {1u,2u,3u,4u,6u,8u}) {
        cfg.width=256*scale;cfg.height=192*scale;red.end=cfg.width;
        out=run(cfg,{red},{},{},{});
        assert(out.size()==size_t(cfg.width)*cfg.height);
        assert(out.front().color==0x1f3f3f3f && out.back().color==0x1f3f3f3f);
    }
    cfg.width=256;cfg.height=192;
    cfg.fogEnabled=1;cfg.fogColor=0x1f00003f;
    red.end=256;red.attr|=1<<15;
    out=run(cfg,{red},{},{},{},true);assert(out[0].color==0x1f1f1f3f);
    cfg.fogAlpha=1;
    out=run(cfg,{red},{},{},{},true);assert(out[0].color==0x1f3f3f3f);
    cfg.fogEnabled=0;cfg.edgeEnabled=1;cfg.clearDepth=0;cfg.edge[1]=0x1f003f00;
    red.end=128;red.color[0]=63;red.color[1]=red.color[2]=0;
    blue=red;blue.x=128;blue.end=256;blue.attr=(31<<16)|(8<<24);
    blue.color[0]=0;blue.color[2]=63;
    out=run(cfg,{red,blue},{},{},{},true);
    assert(out[126].color==0x1f00003f && out[127].color==0x1f003f00);
    puts("DS Metal: opaque/translucent depth, alpha test, shadows, texture wrapping, clear images, GPU fog/edges and 1–8x passed");
}}
