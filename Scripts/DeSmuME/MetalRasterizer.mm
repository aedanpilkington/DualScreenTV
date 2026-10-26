// GPL-2.0-or-later. DeSmuME CPU coverage + native Metal fragment renderer.
#import <Metal/Metal.h>
#include "MetalRasterizer.h"
#define BOOL DSTVCoreBOOL
#include "rasterize.h"
#undef BOOL
#include "MetalShaderSource.h"
#include <vector>
#include <unordered_map>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>

namespace {
struct Span { uint32_t x,end,attr,flags,texture; float coord[4],delta[4],color[4],colorDelta[4]; };
struct Texture { uint32_t offset,width,height,wrap,originalWidth,originalHeight; };
struct Range { uint32_t start,count; };
struct Pixel { uint32_t color,depth,attrs; };
struct Config { uint32_t width,height,color,depth,attrs,wbuffer,alphaTest,alphaRef,blend,highlight,samplingHack,clearImage,toon[32],edgeEnabled,fogEnabled,fogAlpha,clearDepth,clearOpaque,fogColor,edge[8]; };
static_assert(sizeof(Span)==84,"Metal span ABI");
static_assert(sizeof(Config)==232,"Metal config ABI");
id<MTLDevice> device;
id<MTLCommandQueue> queue;
id<MTLComputePipelineState> pipeline, postPipeline;
id<MTLBuffer> buffers[8];
std::vector<std::vector<Span>> rows;
std::vector<Span> flatSpans;
std::vector<Range> tileRanges;
std::vector<uint32_t> tileIndices, tileCursors;
std::vector<Texture> textures;
std::vector<uint32_t> texels;
std::vector<Pixel> initial;
Config config;
std::atomic<unsigned> spanCount{0};
std::atomic<bool> overflow{false};
bool recording=false, enabled=true, postProcessed=false, reference=false;
std::atomic<bool> failed{false}, hasRendered{false};

struct Worker {
    std::mutex mutex;
    std::condition_variable condition;
    std::thread thread;
    SoftRasterizerRenderer *renderer=nullptr;
    void (*waitGeometry)(SoftRasterizerRenderer *)=nullptr;
    bool pending=false, busy=false, scheduled=false, stopping=false, result=true;
    void stop() {
        { std::unique_lock<std::mutex> lock(mutex); condition.wait(lock,[&]{return !busy;}); stopping=true; }
        condition.notify_all();
        if(thread.joinable()) thread.join();
    }
    ~Worker() { stop(); }
} worker;

bool initialize() {
    if (!enabled) return false;
    if (failed || (getenv("DSTV_DS_METAL") && !strcmp(getenv("DSTV_DS_METAL"),"0"))) return false;
    if (pipeline) return true;
    device=MTLCreateSystemDefaultDevice(); queue=[device newCommandQueue];
    MTLCompileOptions *options=[MTLCompileOptions new]; options.fastMathEnabled=NO;
    NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:@(dstvMetalShaderSource) options:options error:&error];
    if (library) pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"raster"] error:&error];
    if (library) postPipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"postprocess"] error:&error];
    if (!pipeline || !postPipeline || !queue) {
        printf("DS Metal initialization failed: %s\n",error.localizedDescription.UTF8String);
        failed=true; return false;
    }
    printf("DS Metal fragment renderer initialized: %s\n",device.name.UTF8String);
    fflush(stdout);
    return true;
}

bool upload(unsigned slot, const void *data, size_t bytes) {
    bytes=std::max(bytes,size_t(4));
    if (!buffers[slot] || buffers[slot].length<bytes)
        buffers[slot]=[device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!buffers[slot]) return false;
    if (data) memcpy(buffers[slot].contents,data,bytes);
    return true;
}
}

extern "C" void dstv_desmume_metal_set_enabled(int32_t value) { enabled=value!=0; if (enabled) initialize(); }
extern "C" int32_t dstv_desmume_metal_active() { return enabled && pipeline && !failed && hasRendered; }

bool DSTVMetalWait() {
    std::unique_lock<std::mutex> lock(worker.mutex);
    if(!worker.scheduled) return true;
    worker.condition.wait(lock,[]{return !worker.busy;});
    worker.scheduled=false;
    return worker.result;
}

void DSTVMetalSchedule(SoftRasterizerRenderer *renderer, void (*waitGeometry)(SoftRasterizerRenderer *)) {
    if(!recording) return;
    std::lock_guard<std::mutex> lock(worker.mutex);
    if(!worker.thread.joinable()) {
        worker.stopping=false;
        worker.thread=std::thread([] {
            for(;;) {
                std::unique_lock<std::mutex> lock(worker.mutex);
                worker.condition.wait(lock,[]{return worker.pending || worker.stopping;});
                if(worker.stopping) return;
                auto *renderer=worker.renderer; auto wait=worker.waitGeometry;
                worker.pending=false; lock.unlock();
                wait(renderer);
                const bool result=DSTVMetalFinish(renderer);
                lock.lock(); worker.result=result; worker.busy=false; lock.unlock();
                worker.condition.notify_all();
            }
        });
    }
    worker.renderer=renderer; worker.waitGeometry=waitGeometry;
    worker.busy=true; worker.scheduled=true; worker.pending=true;
    worker.condition.notify_one();
}

