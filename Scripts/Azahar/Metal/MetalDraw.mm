// SPDX-License-Identifier: GPL-2.0-or-later
#include "MetalDraw.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cmath>
#include <map>
#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <cstring>
#include <cstdlib>

namespace AzaharMetal {
struct TransferTicket {
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> command;
    id<MTLBuffer> output,displayOutput;
    unsigned displayScale=1;
    size_t size=0;
};
struct SnapshotLease {
    id<MTLTexture> image;
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> lastUse;
    std::atomic_bool foreignUse{false};
};
struct NativeTexture { id<MTLTexture> image; std::shared_ptr<SnapshotLease> lease; };
namespace {
constexpr const char* vertexSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Vertex {
    packed_float4 position, color;
    packed_float2 uv0, uv1, uv2;
    float uv0w;
    packed_float4 quaternion;
    packed_float3 view;
};
struct Varyings {
    float4 position [[position]];
    float4 color [[user(locn1)]];
    float2 uv0 [[user(locn2)]];
    float2 uv1 [[user(locn3)]];
    float2 uv2 [[user(locn4)]];
    float uv0w [[user(locn5)]];
    float4 quaternion [[user(locn6)]];
    float3 view [[user(locn7)]];
    float clip [[clip_distance]] [2];
};
struct VSUniforms { uint enableClip, flip; float4 coefficient; };
vertex Varyings pica_vertex(uint id [[vertex_id]], device const Vertex* vertices [[buffer(0)]], constant VSUniforms& uniforms [[buffer(1)]]) {
    Vertex v = vertices[id];
    Varyings o;
    // PICA clip Z is [-W,0]; native Metal's is [0,W].
    o.position = float4(v.position.x, v.position.y, -v.position.z, v.position.w);
    if (uniforms.flip) o.position.y = -o.position.y;
    o.clip[0] = -v.position.z;
    o.clip[1] = uniforms.enableClip ? dot(uniforms.coefficient, float4(v.position)) : 0;
    o.color = v.color;
    o.uv0 = v.uv0; o.uv1 = v.uv1; o.uv2 = v.uv2; o.uv0w = v.uv0w;
    o.quaternion = v.quaternion; o.view = v.view;
    return o;
}
)MSL";
void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
std::string Error(NSError* error) {
    return error ? std::string(error.localizedDescription.UTF8String) : "Metal operation failed";
}
}
struct DrawContext::Impl {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLFunction> vertex;
    id<MTLComputePipelineState> transferPipeline,aliasPipeline,scanoutPipeline;
    id<MTLSamplerState> sampler;
    id<MTLDepthStencilState> depth;
    using PipelineKey=std::array<uint64_t,12>;
    struct CachedPipeline {id<MTLRenderPipelineState> pipeline;uint64_t lastUse;};
    std::map<PipelineKey,CachedPipeline> pipelines;
    std::map<std::pair<std::string,std::string>,uint64_t> anonymousVertexIDs;
    uint64_t anonymousVertexSequence=0;
    std::map<uint64_t,id<MTLFunction>> vertexFunctions;
    std::map<uint64_t,id<MTLFunction>> fragmentFunctions;
    uint64_t pipelineClock=0;
    id<MTLTexture> cachedColor, cachedDepth,whiteTexture;
    id<MTLTexture> stencilViewParent,stencilView;
    bool stencilViewReadable=false;
    id<MTLCommandBuffer> activeCommand;
    id<MTLRenderCommandEncoder> activeEncoder;
    unsigned activeDraws = 0;
    std::map<std::array<unsigned,9>,id<MTLDepthStencilState>> depthStates;
    std::vector<id<MTLCommandBuffer>> pending;
    std::map<uint64_t,id<MTLTexture>> textureCache;
    size_t textureCacheBytes=0;
    std::map<unsigned,id<MTLSamplerState>> samplers;
    std::array<id<MTLTexture>,3> lutTextures;
    std::array<std::vector<uint8_t>,3> lutBytes;
    // Upload slices stay immutable until their owning command completes. One
    // page can serve many draws, avoiding an MTLBuffer allocation per draw/plane.
    struct UploadPage { id<MTLBuffer> buffer; id<MTLCommandBuffer> owner; size_t used; };
    struct BufferSlice { id<MTLBuffer> buffer; size_t offset; };
    std::vector<UploadPage> uploadPages;
    size_t uploadPoolBytes=0;
    std::vector<std::shared_ptr<SnapshotLease>> snapshotPool;
    size_t snapshotPoolBytes=0;
    id<MTLBuffer> aliasDepthScratch,aliasStencilScratch;
    id<MTLBuffer> colorReadback,depthReadback,stencilReadback,transferReadback;
    id<MTLTexture> spareColor,spareDepth;
    bool profilingEnabled = false;
    Stats stats;
    BufferSlice Upload(size_t length) {
        Require(activeCommand != nil && length != 0,"Upload outside command buffer");
        const size_t aligned=(length+255)&~size_t(255);
        for(auto& page:uploadPages) {
            if(page.owner != activeCommand && page.owner.status==MTLCommandBufferStatusCompleted) {
                page.owner=nil;page.used=0;
            }
            if((!page.owner || page.owner==activeCommand) && page.buffer.length-page.used>=aligned) {
                const size_t offset=page.used;page.used+=aligned;page.owner=activeCommand;
                ++stats.uploadBufferReuses;return {page.buffer,offset};
            }
        }
        const size_t capacity=std::max(size_t(256*1024),aligned);
        auto buffer=[device newBufferWithLength:capacity options:MTLResourceStorageModeShared];
        Require(buffer != nil,"Upload buffer allocation failed");++stats.uploadBufferAllocations;
        // Oversized/burst allocations are retained by Metal's command buffer,
        // not the pool. They cannot grow the persistent cache without bound.
        if(capacity<=1024*1024 && uploadPoolBytes+capacity<=16*1024*1024) {
            uploadPages.push_back({buffer,activeCommand,aligned});uploadPoolBytes+=capacity;
        }
        return {buffer,0};
    }
    std::shared_ptr<NativeTexture> SnapshotImage(unsigned width,unsigned height) {
        for(auto& item:snapshotPool) {
            // No CPU snapshot handle may still refer to an image we overwrite,
            // and every GPU consumer on this queue must have completed.
            if(item.use_count()==1 && !item->foreignUse && item->lastUse.status==MTLCommandBufferStatusCompleted &&
               item->image.width==width && item->image.height==height) {
                item->lastUse=activeCommand;++stats.snapshotTextureReuses;
                auto result=std::make_shared<NativeTexture>();result->image=item->image;result->lease=item;return result;
            }
        }
        auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        auto item=std::make_shared<SnapshotLease>();item->image=[device newTextureWithDescriptor:descriptor];
        Require(item->image != nil,"Surface snapshot allocation failed");
        item->queue=queue;item->lastUse=activeCommand;++stats.snapshotTextureAllocations;
        const size_t bytes=size_t(width)*height*4;
        if(snapshotPoolBytes+bytes<=32*1024*1024) {snapshotPool.push_back(item);snapshotPoolBytes+=bytes;}
        auto result=std::make_shared<NativeTexture>();result->image=item->image;result->lease=std::move(item);return result;
    }
    id<MTLBuffer> AliasScratch(id<MTLBuffer> __strong& buffer,size_t length) {
        // GPU-only scratch is ordered by tracked resources on this one command
        // queue. Reusing it does not expose mutable bytes to CPU snapshots.
        if(!buffer || buffer.length<length) {buffer=[device newBufferWithLength:length options:MTLResourceStorageModePrivate];++stats.aliasScratchAllocations;}
        Require(buffer != nil,"Surface scratch allocation failed");return buffer;
    }
    id<MTLBuffer> Readback(id<MTLBuffer> __strong& buffer,size_t length) {
        // ReadFrame waits for completion and copies into owned vectors before
        // returning. No CPU or GPU consumer retains these scratch bytes.
        if(!buffer || buffer.length<length) {
            buffer=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
            ++stats.readbackBufferAllocations;
        } else ++stats.readbackBufferReuses;
        Require(buffer != nil,"Readback allocation failed");return buffer;
    }
    void SubmitDraws() {
        if (!activeCommand) return;
        [activeEncoder endEncoding]; activeEncoder=nil;
        [activeCommand commit];
        pending.push_back(activeCommand); activeCommand=nil; activeDraws=0;
        ++stats.commandBuffers;
        // Bound retained buffers without serialising every draw.
        if(pending.size()>=8) {
            auto oldest=pending.front();
            const auto start=std::chrono::steady_clock::now();
            [oldest waitUntilCompleted];
            Require(oldest.status==MTLCommandBufferStatusCompleted,Error(oldest.error));
            if(profilingEnabled) {
                stats.gpuWaitSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
                stats.gpuSeconds+=std::max(0.0,oldest.GPUEndTime-oldest.GPUStartTime);
            }
            pending.erase(pending.begin());
        }
    }
    Impl() {
        device = MTLCreateSystemDefaultDevice();
        Require(device != nil, "No native Metal device");
        queue = [device newCommandQueue];
        Require(queue != nil, "Cannot create native Metal queue");
        NSError* error = nil;
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_3;
        options.fastMathEnabled = NO;
        id<MTLLibrary> library = [device newLibraryWithSource:@(vertexSource) options:options error:&error];
        Require(library != nil, Error(error));
        vertex = [library newFunctionWithName:@"pica_vertex"];
        Require(vertex != nil, "Missing PICA vertex entry");
        MTLSamplerDescriptor* descriptor = [MTLSamplerDescriptor new];
        descriptor.minFilter = MTLSamplerMinMagFilterNearest;
        descriptor.magFilter = MTLSamplerMinMagFilterNearest;
        descriptor.sAddressMode = descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler = [device newSamplerStateWithDescriptor:descriptor];
        MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
        ds.depthCompareFunction = MTLCompareFunctionAlways;
        ds.depthWriteEnabled = YES;
        depth = [device newDepthStencilStateWithDescriptor:ds];
    }
    id<MTLRenderPipelineState> Pipeline(const FragmentProgram& program, unsigned colorMask,const VertexProgram* hardware) {
        Require(program.shader && program.shader->identity,"Missing immutable fragment program");
        uint64_t vertexID=hardware?hardware->identity:0;
        if(hardware && !vertexID) {
            const auto source=std::make_pair(hardware->source,hardware->entry);
            auto [entry,inserted]=anonymousVertexIDs.try_emplace(source,0);
            if(inserted)entry->second=++anonymousVertexSequence;
            vertexID=entry->second;
        }
        PipelineKey key{program.shader->identity,uint64_t(bool(hardware)),vertexID,
            uint64_t(hardware && !hardware->identity),colorMask,uint64_t(program.blendEnabled),
            program.blend[0],program.blend[1],program.blend[2],program.blend[3],program.blend[4],program.blend[5]};
        if(auto found=pipelines.find(key);found!=pipelines.end()) {
            ++stats.pipelineHits;found->second.lastUse=++pipelineClock;
            return found->second.pipeline;
        }
        const auto buildStart = profilingEnabled ? std::chrono::steady_clock::now()
                                                 : std::chrono::steady_clock::time_point{};
        NSError* error = nil;
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_3;
        options.fastMathEnabled = NO;
        id<MTLFunction> fragment=nil;
        auto knownFragment=fragmentFunctions.find(program.shader->identity);
        if(knownFragment!=fragmentFunctions.end())fragment=knownFragment->second;
        else {
            auto library=[device newLibraryWithSource:@(program.shader->source.c_str()) options:options error:&error];
            Require(library!=nil,Error(error));
            fragment=[library newFunctionWithName:@(program.shader->entry.c_str())];
            Require(fragment!=nil,"Missing PICA fragment entry");
            if(fragmentFunctions.size()>=256)fragmentFunctions.clear();
            fragmentFunctions.emplace(program.shader->identity,fragment);
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        if(hardware) {
            auto known=vertexFunctions.find(hardware->identity);
            if(hardware->identity && known!=vertexFunctions.end())descriptor.vertexFunction=known->second;
            else {
                auto nativeLibrary=[device newLibraryWithSource:@(hardware->source.c_str()) options:options error:&error];
                Require(nativeLibrary!=nil,Error(error));
                descriptor.vertexFunction=[nativeLibrary newFunctionWithName:@(hardware->entry.c_str())];
                Require(descriptor.vertexFunction!=nil,"Missing native PICA vertex function");
                if(vertexFunctions.size()>=128)vertexFunctions.clear();
                if(hardware->identity)vertexFunctions.emplace(hardware->identity,descriptor.vertexFunction);
            }
        }
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        descriptor.colorAttachments[0].writeMask = MTLColorWriteMask(((colorMask & 1) ? MTLColorWriteMaskRed : 0) | ((colorMask & 2) ? MTLColorWriteMaskGreen : 0) | ((colorMask & 4) ? MTLColorWriteMaskBlue : 0) | ((colorMask & 8) ? MTLColorWriteMaskAlpha : 0));
        if (program.blendEnabled) {
            constexpr MTLBlendOperation operations[] = {MTLBlendOperationAdd, MTLBlendOperationSubtract, MTLBlendOperationReverseSubtract};
            constexpr MTLBlendFactor factors[] = {MTLBlendFactorZero, MTLBlendFactorOne,
                MTLBlendFactorSourceColor, MTLBlendFactorOneMinusSourceColor,
                MTLBlendFactorDestinationColor, MTLBlendFactorOneMinusDestinationColor,
                MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha,
                MTLBlendFactorDestinationAlpha, MTLBlendFactorOneMinusDestinationAlpha,
                MTLBlendFactorBlendColor, MTLBlendFactorOneMinusBlendColor,
                MTLBlendFactorBlendAlpha, MTLBlendFactorOneMinusBlendAlpha,
                MTLBlendFactorSourceAlphaSaturated};
            const auto& b = program.blend;
            Require(b[0] < 3 && b[3] < 3 && b[1] < 15 && b[2] < 15 && b[4] < 15 && b[5] < 15, "Invalid native blend state");
            auto attachment = descriptor.colorAttachments[0];
            attachment.blendingEnabled = YES;
            attachment.rgbBlendOperation = operations[b[0]];
            attachment.sourceRGBBlendFactor = factors[b[1]];
            attachment.destinationRGBBlendFactor = factors[b[2]];
            attachment.alphaBlendOperation = operations[b[3]];
            attachment.sourceAlphaBlendFactor = factors[b[4]];
            attachment.destinationAlphaBlendFactor = factors[b[5]];
        }
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        Require(pipeline != nil, Error(error));
        // Bounded development cache; no persistent compatibility promise yet.
        if(pipelines.size()>=256) {
            auto oldest=std::min_element(pipelines.begin(),pipelines.end(),[](const auto& a,const auto& b){return a.second.lastUse<b.second.lastUse;});
            pipelines.erase(oldest);
        }
        pipelines.emplace(key,CachedPipeline{pipeline,++pipelineClock});
        ++stats.pipelineBuilds;
        if (profilingEnabled) {
            stats.pipelineBuildSeconds +=
                std::chrono::duration<double>(std::chrono::steady_clock::now() - buildStart).count();
        }
        return pipeline;
    }
};
DrawContext::DrawContext() : impl(std::make_unique<Impl>()) {}
DrawContext::~DrawContext() = default;
const Stats& DrawContext::Measurements() const { return impl->stats; }
void DrawContext::SetProfilingEnabled(bool enabled) { impl->profilingEnabled = enabled; }
Stats DrawContext::TakeMeasurements() {
    Stats result = impl->stats;
    impl->stats = {};
    return result;
}
std::vector<uint8_t> DrawContext::Draw(const FragmentProgram& program, std::span<const Vertex> vertices,
    const Pica::Shader::Generator::FSUniformData& uniforms, unsigned width, unsigned height,
    std::span<const Texture> textures, const LookupTables& luts) {
    Frame initial;
    initial.width = width; initial.height = height;
    initial.rgba.resize(size_t(width) * height * 4);
    initial.depth.resize(size_t(width) * height, 1);
    initial.stencil.resize(size_t(width) * height);
    return DrawFrame(program, vertices, uniforms, initial, {}, textures, luts).rgba;
}
Frame DrawContext::DrawFrame(const FragmentProgram& program, std::span<const Vertex> vertices,
    const Pica::Shader::Generator::FSUniformData& uniforms, const Frame& initial,
    const DrawState& state, std::span<const Texture> textures, const LookupTables& luts, bool retainTarget) {
    const unsigned width = initial.width, height = initial.height;
    @autoreleasepool {
        const auto encodeStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                        : std::chrono::steady_clock::time_point{};
        Require(width > 0 && height > 0 && width <= 4096 && height <= 4096, "Invalid Metal target size");
        const auto hardware=state.hardware;
        const size_t vertexCount=hardware?hardware->indices.size():vertices.size();
        Require(vertexCount && vertexCount%3==0 && vertexCount<=300000,"Invalid triangle batch");
        Require(textures.size() <= 3, "Too many PICA texture units");
        for (const auto& v : vertices) for (float component : v.position)
            Require(std::isfinite(component), "Non-finite clip coordinate");
        const size_t count = size_t(width) * height;
        const bool reuse = initial.rgba.empty();
        Require(reuse ? (impl->cachedColor && impl->cachedColor.width == width && impl->cachedColor.height == height) : (initial.rgba.size() == count * 4 && initial.depth.size() == count && initial.stencil.size() == count), "Invalid initial framebuffer");
        auto pipeline = impl->Pipeline(program, state.colorMask,hardware?hardware->program:nullptr);
        if(!reuse) impl->SubmitDraws();
        auto device = impl->device;
        MTLTextureDescriptor* targetDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        targetDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        targetDesc.storageMode = MTLStorageModePrivate;
        const auto targetAllocationStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                                  : std::chrono::steady_clock::time_point{};
        const bool spareMatches=impl->spareColor && impl->spareColor.width==width && impl->spareColor.height==height;
        id<MTLTexture> target = reuse ? impl->cachedColor : spareMatches ? impl->spareColor : [device newTextureWithDescriptor:targetDesc];
        MTLTextureDescriptor* depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:width height:height mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        depthDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = reuse ? impl->cachedDepth : spareMatches ? impl->spareDepth : [device newTextureWithDescriptor:depthDesc];
        if(!reuse) {
            if(spareMatches) ++impl->stats.targetReuses; else ++impl->stats.targetAllocations;
            impl->spareColor=nil;impl->spareDepth=nil;
        }
        if (impl->profilingEnabled) {
            impl->stats.targetAllocationSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - targetAllocationStart).count();
        }
        const size_t rowBytes = (size_t(width) * 4 + 255) & ~size_t(255);
        const auto vertexBufferStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                              : std::chrono::steady_clock::time_point{};
        const void* inputBytes=hardware?static_cast<const void*>(hardware->inputs.data()):vertices.data();
        const size_t inputSize=hardware?hardware->inputs.size()*sizeof(hardware->inputs[0]):vertices.size_bytes();
        const bool inlineVertices=inputSize<=4096;
        if(!impl->activeCommand) impl->activeCommand=[impl->queue commandBuffer];
        Impl::BufferSlice input{};
        if(!inlineVertices) {
            input=impl->Upload(inputSize);
            std::memcpy(static_cast<uint8_t*>(input.buffer.contents)+input.offset,inputBytes,inputSize);
        }
        if (impl->profilingEnabled) {
            impl->stats.vertexBufferSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - vertexBufferStart).count();
        }
        Require(target && depth && (inlineVertices || input.buffer), "Metal allocation failed");
        if(!impl->activeCommand) impl->activeCommand=[impl->queue commandBuffer];
        id<MTLCommandBuffer> command=impl->activeCommand;
        auto uploadPlane = [&](id<MTLTexture> texture, const void* bytes, size_t pixelBytes, MTLBlitOption option) {
            const auto uploadStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                            : std::chrono::steady_clock::time_point{};
            const size_t stride = (width * pixelBytes + 255) & ~size_t(255);
            const auto staging=impl->Upload(stride*height);
            for (unsigned y = 0; y < height; ++y) std::memcpy(static_cast<uint8_t*>(staging.buffer.contents) + staging.offset + stride*y, static_cast<const uint8_t*>(bytes) + width*pixelBytes*y, width*pixelBytes);
            auto blit = [command blitCommandEncoder];
            [blit copyFromBuffer:staging.buffer sourceOffset:staging.offset sourceBytesPerRow:stride sourceBytesPerImage:stride * height sourceSize:MTLSizeMake(width, height, 1) toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0) options:option];
            [blit endEncoding];
            if (impl->profilingEnabled) {
                impl->stats.framebufferUploadSeconds += std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - uploadStart).count();
                impl->stats.framebufferUploadBytes += uint64_t(width) * height * pixelBytes;
            }
        };
        if (!reuse) {
        uploadPlane(target, initial.rgba.data(), 4, MTLBlitOptionNone);
        uploadPlane(depth, initial.depth.data(), 4, MTLBlitOptionDepthFromDepthStencil);
        uploadPlane(depth, initial.stencil.data(), 1, MTLBlitOptionStencilFromDepthStencil);
        }
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = depth;
        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1;
        if(!impl->activeEncoder) impl->activeEncoder=[command renderCommandEncoderWithDescriptor:pass];
        id<MTLRenderCommandEncoder> encoder=impl->activeEncoder;
        Require(encoder != nil, "Cannot create Metal render encoder");
        [encoder setRenderPipelineState:pipeline];
        constexpr MTLCompareFunction compares[] = {MTLCompareFunctionNever, MTLCompareFunctionAlways, MTLCompareFunctionEqual, MTLCompareFunctionNotEqual, MTLCompareFunctionLess, MTLCompareFunctionLessEqual, MTLCompareFunctionGreater, MTLCompareFunctionGreaterEqual};
        constexpr MTLStencilOperation operations[] = {MTLStencilOperationKeep, MTLStencilOperationZero, MTLStencilOperationReplace, MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp, MTLStencilOperationInvert, MTLStencilOperationIncrementWrap, MTLStencilOperationDecrementWrap};
        Require(state.depthFunc < 8 && state.stencilFunc < 8 && state.stencilFail < 8 && state.depthFail < 8 && state.depthPass < 8, "Invalid depth/stencil state");
        auto ds = [MTLDepthStencilDescriptor new];
        ds.depthCompareFunction = compares[state.depthFunc];
        ds.depthWriteEnabled = state.depthWrite;
        if (state.stencilEnabled) {
            auto stencil = [MTLStencilDescriptor new];
            // PICA compares reference to stored stencil, the Metal convention.
            stencil.stencilCompareFunction = compares[state.stencilFunc];
            stencil.stencilFailureOperation = operations[state.stencilFail];
            stencil.depthFailureOperation = operations[state.depthFail];
            stencil.depthStencilPassOperation = operations[state.depthPass];
            stencil.readMask = state.stencilReadMask; stencil.writeMask = state.stencilWriteMask;
            ds.frontFaceStencil = ds.backFaceStencil = stencil;
        }
        const std::array<unsigned,9> depthKey{state.depthFunc,unsigned(state.depthWrite),unsigned(state.stencilEnabled),state.stencilFunc,state.stencilFail,state.depthFail,state.depthPass,state.stencilReadMask,state.stencilWriteMask};
        auto depthState=impl->depthStates.find(depthKey);
        if(depthState==impl->depthStates.end()) {
            if(impl->depthStates.size()>=128) impl->depthStates.clear();
            depthState=impl->depthStates.emplace(depthKey,[device newDepthStencilStateWithDescriptor:ds]).first;
        }
        [encoder setDepthStencilState:depthState->second];
        [encoder setStencilReferenceValue:state.stencilRef];
        [encoder setCullMode:state.cull ? MTLCullModeBack : MTLCullModeNone];
        [encoder setFrontFacingWinding:state.cull == 1 ? MTLWindingClockwise : MTLWindingCounterClockwise];
        if (state.viewportWidth > 0 && state.viewportHeight > 0) [encoder setViewport:MTLViewport{state.viewportX, state.viewportY, state.viewportWidth, state.viewportHeight, 0, 1}];
        else [encoder setViewport:MTLViewport{0,0,double(width),double(height),0,1}];
        auto vs = state.vertexUniforms;
        vs.flip_viewport = state.flipY;
        [encoder setVertexBytes:&vs length:sizeof(vs) atIndex:1];
        [encoder setBlendColorRed:uniforms.blend_color.r() green:uniforms.blend_color.g() blue:uniforms.blend_color.b() alpha:uniforms.blend_color.a()];
        if(inlineVertices) [encoder setVertexBytes:inputBytes length:inputSize atIndex:0];
        else [encoder setVertexBuffer:input.buffer offset:input.offset atIndex:0];
        if(hardware) {
            [encoder setVertexBytes:&hardware->uniforms length:sizeof(hardware->uniforms) atIndex:2];
            const size_t bytes=hardware->indices.size()*sizeof(uint32_t);
            const auto order=impl->Upload(bytes);
            std::memcpy(static_cast<uint8_t*>(order.buffer.contents)+order.offset,hardware->indices.data(),bytes);
            [encoder setVertexBuffer:order.buffer offset:order.offset atIndex:3];
        }
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        // Safe defaults for inactive sampler bindings, not fake game resources.
        for (unsigned i = 0; i < 3; ++i) {
            static const Texture white;
            const Texture& texture = i < textures.size() ? textures[i] : white;
            Require(texture.width && texture.height && texture.width <= 4096 && texture.height <= 4096 && (texture.native || texture.Pixels().size() == size_t(texture.width) * texture.height * 4), "Invalid texture payload");
            id<MTLTexture> tex=texture.native?texture.native->image:nil;
            auto cached=impl->textureCache.find(texture.cacheIdentity);
            if(!tex && texture.cacheIdentity && cached!=impl->textureCache.end()) tex=cached->second;
            const auto pixels=texture.Pixels();
            const bool whitePixel=!texture.native && texture.width==1 && texture.height==1 && pixels.size()==4 &&
                pixels[0]==255 && pixels[1]==255 && pixels[2]==255 && pixels[3]==255;
            if(!tex && whitePixel && impl->whiteTexture) {tex=impl->whiteTexture;++impl->stats.whiteTextureReuses;}
            if(!tex) {
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:texture.width height:texture.height mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead;td.storageMode = MTLStorageModeShared;
                const auto textureUploadStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                                       : std::chrono::steady_clock::time_point{};
                tex=[device newTextureWithDescriptor:td];
                Require(tex != nil, "Texture allocation failed");
                ++impl->stats.textureAllocations;
                if(whitePixel)impl->whiteTexture=tex;
                [tex replaceRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0 withBytes:texture.Pixels().data() bytesPerRow:texture.width*4];
                if (impl->profilingEnabled) {
                    impl->stats.textureUploadSeconds += std::chrono::duration<double>(
                        std::chrono::steady_clock::now() - textureUploadStart).count();
                    impl->stats.textureUploadBytes += texture.Pixels().size();
                }
                if(texture.cacheIdentity) {
                    if(impl->textureCacheBytes+texture.Pixels().size()>32*1024*1024 || impl->textureCache.size()>=128) { impl->textureCache.clear();impl->textureCacheBytes=0; }
                    impl->textureCache.emplace(texture.cacheIdentity,tex);impl->textureCacheBytes+=texture.Pixels().size();
                }
            }
            Require(texture.resolutionScale>=1 && texture.resolutionScale<=4 && tex.width==uint64_t(texture.width)*texture.resolutionScale && tex.height==uint64_t(texture.height)*texture.resolutionScale,"Native snapshot dimensions mismatch");
            if(texture.native && texture.native->lease) {
                auto& lease=*texture.native->lease;
                if(lease.queue!=impl->queue)lease.foreignUse=true;
                else lease.lastUse=impl->activeCommand;
            }
            [encoder setFragmentTexture:tex atIndex:i];
            auto sd = [MTLSamplerDescriptor new];
            auto wrap = [](unsigned mode) -> MTLSamplerAddressMode {
                if (mode == 2 || mode == 6 || mode == 7) return MTLSamplerAddressModeRepeat;
                if (mode == 3) return MTLSamplerAddressModeMirrorRepeat;
                return MTLSamplerAddressModeClampToEdge;
            };
            sd.sAddressMode = wrap(texture.wrapS); sd.tAddressMode = wrap(texture.wrapT);
            sd.minFilter = texture.linearMin ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sd.magFilter = texture.linearMag ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            const unsigned samplerKey=texture.wrapS|(texture.wrapT<<3)|(unsigned(texture.linearMin)<<6)|(unsigned(texture.linearMag)<<7);
            auto sampler=impl->samplers.find(samplerKey);
            if(sampler==impl->samplers.end()) sampler=impl->samplers.emplace(samplerKey,[device newSamplerStateWithDescriptor:sd]).first;
            [encoder setFragmentSamplerState:sampler->second atIndex:i];
        }
        auto bindLUT = [&](const auto& data, MTLPixelFormat format, unsigned slot) {
            Require(!data.empty() && data.size() <= 65536, "Invalid PICA lookup table size");
            // SPIRV-Cross's buffer-image lowering uses 4096-wide 2D textures.
            const size_t rows = (data.size() + 4095) / 4096;
            using Element = typename std::decay_t<decltype(data)>::value_type;
            const size_t index=slot-3, bytes=data.size()*sizeof(Element);
            auto& last=impl->lutBytes[index];
            if(last.size()==bytes && std::memcmp(last.data(),data.data(),bytes)==0) {
                [encoder setFragmentTexture:impl->lutTextures[index] atIndex:slot];return;
            }
            const auto lutUploadStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                               : std::chrono::steady_clock::time_point{};
            std::vector<Element> padded(rows * 4096);
            std::copy(data.begin(), data.end(), padded.begin());
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:4096 height:rows mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            Require(texture != nil, "PICA lookup texture allocation failed");
            [texture replaceRegion:MTLRegionMake2D(0, 0, 4096, rows) mipmapLevel:0 withBytes:padded.data() bytesPerRow:4096 * sizeof(Element)];
            impl->lutTextures[index]=texture;
            last.assign(reinterpret_cast<const uint8_t*>(data.data()),reinterpret_cast<const uint8_t*>(data.data())+bytes);
            if (impl->profilingEnabled) {
                impl->stats.lutUploadSeconds += std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - lutUploadStart).count();
                impl->stats.lutUploadBytes += padded.size() * sizeof(Element);
            }
            [encoder setFragmentTexture:texture atIndex:slot];
        };
        bindLUT(luts.lightingFog, MTLPixelFormatRG32Float, 3);
        bindLUT(luts.procedural, MTLPixelFormatRG32Float, 4);
        bindLUT(luts.proceduralColor, MTLPixelFormatRGBA32Float, 5);
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertexCount];
        ++impl->activeDraws;
        if (impl->profilingEnabled) {
            impl->stats.cpuEncodeSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - encodeStart).count();
        }
        if(impl->activeDraws>=128) impl->SubmitDraws();
        ++impl->stats.draws;
        impl->cachedColor = target; impl->cachedDepth = depth;
        if (retainTarget) return {};
        return ReadFrame();
    }
}
void DrawContext::ClearSurface(const SurfaceClear& clear) {
    @autoreleasepool {
        Require(impl->cachedColor && impl->cachedDepth,"Clear without resident framebuffer");
        [impl->activeEncoder endEncoding];impl->activeEncoder=nil;
        if(!impl->activeCommand)impl->activeCommand=[impl->queue commandBuffer];
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=impl->cachedColor;
        pass.colorAttachments[0].loadAction=clear.color?MTLLoadActionClear:MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(clear.rgba[0]/255.0,clear.rgba[1]/255.0,clear.rgba[2]/255.0,clear.rgba[3]/255.0);
        pass.depthAttachment.texture=impl->cachedDepth;
        pass.depthAttachment.loadAction=clear.depth?MTLLoadActionClear:MTLLoadActionLoad;
        pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=clear.depthValue;
        pass.stencilAttachment.texture=impl->cachedDepth;
        pass.stencilAttachment.loadAction=clear.stencil?MTLLoadActionClear:MTLLoadActionLoad;
        pass.stencilAttachment.storeAction=MTLStoreActionStore;pass.stencilAttachment.clearStencil=clear.stencilValue;
        auto encoder=[impl->activeCommand renderCommandEncoderWithDescriptor:pass];
        Require(encoder != nil,"Resident fill encoder failed");[encoder endEncoding];
    }
}
void DrawContext::DiscardFrame() {
    impl->SubmitDraws();
    // All consumers and subsequent imports use the same serial Metal queue.
    // Keep queued commands alive; imports use immutable staging slices and GPU
    // blits, so recycling these attachments needs ordering, not a CPU wait.
    if(impl->cachedColor) {impl->spareColor=impl->cachedColor;impl->spareDepth=impl->cachedDepth;}
    impl->cachedColor = nil; impl->cachedDepth = nil;
}
Frame DrawContext::ReadFrame(bool readColor, bool readDepth, bool readStencil) {
    @autoreleasepool {
        // Finish the render encoder, then append readback to that same command
        // buffer. One submission orders render -> blit without an extra queue trip.
        [impl->activeEncoder endEncoding]; impl->activeEncoder=nil;
        auto command=impl->activeCommand;
        impl->activeCommand=nil; impl->activeDraws=0;
        if(!command) command=[impl->queue commandBuffer];
        const auto readbackStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                          : std::chrono::steady_clock::time_point{};
        auto target = impl->cachedColor, depth = impl->cachedDepth;
        Require(target && depth, "No retained Metal framebuffer");
        const unsigned width = unsigned(target.width), height = unsigned(target.height);
        const size_t count = size_t(width)*height;
        id<MTLBuffer> output = nil;
        size_t rowBytes = 0;
        auto device = impl->device;
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (readColor) {
            rowBytes = (size_t(width) * 4 + 255) & ~size_t(255);
            output = impl->Readback(impl->colorReadback,rowBytes*height);
            Require(output != nil, "Framebuffer readback allocation failed");
            [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1) toBuffer:output destinationOffset:0 destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes * height];
        }
        auto readPlane = [&](size_t pixelBytes, MTLBlitOption option) -> std::pair<id<MTLBuffer>, size_t> {
            const size_t stride = (width * pixelBytes + 255) & ~size_t(255);
            auto& scratch=option==MTLBlitOptionDepthFromDepthStencil ? impl->depthReadback : impl->stencilReadback;
            id<MTLBuffer> buffer = impl->Readback(scratch,stride*height);
            Require(buffer != nil, "Depth readback allocation failed");
            [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride * height options:option];
            return {buffer, stride};
        };
        std::pair<id<MTLBuffer>, size_t> depthRead{}, stencilRead{};
        if (readDepth) depthRead = readPlane(4, MTLBlitOptionDepthFromDepthStencil);
        if (readStencil) stencilRead = readPlane(1, MTLBlitOptionStencilFromDepthStencil);
        if (impl->profilingEnabled) {
            impl->stats.readbackBytes += uint64_t(width) * height *
                ((readColor ? 4 : 0) + (readDepth ? 4 : 0) + (readStencil ? 1 : 0));
        }
        [blit endEncoding];
        [command commit]; ++impl->stats.commandBuffers;
        const auto waitStart = impl->profilingEnabled ? std::chrono::steady_clock::now()
                                                      : std::chrono::steady_clock::time_point{};
        [command waitUntilCompleted];
        if (impl->profilingEnabled) {
            impl->stats.gpuWaitSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - waitStart).count();
        }
        Require(command.status == MTLCommandBufferStatusCompleted, Error(command.error));
        if (impl->profilingEnabled) {
            impl->stats.gpuSeconds += std::max(0.0, command.GPUEndTime - command.GPUStartTime);
        }
        // This readback is ordered after all retained draws on the same queue.
        for (auto submitted : impl->pending) {
            Require(submitted.status == MTLCommandBufferStatusCompleted, Error(submitted.error));
            impl->stats.gpuSeconds += std::max(0.0, submitted.GPUEndTime - submitted.GPUStartTime);
        }
        impl->pending.clear();
        Frame result;
        result.width = width; result.height = height;
        if (readColor) {
            result.rgba.resize(count * 4);
            for (unsigned y = 0; y < height; ++y)
                std::memcpy(result.rgba.data() + size_t(y) * width * 4, static_cast<const uint8_t*>(output.contents) + y * rowBytes, size_t(width) * 4);
        }
        if (readDepth) {
            result.depth.resize(count);
            for (unsigned y = 0; y < height; ++y)
                std::memcpy(result.depth.data() + size_t(y) * width, static_cast<const uint8_t*>(depthRead.first.contents) + y * depthRead.second, size_t(width) * 4);
        }
        if (readStencil) {
            result.stencil.resize(count);
            for (unsigned y = 0; y < height; ++y)
                std::memcpy(result.stencil.data() + size_t(y) * width, static_cast<const uint8_t*>(stencilRead.first.contents) + y * stencilRead.second, size_t(width));
        }
        if (impl->profilingEnabled) {
            impl->stats.readbackWallSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - readbackStart).count();
        }
        return result;
    }
}
std::shared_ptr<TransferTicket> DrawContext::EnqueueTransfer(const DisplayTransfer& p,std::span<const uint8_t> source) {
    @autoreleasepool {
        Require(p.inputFormat<5 && p.outputFormat<5 && p.scaling<=2 && p.resolutionScale>=1 && p.resolutionScale<=4,"Invalid display transfer format");
        auto bpp=[](unsigned f){return f==0?4u:(f==1?3u:2u);};
        const size_t sourceSize=size_t(p.inputWidth)*p.inputHeight*bpp(p.inputFormat);
        const size_t outputSize=size_t(p.outputWidth)*p.outputHeight*bpp(p.outputFormat);
        Require(outputSize>0 && outputSize<=16*1024*1024 && sourceSize<=16*1024*1024,"Display transfer exceeds bounds");
        Require(p.useImage ? bool(impl->cachedColor) : source.size()==sourceSize,"Display transfer source unavailable");
        const uint64_t sampledWidth=uint64_t(p.outputWidth)<<(p.scaling!=0);
        const uint64_t sampledHeight=uint64_t(p.outputHeight)<<(p.scaling==2);
        Require(p.outputWidth && p.outputHeight && sampledWidth<=p.inputWidth && sampledHeight<=p.inputHeight,"Display transfer sampling outside input");
        if(p.useImage) Require((uint64_t(p.sourceX)+sampledWidth)*p.resolutionScale<=impl->cachedColor.width && (uint64_t(p.sourceY)+sampledHeight)*p.resolutionScale<=impl->cachedColor.height,"Display transfer outside resident framebuffer");
        if(!impl->transferPipeline) {
            static const char* code=R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Params {uint iw,ih,ow,oh,inf,outf,inLinear,outLinear,scale,flip,useImage,sourceX,sourceY,resolutionScale;};
uint bytes(uint f){return f==0?4u:(f==1?3u:2u);}
uint offset(uint x,uint y,uint w,uint linear) {
 if(linear)return y*w+x;
 uint m=(x&1)|((y&1)<<1)|((x&2)<<1)|((y&2)<<2)|((x&4)<<2)|((y&4)<<3);
 return (y/8)*(w/8)*64+(x/8)*64+m;
}
uint4 decode(device const uchar* src,uint at,uint f) {
 if(f==0)return uint4(src[at+3],src[at+2],src[at+1],src[at]);
 if(f==1)return uint4(src[at+2],src[at+1],src[at],255);
 uint v=uint(src[at])|(uint(src[at+1])<<8);
 if(f==2){uint r=(v>>11)&31,g=(v>>5)&63,b=v&31;return uint4((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2),255);}
 if(f==3){uint r=(v>>11)&31,g=(v>>6)&31,b=(v>>1)&31;return uint4((r<<3)|(r>>2),(g<<3)|(g>>2),(b<<3)|(b>>2),(v&1)*255);}
 return uint4((v>>12)&15,(v>>8)&15,(v>>4)&15,v&15)*17u;
}
void encode(device uchar* dst,uint at,uint f,uint4 c) {
 if(f==0){dst[at]=uchar(c.a);dst[at+1]=uchar(c.b);dst[at+2]=uchar(c.g);dst[at+3]=uchar(c.r);return;}
 if(f==1){dst[at]=uchar(c.b);dst[at+1]=uchar(c.g);dst[at+2]=uchar(c.r);return;}
 uint v=f==2?((c.r>>3)<<11)|((c.g>>2)<<5)|(c.b>>3):f==3?((c.r>>3)<<11)|((c.g>>3)<<6)|((c.b>>3)<<1)|(c.a>>7):((c.r>>4)<<12)|((c.g>>4)<<8)|((c.b>>4)<<4)|(c.a>>4);
 dst[at]=uchar(v&255);dst[at+1]=uchar(v>>8);
}
uint4 quantize(uint4 c,uint f) {
 if(f==0)return c;
 if(f==1)return uint4(c.rgb,255);
 if(f==2){uint3 v=c.rgb>>uint3(3,2,3);return uint4((v<<uint3(3,2,3))|(v>>uint3(2,4,2)),255);}
 if(f==3){uint3 v=c.rgb>>3;return uint4((v<<3)|(v>>2),(c.a>>7)*255);}
 return (c>>4)*17;
}
uint4 sampleSource(device const uchar* src,texture2d<float,access::read> image,constant Params& p,uint x,uint y) {
 if(p.useImage)return quantize(uint4(rint(image.read(uint2(x+p.sourceX,y+p.sourceY)*p.resolutionScale+p.resolutionScale/2)*255.0f)),p.inf);
 return decode(src,offset(x,y,p.iw,p.inLinear)*bytes(p.inf),p.inf);
}
kernel void display_transfer(device const uchar* src [[buffer(0)]],device uchar* dst [[buffer(1)]],constant Params& p [[buffer(2)]],texture2d<float,access::read> image [[texture(0)]],uint2 id [[thread_position_in_grid]]) {
 uint x=id.x,y=id.y;if(x>=p.ow||y>=p.oh)return;
 uint sx=x<<(p.scale!=0),sy=y<<(p.scale==2);
 uint4 c=sampleSource(src,image,p,sx,sy);
 if(p.scale==1)c=(c+sampleSource(src,image,p,sx+1,sy))/2;
 if(p.scale==2)c=(c+sampleSource(src,image,p,sx+1,sy)+sampleSource(src,image,p,sx,sy+1)+sampleSource(src,image,p,sx+1,sy+1))/4;
 uint oy=p.flip?p.oh-y-1:y;
 encode(dst,offset(x,oy,p.ow,p.outLinear)*bytes(p.outf),p.outf,c);
}
)MSL";
            NSError* error=nil;auto options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion2_3;options.fastMathEnabled=NO;
            auto library=[impl->device newLibraryWithSource:@(code) options:options error:&error];Require(library!=nil,Error(error));
            impl->transferPipeline=[impl->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"display_transfer"] error:&error];Require(impl->transferPipeline!=nil,Error(error));
        }
        [impl->activeEncoder endEncoding];impl->activeEncoder=nil;
        auto command=impl->activeCommand;impl->activeCommand=nil;impl->activeDraws=0;
        if(!command)command=[impl->queue commandBuffer];
        uint32_t zero=0;
        auto input=[impl->device newBufferWithBytes:p.useImage?static_cast<const void*>(&zero):static_cast<const void*>(source.data()) length:p.useImage?4:sourceSize options:MTLResourceStorageModeShared];
        // Outputs cannot share scratch storage: several transfers may be in flight.
        auto output=[impl->device newBufferWithLength:outputSize options:MTLResourceStorageModeShared];Require(input && output,"Display transfer allocation failed");
        id<MTLTexture> image=impl->cachedColor;
        if(!image) {auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];d.usage=MTLTextureUsageShaderRead;image=[impl->device newTextureWithDescriptor:d];}
        auto encoder=[command computeCommandEncoder];[encoder setComputePipelineState:impl->transferPipeline];
        [encoder setBuffer:input offset:0 atIndex:0];[encoder setBuffer:output offset:0 atIndex:1];[encoder setBytes:&p length:sizeof(p) atIndex:2];[encoder setTexture:image atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(p.outputWidth,p.outputHeight,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        id<MTLBuffer> displayOutput=nil;
        if(p.useImage && p.resolutionScale>1 && p.outputLinear) {
            // Preserve high-resolution pixels independently from the native-size
            // packed result that guest CPU reads must observe.
            const unsigned scale=p.resolutionScale;
            auto high=p;high.inputWidth*=scale;high.inputHeight*=scale;
            high.outputWidth*=scale;high.outputHeight*=scale;
            high.sourceX*=scale;high.sourceY*=scale;high.resolutionScale=1;
            displayOutput=[impl->device newBufferWithLength:outputSize*scale*scale options:MTLResourceStorageModeShared];
            Require(displayOutput!=nil,"Scaled display transfer allocation failed");
            [encoder setBuffer:displayOutput offset:0 atIndex:1];[encoder setBytes:&high length:sizeof(high) atIndex:2];
            [encoder dispatchThreads:MTLSizeMake(high.outputWidth,high.outputHeight,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        }
        [encoder endEncoding];
        [command commit];++impl->stats.commandBuffers;
        impl->pending.push_back(command);
        auto ticket=std::make_shared<TransferTicket>();
        ticket->queue=impl->queue;ticket->command=command;ticket->output=output;ticket->size=outputSize;
        ticket->displayOutput=displayOutput;ticket->displayScale=displayOutput?p.resolutionScale:1;
        return ticket;
    }
}
std::shared_ptr<TransferTicket> DrawContext::EnqueueScanout(const std::shared_ptr<TransferTicket>& source,
    unsigned width,unsigned height,unsigned format,std::array<uint8_t,4> tail,bool highResolution) {
    @autoreleasepool {
        const unsigned bpp=format==0?4:format==1?3:2;
        Require(source && source->queue==impl->queue && width && height && width<=4096 && height<=4096 && format<5 &&
            source->size==size_t(width)*height*bpp,"Invalid resident scanout");
        const unsigned scale=highResolution?source->displayScale:1;
        auto input=scale>1?source->displayOutput:source->output;
        width*=scale;height*=scale;
        if(!impl->scanoutPipeline) {
            static const char* code=R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Params {uint width,height,format;uchar tail[4];};
kernel void scanout(device const uchar* source [[buffer(0)]],device uchar4* output [[buffer(1)]],constant Params& p [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=p.width || pos.y>=p.height)return;
    uint bpp=p.format==0?4:p.format==1?3:2;
    uint pixel=pos.y*p.width+p.width-pos.x;
    device const uchar* s=source+pixel*bpp;
    uchar4 raw=pixel==p.width*p.height?uchar4(p.tail[0],p.tail[1],p.tail[2],p.tail[3]):uchar4(0);
    // Conditional loads avoid reading the unwritten one-past destination pixel.
    if(pixel<p.width*p.height)for(uint i=0;i<bpp;++i)raw[i]=s[i];
    uchar4 c;
    if(p.format==0)c=raw.wzyx;
    else if(p.format==1)c=uchar4(raw.z,raw.y,raw.x,255);
    else {
        uint v=uint(raw.x)|(uint(raw.y)<<8);
        if(p.format==2) {uint r=(v>>11)&31,g=(v>>5)&63,b=v&31;c=uchar4((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2),255);}
        else if(p.format==3) {uint r=(v>>11)&31,g=(v>>6)&31,b=(v>>1)&31;c=uchar4((r<<3)|(r>>2),(g<<3)|(g>>2),(b<<3)|(b>>2),(v&1)?255:0);}
        else c=uchar4(((v>>12)&15)*17,((v>>8)&15)*17,((v>>4)&15)*17,(v&15)*17);
    }
    output[pos.x*p.height+pos.y]=c;
}
)MSL";
            NSError* error=nil;auto options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion2_3;
            auto library=[impl->device newLibraryWithSource:@(code) options:options error:&error];Require(library!=nil,Error(error));
            impl->scanoutPipeline=[impl->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"scanout"] error:&error];Require(impl->scanoutPipeline!=nil,Error(error));
        }
        struct Params {uint32_t width,height,format;std::array<uint8_t,4> tail;};
        Params params{width,height,format,tail};
        auto command=[impl->queue commandBuffer];
        auto output=[impl->device newBufferWithLength:size_t(width)*height*4 options:MTLResourceStorageModeShared];
        Require(command && output,"Scanout allocation failed");
        auto encoder=[command computeCommandEncoder];[encoder setComputePipelineState:impl->scanoutPipeline];
        [encoder setBuffer:input offset:0 atIndex:0];[encoder setBuffer:output offset:0 atIndex:1];
        [encoder setBytes:&params length:sizeof(params) atIndex:2];
        [encoder dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
        [command commit];++impl->stats.commandBuffers;impl->pending.push_back(command);
        auto ticket=std::make_shared<TransferTicket>();ticket->queue=impl->queue;ticket->command=command;ticket->output=output;ticket->size=size_t(width)*height*4;
        return ticket;
    }
}
unsigned DrawContext::PresentationScale(const std::shared_ptr<TransferTicket>& ticket) const {
    return ticket?ticket->displayScale:1;
}
std::vector<uint8_t> DrawContext::ResolveTransfer(const std::shared_ptr<TransferTicket>& ticket) {
    Require(bool(ticket),"Missing display transfer ticket");
    @autoreleasepool {
        const auto waitStart=std::chrono::steady_clock::now();
        [ticket->command waitUntilCompleted];
        Require(ticket->command.status==MTLCommandBufferStatusCompleted,Error(ticket->command.error));
        if(impl->profilingEnabled) {
            impl->stats.gpuWaitSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-waitStart).count();
            impl->stats.readbackBytes+=ticket->size;
        }
        // Queue order means earlier commands are complete too. Remove only
        // completed entries; later queued draws may still be running.
        auto end=std::remove_if(impl->pending.begin(),impl->pending.end(),[&](auto command) {
            if(command.status!=MTLCommandBufferStatusCompleted)return false;
            if(impl->profilingEnabled)impl->stats.gpuSeconds+=std::max(0.0,command.GPUEndTime-command.GPUStartTime);
            return true;
        });
        impl->pending.erase(end,impl->pending.end());
        std::vector<uint8_t> result(ticket->size);
        std::memcpy(result.data(),ticket->output.contents,ticket->size);
        return result;
    }
}
std::vector<uint8_t> DrawContext::Transfer(const DisplayTransfer& p,std::span<const uint8_t> source) {
    return ResolveTransfer(EnqueueTransfer(p,source));
}

}