void DSTVMetalRelease() {
    DSTVMetalWait();
    worker.stop();
    recording=false; postProcessed=false; hasRendered=false;
    for (auto &buffer:buffers) buffer=nil;
    std::vector<std::vector<Span>>().swap(rows);
    std::vector<Span>().swap(flatSpans);
    std::vector<Range>().swap(tileRanges);
    std::vector<uint32_t>().swap(tileIndices);
    std::vector<uint32_t>().swap(tileCursors);
    std::vector<Texture>().swap(textures);
    std::vector<uint32_t>().swap(texels);
    std::vector<Pixel>().swap(initial);
}

bool DSTVMetalRecording() { return recording; }
bool DSTVMetalPostProcessed() { return postProcessed; }
bool DSTVMetalReference() { return reference; }

bool DSTVMetalBegin(SoftRasterizerRenderer *renderer) {
    recording=false; postProcessed=false;
    reference=getenv("DSTV_DS_METAL_COMPARE") != nullptr;
    if (!initialize()) return false;
    config={};
    config.width=renderer->GetFramebufferWidth(); config.height=renderer->GetFramebufferHeight();
    if (config.width<256 || config.width>2048 || config.height>1536) return false;
    auto *a=renderer->_framebufferAttributes;
    config.color=renderer->GetFramebuffer()[0].color; config.depth=a->depth[0];
    config.attrs=a->opaquePolyID[0]|(a->translucentPolyID[0]<<8)|(a->stencil[0]<<16)|
        (a->isFogged[0]<<17)|(a->isTranslucentPoly[0]<<18)|(a->polyFacing[0]<<19);
    const auto &state=*renderer->currentRenderState;
    config.wbuffer=state.wbuffer; config.alphaTest=state.enableAlphaTest;
    config.alphaRef=state.alphaTestRef; config.blend=state.enableAlphaBlending;
    config.highlight=state.shading==PolygonShadingMode_Highlight;
    config.samplingHack=renderer->_enableFragmentSamplingHack;
    config.clearImage=state.enableClearImage;
    config.edgeEnabled=renderer->DSTVMetalEdgeEnabled(); config.fogEnabled=renderer->DSTVMetalFogEnabled();
    config.fogAlpha=state.enableFogAlphaOnly; config.clearDepth=state.clearDepth;
    config.clearOpaque=(state.clearColor>>24)&63;
    config.fogColor=COLOR555TO6665(state.fogColor&0x7fff,(state.fogColor>>16)&31);
    for (unsigned i=0;i<8;++i) config.edge[i]=COLOR555TO6665(state.edgeMarkColorTable[i]&0x7fff,state.enableAntialiasing?16:31);

    if (config.clearImage) {
        initial.resize(size_t(config.width)*config.height);
        for (size_t i=0;i<initial.size();++i) initial[i]={renderer->GetFramebuffer()[i].color,a->depth[i],
            uint32_t(a->opaquePolyID[i])|(a->translucentPolyID[i]<<8)|(a->stencil[i]<<16)|
            (a->isFogged[i]<<17)|(a->isTranslucentPoly[i]<<18)|(a->polyFacing[i]<<19)};
    }
    for (unsigned i=0;i<32;++i) config.toon[i]=renderer->toonColor32LUT[i].color;
    rows.resize(config.height);
    for (auto &row:rows) row.clear();
    textures.clear(); texels.clear();
    std::unordered_map<const SoftRasterizerTexture*,uint32_t> offsets;
    for (size_t i=0;i<renderer->GetClippedPolyCount();++i) {
        auto *t=(SoftRasterizerTexture*)renderer->GetTextureByPolygonRenderIndex(i);
        Texture info={};
        if (t && t->IsSamplingEnabled()) {
            info.width=t->GetRenderWidth(); info.height=t->GetRenderHeight();
            info.originalWidth=t->GetWidth(); info.originalHeight=t->GetHeight();
            info.wrap=renderer->GetClippedPolyByIndex(i).poly->texParam.TextureWrapMode;
            auto found=offsets.find(t);
            if (found!=offsets.end()) info.offset=found->second;
            else {
                const size_t count=size_t(info.width)*info.height;
                // Bound upload memory even with malicious or pathological scenes.
                if (count>16u*1024*1024 || texels.size()+count>32u*1024*1024) return false;
                info.offset=(uint32_t)texels.size(); offsets[t]=info.offset;
                texels.insert(texels.end(),t->GetRenderData(),t->GetRenderData()+count);
            }
        }
        textures.push_back(info);
    }
    if (textures.empty()) textures.push_back({});
    if (texels.empty()) texels.push_back(0);
    spanCount=0; overflow=false;
    recording=true;
    return true;
}

void DSTVMetalSpan(unsigned y,unsigned x,unsigned count,unsigned polygon,uint32_t attr,unsigned flags,
                   const float *coord,const float *delta,const float *color,const float *colorDelta) {
    if (!count || y>=rows.size()) return;
    // Reserve in row-local batches to avoid one contended atomic per scanline.
    if (overflow.load(std::memory_order_relaxed)) return;
    if ((rows[y].size() & 63) == 0 && spanCount.fetch_add(64,std::memory_order_relaxed)>=500000) { overflow=true; return; }
    Span span={x,x+count,attr,flags,polygon};
    memcpy(span.coord,coord,16); memcpy(span.delta,delta,16);
    memcpy(span.color,color,16); memcpy(span.colorDelta,colorDelta,16);
    // Software rasterizer workers own disjoint row bands, preserving polygon order.
    rows[y].push_back(span);
}

bool DSTVMetalFinish(SoftRasterizerRenderer *renderer) {
    if (!recording) return true;
    recording=false;
    if (overflow) { failed=true; printf("DS Metal span budget exceeded; reverting to CPU\n"); return false; }
    @autoreleasepool {
        auto &spans=flatSpans;
        auto &ranges=tileRanges;
        auto &indices=tileIndices;
        spans.clear(); indices.clear();
        const unsigned tiles=config.width/32;
        ranges.assign(config.height*tiles,{});
        // Count covered bins once per span; do not scan every polygon for every tile.
        for (unsigned y=0;y<rows.size();++y) for (const auto &span:rows[y]) {
            for (unsigned t=span.x/32;t<=(span.end-1)/32;++t) ++ranges[y*tiles+t].count;
        }
        size_t total=0;
        tileCursors.resize(ranges.size());
        for (size_t i=0;i<ranges.size();++i) {
            ranges[i].start=(uint32_t)total; tileCursors[i]=(uint32_t)total;
            total+=ranges[i].count;
        }
        if (total>16u*1024*1024) { failed=true; return false; }
        indices.resize(std::max(total,size_t(1)));
        for (unsigned y=0;y<rows.size();++y) for (const auto &span:rows[y]) {
            const uint32_t index=(uint32_t)spans.size(); spans.push_back(span);
            for (unsigned t=span.x/32;t<=(span.end-1)/32;++t) indices[tileCursors[y*tiles+t]++]=index;
        }
        if (spans.empty()) spans.push_back({});
        const size_t count=size_t(config.width)*config.height;
        bool okay=upload(0,spans.data(),spans.size()*sizeof(Span)) &&
            upload(1,ranges.data(),ranges.size()*sizeof(Range)) &&
            upload(2,indices.data(),indices.size()*4) &&
            upload(3,textures.data(),textures.size()*sizeof(Texture)) &&
            upload(4,texels.data(),texels.size()*4) && upload(5,config.clearImage?initial.data():nullptr,count*sizeof(Pixel)) &&
            upload(6,nullptr,count*4) && upload(7,renderer->DSTVMetalFogTable(),32768);
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=okay?[command computeCommandEncoder]:nil;
        if (encoder) {
            [encoder setComputePipelineState:pipeline];
            for (unsigned i=0;i<6;++i) [encoder setBuffer:buffers[i] offset:0 atIndex:i];
            [encoder setBytes:&config length:sizeof(config) atIndex:6];
            const NSUInteger group=std::min(NSUInteger(128),std::min(pipeline.maxTotalThreadsPerThreadgroup,postPipeline.maxTotalThreadsPerThreadgroup));
            [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(group,1,1)];
            [encoder endEncoding];
            id<MTLComputeCommandEncoder> post=[command computeCommandEncoder];
            [post setComputePipelineState:postPipeline];
            [post setBuffer:buffers[5] offset:0 atIndex:0];
            [post setBuffer:buffers[6] offset:0 atIndex:1];
            [post setBuffer:buffers[7] offset:0 atIndex:2];
            [post setBytes:&config length:sizeof(config) atIndex:3];
            [post dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(group,1,1)];
            [post endEncoding]; [command commit]; [command waitUntilCompleted];
        }
        if (!encoder || command.status!=MTLCommandBufferStatusCompleted) {
            printf("DS Metal frame failed; reverting to CPU: %s\n",command.error.localizedDescription.UTF8String);
            failed=true; return false;
        }
        auto *out=(const Pixel*)buffers[5].contents;
        auto *color=renderer->GetFramebuffer();
        if (DSTVMetalReference()) {
            size_t differences=0, large=0;
            for (size_t i=0;i<count;++i) if (color[i].color!=out[i].color) {
                ++differences;
                const uint32_t c=color[i].color,g=out[i].color;
                for (unsigned channel=0;channel<4;++channel)
                    if (abs(int((c>>(channel*8))&255)-int((g>>(channel*8))&255))>1) { ++large; break; }
            }
            static unsigned checks=0;
            if (++checks<=10 || checks%120==0) printf("DS Metal reference: %zu/%zu colour differences, %zu over one unit\n",differences,count,large);
        }
        memcpy(color,buffers[6].contents,count*4);
        postProcessed=true; hasRendered=true;
        static unsigned frame=0;
        if (++frame==1 || frame%600==0) printf("DS Metal: %ux%u, %zu spans, GPU %.2f ms\n",config.width,config.height,spans.size(),(command.GPUEndTime-command.GPUStartTime)*1000);
        fflush(stdout);
        return true;
    }
}