namespace AzaharMetal {
std::shared_ptr<NativeTexture> DrawContext::SnapshotSurface(unsigned x,unsigned y,unsigned width,unsigned height,
    bool depth,bool dirtyDepth,bool dirtyStencil,std::span<const uint8_t> original,unsigned resolutionScale) {
    @autoreleasepool {
        Require(resolutionScale>=1 && resolutionScale<=4 && impl->cachedColor && width && height && (uint64_t(x)+width)*resolutionScale<=impl->cachedColor.width && (uint64_t(y)+height)*resolutionScale<=impl->cachedColor.height,"Surface snapshot outside owner");
        Require(!depth || (impl->cachedDepth && ((dirtyDepth && dirtyStencil)||original.size()==size_t(width)*height*4)),"Missing unchanged guest depth/stencil components");
        if(!impl->aliasPipeline) {
            static const char* source=R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Parameters { uint width,height,depthStride,stencilStride,depthPlane,dirtyDepth,dirtyStencil,x,y,scale,directDepth; };
uint morton(uint2 p) {return (p.x&1)|((p.y&1)<<1)|((p.x&2)<<1)|((p.y&2)<<2)|((p.x&4)<<2)|((p.y&4)<<3);}
// Exactly floor(double(floatDepth)*16777215), without Metal float64 or a
// float32 multiplication rounding up at integer boundaries.
uint packDepth(float value) {
    uint bits=as_type<uint>(clamp(value,0.0f,1.0f));uint exponent=(bits>>23)&255;
    if(exponent==0)return 0;
    // m*(2^24-1) as two uint32 words. Avoid emulated 64-bit multiply
    // while preserving every bit of the previous exact integer result.
    uint m=(bits&0x7fffff)|0x800000;
    uint shifted=(m&255u)<<24;
    uint low=shifted-m,high=(m>>8)-uint(shifted<m);
    uint shift=150-exponent;
    if(shift>=64)return 0;
    if(shift>=32)return high>>(shift-32);
    return (low>>shift)|(high<<(32-shift));
}
kernel void surface_alias(texture2d<float,access::read> color [[texture(0)]],
    texture2d<float,access::write> output [[texture(1)]],
    depth2d<float> depthImage [[texture(2)]],texture2d<uint,access::read> stencilImage [[texture(3)]],
    device const float* depth [[buffer(0)]],device const uchar* stencil [[buffer(1)]],
    device const uchar* original [[buffer(2)]],constant Parameters& p [[buffer(3)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=p.width || pos.y>=p.height)return;
    uint2 guest=uint2(pos.x,p.height-1-pos.y);
    if(!p.depthPlane) {output.write(color.read(guest+uint2(p.x,p.y)),pos);return;}
    uint2 native=guest/p.scale;
    uint offset=((native.y/8)*(p.width/p.scale)*8+(native.x/8)*64+morton(native))*4;
    uint2 sample=guest;
    uint z=p.dirtyDepth?packDepth(p.directDepth?depthImage.read(sample+uint2(p.x,p.y)):depth[sample.y*p.depthStride+sample.x]):uint(original[offset])|(uint(original[offset+1])<<8)|(uint(original[offset+2])<<16);
    uint st=p.dirtyStencil?(p.directDepth?stencilImage.read(sample+uint2(p.x,p.y)).r:stencil[sample.y*p.stencilStride+sample.x]):original[offset+3];
    output.write(float4(st,(z>>16)&255,(z>>8)&255,z&255)/255.0f,pos);
}
)MSL";
            NSError* error=nil;auto options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion2_3;options.fastMathEnabled=NO;
            auto library=[impl->device newLibraryWithSource:@(source) options:options error:&error];Require(library!=nil,Error(error));
            impl->aliasPipeline=[impl->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"surface_alias"] error:&error];Require(impl->aliasPipeline!=nil,Error(error));
        }
        // Close the producing pass before using its attachments. Every lease
        // records creation and last sampling use, including later commands.
        [impl->activeEncoder endEncoding];impl->activeEncoder=nil;
        if(!impl->activeCommand)impl->activeCommand=[impl->queue commandBuffer];
        auto command=impl->activeCommand;
        if(impl->stencilViewParent!=impl->cachedDepth) {
            impl->stencilView=[impl->cachedDepth newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
            impl->stencilViewParent=impl->cachedDepth;impl->stencilViewReadable=bool(impl->stencilView);
        }
        const char* bufferDepth=std::getenv("DSTV_METAL_BUFFER_DEPTH");
        const bool directDepth=impl->stencilViewReadable && (!bufferDepth || std::strcmp(bufferDepth,"0")==0);
        if(!impl->stencilView) {
            auto dummy=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint width:1 height:1 mipmapped:NO];
            dummy.usage=MTLTextureUsageShaderRead;impl->stencilView=[impl->device newTextureWithDescriptor:dummy];
        }
        const unsigned physicalWidth=width*resolutionScale,physicalHeight=height*resolutionScale;
        const unsigned outputWidth=physicalWidth,outputHeight=physicalHeight;
        if(depth) {
            if(directDepth) {++impl->stats.depthTextureSnapshots;impl->stats.avoidedDepthCopyBytes+=uint64_t(physicalWidth)*physicalHeight*((dirtyDepth?4:0)+(dirtyStencil?1:0));}
            else ++impl->stats.depthBufferSnapshots;
        }
        auto result=impl->SnapshotImage(outputWidth,outputHeight);
        const unsigned depthRow=(physicalWidth*4+255)&~255u,stencilRow=(physicalWidth+255)&~255u;
        uint32_t parameters[]={outputWidth,outputHeight,depthRow/4,stencilRow,unsigned(depth),unsigned(dirtyDepth),unsigned(dirtyStencil),x*resolutionScale,y*resolutionScale,resolutionScale,unsigned(directDepth)};
        auto depthBuffer=impl->AliasScratch(impl->aliasDepthScratch,depth&&!directDepth?size_t(depthRow)*physicalHeight:4);
        auto stencilBuffer=impl->AliasScratch(impl->aliasStencilScratch,depth&&!directDepth?size_t(stencilRow)*physicalHeight:4);
        uint32_t zero=0;
        const auto originalBuffer=impl->Upload(original.empty()?4:original.size());
        std::memcpy(static_cast<uint8_t*>(originalBuffer.buffer.contents)+originalBuffer.offset,original.empty()?static_cast<const void*>(&zero):original.data(),original.empty()?4:original.size());
        if(depth && !directDepth && (dirtyDepth || dirtyStencil)) {
            auto blit=[command blitCommandEncoder];
            if(dirtyDepth)[blit copyFromTexture:impl->cachedDepth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x*resolutionScale,y*resolutionScale,0) sourceSize:MTLSizeMake(physicalWidth,physicalHeight,1) toBuffer:depthBuffer destinationOffset:0 destinationBytesPerRow:depthRow destinationBytesPerImage:size_t(depthRow)*physicalHeight options:MTLBlitOptionDepthFromDepthStencil];
            if(dirtyStencil)[blit copyFromTexture:impl->cachedDepth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x*resolutionScale,y*resolutionScale,0) sourceSize:MTLSizeMake(physicalWidth,physicalHeight,1) toBuffer:stencilBuffer destinationOffset:0 destinationBytesPerRow:stencilRow destinationBytesPerImage:size_t(stencilRow)*physicalHeight options:MTLBlitOptionStencilFromDepthStencil];
            [blit endEncoding];
        }
        auto encoder=[command computeCommandEncoder];Require(encoder!=nil,"Surface alias encoder failed");
        [encoder setComputePipelineState:impl->aliasPipeline];[encoder setTexture:impl->cachedColor atIndex:0];[encoder setTexture:result->image atIndex:1];
        [encoder setTexture:impl->cachedDepth atIndex:2];[encoder setTexture:impl->stencilView atIndex:3];
        [encoder setBuffer:depthBuffer offset:0 atIndex:0];[encoder setBuffer:stencilBuffer offset:0 atIndex:1];[encoder setBuffer:originalBuffer.buffer offset:originalBuffer.offset atIndex:2];
        [encoder setBytes:parameters length:sizeof(parameters) atIndex:3];
        [encoder dispatchThreads:MTLSizeMake(outputWidth,outputHeight,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
        return result;
    }
}
}

namespace AzaharMetal {
std::vector<uint8_t> DrawContext::ReadTexture(const std::shared_ptr<NativeTexture>& snapshot) {
    Require(snapshot && snapshot->image,"Missing snapshot for validation");
    if(snapshot->lease && snapshot->lease->queue!=impl->queue)snapshot->lease->foreignUse=true;
    impl->SubmitDraws();
    auto image=snapshot->image;const size_t row=(image.width*4+255)&~size_t(255);
    auto output=[impl->device newBufferWithLength:row*image.height options:MTLResourceStorageModeShared];
    Require(output!=nil,"Validation staging allocation failed");
    auto command=[impl->queue commandBuffer];auto blit=[command blitCommandEncoder];
    [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(image.width,image.height,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*image.height];
    [blit endEncoding];[command commit];
    const auto waitStart=impl->profilingEnabled?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
    [command waitUntilCompleted];
    if(impl->profilingEnabled) {
        ++impl->stats.commandBuffers;impl->stats.readbackBytes+=image.width*image.height*4;
        impl->stats.gpuWaitSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-waitStart).count();
        impl->stats.gpuSeconds+=std::max(0.0,command.GPUEndTime-command.GPUStartTime);
    }
    Require(command.status==MTLCommandBufferStatusCompleted,Error(command.error));
    std::vector<uint8_t> bytes(image.width*image.height*4);
    for(size_t y=0;y<image.height;++y)std::memcpy(bytes.data()+y*image.width*4,static_cast<const uint8_t*>(output.contents)+y*row,image.width*4);
    return bytes;
}
}
