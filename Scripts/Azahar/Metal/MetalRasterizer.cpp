// SPDX-License-Identifier: GPL-2.0-or-later
#include "MetalRasterizer.h"
#include "MetalFramebuffer.h"
#include "MetalResolution.h"
#include "common/settings.h"
#include "MetalCpuProfile.h"
#include "video_core/pica/vertex_loader.h"
#include "core/core.h"
#include "core/memory.h"
#include "video_core/pica/pica_core.h"
#include "video_core/pica/output_vertex.h"
#include "video_core/texture/texture_decode.h"
#include "common/logging/log.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <execinfo.h>
namespace {
std::atomic<uint64_t> nativeBatches{}, fallbackBatches{},vertexBatches{};
bool FeatureEnabled(const char* name, bool defaultValue) {
    const char* value=std::getenv(name);
    return value ? std::strcmp(value,"0")!=0 : defaultValue;
}
bool MetalProfilingEnabled() {
    static const bool enabled = [] {
        const char* value = std::getenv("DSTV_METAL_PROFILE");
        return value && value[0] != '\0' && std::strcmp(value, "0") != 0;
    }();
    return enabled;
}
}
extern "C" __attribute__((visibility("default"))) uint64_t dstv_metal_native_batches() { return nativeBatches.load(); }
extern "C" __attribute__((visibility("default"))) uint64_t dstv_metal_fallback_batches() { return fallbackBatches.load(); }
extern "C" __attribute__((visibility("default"))) uint64_t dstv_metal_vertex_batches() { return vertexBatches.load(); }
namespace AzaharMetal {
Renderer::Renderer(Core::System& system, Pica::PicaCore& pica, Frontend::EmuWindow& window)
    : SwRenderer::RendererSoftware(system, pica, window),
      native(system.Memory(), pica, *SwRenderer::RendererSoftware::Rasterizer()) {}
HybridRenderer::HybridRenderer(Core::System& system, Pica::PicaCore& pica,
                               Frontend::EmuWindow& window, Frontend::EmuWindow* secondaryWindow)
    : Vulkan::RendererVulkan(system, pica, window, secondaryWindow),
      native(system.Memory(), pica,
             *Vulkan::RendererVulkan::Rasterizer()) {}
void HybridRenderer::SwapBuffers() {
    native.FlushDisplayRegions();
    native.ReportProfileFrame();
    Vulkan::RendererVulkan::SwapBuffers();
}
Rasterizer::Rasterizer(Memory::MemorySystem& memory, Pica::PicaCore& pica,
                       VideoCore::RasterizerInterface& fallback)
    : RasterizerAccelerated(memory, pica), fallback(fallback), context(std::make_unique<DrawContext>()) {
    nativeBatches = 0; fallbackBatches = 0; vertexBatches=0;
    profileEnabled = MetalProfilingEnabled();
    cpuProfile={};cpuProfileSequence=0;
    printf("Metal experiment: GPU vertices=%d compute transfers=%d\n",FeatureEnabled("DSTV_METAL_GPU_VERTICES",true),FeatureEnabled("DSTV_METAL_TRANSFERS",true));
    context->SetProfilingEnabled(profileEnabled);
    profileStart = std::chrono::steady_clock::now();
    profileNativeStart = nativeBatches.load();
    profileFallbackStart = fallbackBatches.load();
    lookupTables.lightingFog.resize(24 * 256 + 128);
    printf("DualScreenTV native Metal prototype: PICA vertex programs on GPU where supported; CPU geometry fallback; Metal rasterization, fragment, depth/stencil and blending on GPU; scaled targets; explicit fallback\n");
}
Rasterizer::~Rasterizer() { pendingTransfers.clear(); ReleaseTarget(); }
void Rasterizer::ReleaseTarget() {
    cachedRanges.clear(); retained = false;
    SyncCachedPages();
    surfaceOwner.Invalidate();
    wroteColor = wroteDepth = wroteStencil = false;
    context->DiscardFrame();
}
void Rasterizer::ClearAll(bool flush) {
    displayScreens={};
    if (flush) FlushAll(); else {pendingTransfers.clear();ReleaseTarget();}
    fallback.ClearAll(flush);
    original.clear(); vertex_batch.clear(); programs.clear(); decodedTextures.clear(); decodedBytes=0; vertexPrograms.clear(); vertexProgramCount=0; rejectedVertexPrograms.clear();
}
void Rasterizer::SyncCachedPages() {
    // MemorySystem uses boolean page markers, not reference counts. Build the
    // union of target and transfer owners before changing any page attribute.
    std::vector<PAddr> desired;desired.reserve(markedPages.size()+128);
    for(auto [address,bytes]:cachedRanges)TransferRange{address,bytes}.AddPages(desired);
    for(const auto& transfer:pendingTransfers)transfer.range.AddPages(desired);
    std::sort(desired.begin(),desired.end());
    desired.erase(std::unique(desired.begin(),desired.end()),desired.end());
    for(auto page:markedPages)if(!std::binary_search(desired.begin(),desired.end(),page))memory.RasterizerMarkRegionCached(page,4096,false);
    for(auto page:desired)if(!std::binary_search(markedPages.begin(),markedPages.end(),page))memory.RasterizerMarkRegionCached(page,4096,true);
    markedPages=std::move(desired);
}
void Rasterizer::ResolveTransfers(PAddr address,u32 size,bool discardCovered) {
    bool changed=false;
    for(auto it=pendingTransfers.begin();it!=pendingTransfers.end();) {
        if(!it->range.Overlaps(address,size)) {++it;continue;}
        // A complete CPU overwrite makes the old GPU result dead. Partial
        // writes must first materialise all untouched destination bytes.
        if(it->dirty && (!discardCovered || !it->range.CoveredBy(address,size))) {
            if(profileEnabled)++profileStats.transfersMaterialised;
            auto bytes=context->ResolveTransfer(it->ticket);
            std::memcpy(memory.GetPhysicalPointer(it->range.address),bytes.data(),bytes.size());
            it->dirty=false;
        } else if(it->dirty && profileEnabled)++profileStats.transfersDiscarded;
        // A read makes the surface clean, not invalid. Keep its high-resolution
        // display copy until an actual write, matching Vulkan's surface cache.
        if(discardCovered) {it=pendingTransfers.erase(it);changed=true;}else ++it;
    }
    if(changed)SyncCachedPages();
}
void Rasterizer::ResolveAllTransfers() {
    for(const auto& transfer:pendingTransfers)if(transfer.dirty) {
        auto bytes=context->ResolveTransfer(transfer.ticket);
        std::memcpy(memory.GetPhysicalPointer(transfer.range.address),bytes.data(),bytes.size());
        if(profileEnabled)++profileStats.transfersMaterialised;
    }
    pendingTransfers.clear();SyncCachedPages();
}
void Rasterizer::InvalidateRegion(PAddr address,u32 size) {
    ResolveTransfers(address,size,true);
    if(profileEnabled && surfaceOwner.Overlaps(address,size))++profileStats.surfaceInvalidations;
    // Materialise BEFORE a partial CPU write, preserving every untouched byte.
    // Immutable GPU snapshots belong to already-encoded draws, never to guest RAM.
    // This callback runs BEFORE a CPU/DMA write. Bytes completely covered by
    // that write are dead; materialise only dirty components outside its range.
    if(surfaceOwner.valid) {
        if(surfaceOwner.color.range.CoveredBy(address,size)) {wroteColor=false;surfaceOwner.dirtyColor={};}
        if(surfaceOwner.depth.range.CoveredBy(address,size)) {wroteDepth=wroteStencil=false;surfaceOwner.dirtyDepth={};surfaceOwner.dirtyStencil={};}
    }
    FlushRegion(address,size);
}
void Rasterizer::FlushRegion(PAddr address,u32 size) {
    ResolveTransfers(address,size);
    // Page markers only trap CPU accesses; ownership is byte-exact, as in
    // Vulkan's interval cache. Adjacent buffers can share a marked page without
    // sharing a single byte. Flushing the whole target here destroys residency.
    if(surfaceOwner.Overlaps(address,size)) {
        if(profileEnabled)++profileStats.regionFlushes;
        if(profileEnabled && FeatureEnabled("DSTV_METAL_TRACE_FLUSH",false) && totalProfileFrames>=4000 && tracedFlushes<16) {
            void* callers[8];const int count=backtrace(callers,8);++tracedFlushes;
            printf("Metal flush trace: address=%u size=%u dirty=%d,%d,%d",address,size,wroteColor,wroteDepth,wroteStencil);
            for(int i=0;i<count;++i)printf(" %p",callers[i]);printf("\n");
        }
        FlushTarget();
    }
}
void Rasterizer::FlushAll() {
    ResolveAllTransfers();
    FlushTarget();
}
Frame Rasterizer::ReadGuestFrame(bool color,bool depth,bool stencil) {
    return Resolution::Downsample(context->ReadFrame(color,depth,stencil),renderScale);
}
void Rasterizer::FlushTarget() {
    if(!retained) return;
    if (!wroteColor && !wroteDepth && !wroteStencil) {
        ReleaseTarget();
        return;
    }
    if(profileEnabled) {++profileStats.readbacks;++profileStats.surfaceMaterialisations;}
    auto result=ReadGuestFrame(wroteColor, wroteDepth, wroteStencil);
    const auto framebufferExportStart = profileEnabled ? std::chrono::steady_clock::now()
                                                       : std::chrono::steady_clock::time_point{};
    const auto& fb=savedRegs.framebuffer;
    FramebufferTransfer::Export(result,memory.GetPhysicalPointer(fb.GetColorBufferPhysicalAddress()),memory.GetPhysicalPointer(fb.GetDepthBufferPhysicalAddress()),fb.color_format,fb.depth_format,wroteColor,wroteDepth,wroteStencil);
    if (profileEnabled) {
        profileStats.framebufferExportSeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - framebufferExportStart).count();
    }
    for (const auto& [address, size] : cachedRanges) fallback.InvalidateRegion(address, size);
    ReleaseTarget();
}
void Rasterizer::FlushDisplayRegions() {
    for(const auto& display:pica.regs.framebuffer_config) {
        const PAddr address=display.active_fb==0?display.address_left1:display.address_left2;
        FlushRegion(address,display.stride*display.height);
    }
}
void Rasterizer::PrepareDisplay() {
    std::array<std::shared_ptr<TransferTicket>,2> scanouts;
    for(unsigned i=0;i<2;++i) {
        auto& cached=displayScreens[i];cached.valid=false;
        const auto& fb=pica.regs.framebuffer_config[i];
        const auto& fill=i==0?pica.regs_lcd.color_fill_top:pica.regs_lcd.color_fill_bottom;
        if(fill.is_enabled || !FeatureEnabled("DSTV_METAL_RESIDENT_SCANOUT",true))continue;
        const PAddr address=fb.active_fb==0?fb.address_left1:fb.address_left2;
        const unsigned format=unsigned(fb.color_format.Value()),bpp=format==0?4:format==1?3:2;
        if(format>=5 || !fb.stride || fb.stride%bpp)continue;
        const unsigned width=fb.stride/bpp,height=fb.height;
        const uint64_t bytes=uint64_t(fb.stride)*height;
        if(!height || bytes>16*1024*1024 || uint64_t(address)+bytes+bpp>uint64_t(UINT32_MAX)+1 || memory.GetPhysicalRef(address).GetSize()<bytes+bpp)continue;
        // Pinned software scanout reads one extra border pixel from guest RAM.
        // Resolve that distinct range before inspecting transfer owners.
        ResolveTransfers(PAddr(uint64_t(address)+bytes),bpp);
        const auto found=std::find_if(pendingTransfers.begin(),pendingTransfers.end(),[&](const auto& t) {
            return t.range.address==address && t.range.bytes==bytes && t.params.outputLinear &&
                t.params.outputWidth==width && t.params.outputHeight==height && t.params.outputFormat==format;
        });
        if(found==pendingTransfers.end())continue;
        std::array<uint8_t,4> tail{};
        std::memcpy(tail.data(),memory.GetPhysicalPointer(address)+bytes,bpp);
        const unsigned scale=context->PresentationScale(found->ticket);
        const bool unchanged=cached.source==found->ticket && cached.tail==tail && cached.screen.width==width*scale && cached.screen.height==height*scale;
        if(profileEnabled) {++profileStats.residentScreens;if(unchanged)++profileStats.cachedScreens;}
        if(!unchanged) {
            cached.source=found->ticket;cached.tail=tail;cached.screen.width=width*scale;cached.screen.height=height*scale;
            scanouts[i]=context->EnqueueScanout(found->ticket,width,height,format,tail,true);
        }
        cached.valid=true;
    }
    // Both screens are queued before waiting. Resolve the last submission first
    // so earlier scanouts are complete without another GPU scheduling round trip.
    for(int i=1;i>=0;--i)if(scanouts[i])displayScreens[i].screen.pixels=context->ResolveTransfer(scanouts[i]);
}
const SwRenderer::ScreenInfo* Rasterizer::BorrowDisplayScreen(VideoCore::ScreenId id) const noexcept {
    const auto& cached=displayScreens[id==VideoCore::ScreenId::Bottom?1:0];
    return cached.valid?&cached.screen:nullptr;
}
bool Rasterizer::LoadDisplay(int i,SwRenderer::ScreenInfo& info) {
    const unsigned id=i==2?1:0;
    const auto& cached=displayScreens[id];
    if(cached.valid) {
        // The compositor borrows BorrowDisplayScreen() directly. Keep fallback
        // metadata current without duplicating the completed pixel vector.
        info.width=cached.screen.width;info.height=cached.screen.height;info.pixels.clear();return true;
    }
    if(profileEnabled)++profileStats.fallbackScreens;
    // Unsupported formats/layouts still use the original CPU scanout. Flush
    // pending owners before that path reads a raw guest-memory pointer.
    const auto& fb=pica.regs.framebuffer_config[id];
    const PAddr address=fb.active_fb==0?fb.address_left1:fb.address_left2;
    FlushRegion(address,fb.stride*fb.height);
    return false;
}
bool Rasterizer::AccelerateFill(const Pica::MemoryFillConfig& config) {
    if(!FeatureEnabled("DSTV_METAL_RESIDENT_FILLS",true) || !retained || !surfaceOwner.valid)return false;
    const uint64_t start=config.GetStartAddress(),end=config.GetEndAddress();
    if(end<=start || surfaceOwner.color.range.Overlaps(surfaceOwner.depth.range.address,surfaceOwner.depth.range.bytes))return false;
    const bool color=start==surfaceOwner.color.range.address && end-start==surfaceOwner.color.range.bytes;
    const bool depth=start==surfaceOwner.depth.range.address && end-start==surfaceOwner.depth.range.bytes;
    if(!color && !depth)return false;
    const unsigned pattern=config.fill_24bit?3u:config.fill_32bit?4u:2u;
    const auto& plane=color?surfaceOwner.color:surfaceOwner.depth;
    if(plane.bytesPerPixel%pattern)return false; // Nonuniform pixel patterns use RAM fallback.
    const auto fill=color?FramebufferTransfer::UniformColorFill(savedRegs.framebuffer.color_format,pattern,config.value_32bit)
                         :FramebufferTransfer::UniformDepthFill(savedRegs.framebuffer.depth_format,pattern,config.value_32bit);
    if(!fill)return false;
    const auto& clear=*fill;
    try {
        context->ClearSurface(clear);
        if(color) {wroteColor=true;surfaceOwner.dirtyColor=plane.range;}
        else {wroteDepth=true;surfaceOwner.dirtyDepth=plane.range;if(clear.stencil) {wroteStencil=true;surfaceOwner.dirtyStencil=plane.range;}}
        fallback.InvalidateRegion(PAddr(start),u32(end-start));
        ++clearBatches;return true;
    } catch(const std::exception& error) {
        if(loggedFailures.size()<96 && loggedFailures.emplace(error.what()).second)printf("Native Metal fill fallback: %s\n",error.what());
        return false;
    }
}
bool Rasterizer::AccelerateDisplayTransfer(const Pica::DisplayTransferConfig& config) {
    if(!FeatureEnabled("DSTV_METAL_TRANSFERS",true))return false;
    const unsigned inf=unsigned(config.input_format.Value()),outf=unsigned(config.output_format.Value()),scale=unsigned(config.scaling.Value());
    if(inf>=5 || outf>=5 || scale>2 || config.block_32 || config.is_texture_copy || (config.input_linear && scale) || (config.flip_vertically && config.crop_input_lines))return false;
    const unsigned iw=config.input_width,ih=config.input_height,ow=config.output_width>>(scale!=0),oh=config.output_height>>(scale==2);
    const bool outputLinear=config.input_linear?bool(config.dont_swizzle):!config.dont_swizzle;
    if(!iw || !ih || !ow || !oh || iw>2048 || ih>2048 || ow>(iw>>(scale!=0)) || oh>(ih>>(scale==2)) || (!config.input_linear && (iw%8 || ih%8)) || (!outputLinear && (ow%8 || oh%8)))return false;
    const PAddr src=config.GetPhysicalInputAddress(),dst=config.GetPhysicalOutputAddress();
    const uint32_t sourceSize=iw*ih*Pica::BytesPerPixel(config.input_format),destSize=ow*oh*Pica::BytesPerPixel(config.output_format);
    if(uint64_t(src)<uint64_t(dst)+destSize && uint64_t(dst)<uint64_t(src)+sourceSize)return false;
    if(memory.GetPhysicalRef(src).GetSize()<sourceSize || memory.GetPhysicalRef(dst).GetSize()<destSize)return false;
    const auto start=std::chrono::steady_clock::now();
    try {
        // Destination writes must resolve overlapping native pages first. The
        // source texture can otherwise stay entirely GPU-resident for this copy.
        ResolveTransfers(dst,destSize,true);
        FlushRegion(dst,destSize);
        const auto& fb=savedRegs.framebuffer;
        using CF=Pica::FramebufferRegs::ColorFormat;
        const unsigned sourceFormat=fb.color_format==CF::RGB565?2u:(fb.color_format==CF::RGB5A1?3u:unsigned(fb.color_format.Value()));
        if(profileEnabled) {
            const auto message="Transfer source "+std::to_string(src)+" "+std::to_string(iw)+"x"+std::to_string(ih)+" fmt="+std::to_string(inf)+" vs cached "+std::to_string(fb.GetColorBufferPhysicalAddress())+" "+std::to_string(unsigned(fb.width))+"x"+std::to_string(unsigned(fb.height)+1)+" fmt="+std::to_string(sourceFormat)+" retained="+std::to_string(retained);
            if(loggedFailures.size()<32 && loggedFailures.emplace(message).second)printf("Metal %s\n",message.c_str());
        }
        const auto alias=retained && !config.input_linear && inf==sourceFormat
            ? surfaceOwner.FindColorTransfer(src,iw,ow<<(scale!=0),oh<<(scale==2),Pica::BytesPerPixel(config.input_format),unsigned(fb.color_format.Value())) : std::nullopt;
        const bool direct=alias.has_value();
        // RAM-only compute copies retain their separate experiment gate. They
        // add upload/readback work and are not needed for resident display copies.
        if(!direct && !FeatureEnabled("DSTV_METAL_MEMORY_TRANSFERS",false))return false;
        // Resident sources are already authoritative GPU surfaces. Do not
        // resolve RAM owners in the nominal input rectangle: its padded extent
        // can overlap unrelated display destinations beyond the sampled area.
        if(!direct) {FlushRegion(src,sourceSize);fallback.FlushRegion(src,sourceSize);}
        DisplayTransfer params{iw,ih,ow,oh,inf,outf,unsigned(config.input_linear),unsigned(outputLinear),scale,unsigned(config.flip_vertically),unsigned(direct),alias?alias->x:0u,alias?alias->y:0u,direct?renderScale:1u};
        const auto input=direct?std::span<const uint8_t>{}:std::span<const uint8_t>{memory.GetPhysicalPointer(src),sourceSize};
        // Same principle as Vulkan's dirty destination surfaces: submit first,
        // materialise only at a guest-memory read/partial-write or presentation.
        // Bound outstanding storage by both count and bytes.
        auto storage=[](const DisplayTransfer& p,size_t bytes) {return bytes*(1+(p.useImage && p.outputLinear && p.resolutionScale>1?p.resolutionScale*p.resolutionScale:0));};
        size_t queuedBytes=0;for(const auto& pending:pendingTransfers)queuedBytes+=storage(pending.params,pending.range.bytes);
        if(pendingTransfers.size()>=8 || queuedBytes+storage(params,destSize)>32*1024*1024)ResolveAllTransfers();
        fallback.InvalidateRegion(dst,destSize);
        auto ticket=context->EnqueueTransfer(params,input);
        const bool validate=direct && FeatureEnabled("DSTV_METAL_VALIDATE_TRANSFERS",false) && validatedTransfers<64 && transferValidationSequence++%17==0;
        std::vector<uint8_t> result;
        if(validate)result=context->ResolveTransfer(ticket);
        if(validate) {
            // Read-only oracle: reference the resident source's decoded colour,
            // then apply upstream integer scaling/packing and destination layout.
            // Neither guest RAM nor ownership/dirty state is changed by ReadFrame.
            const auto reference=ReadGuestFrame(true,false,false);
            std::vector<uint8_t> expected(destSize);
            auto read=[&](unsigned x,unsigned y) {
                const auto* p=reference.rgba.data()+((size_t(y+alias->y)*reference.width+x+alias->x)*4);
                Common::Vec4<u8> value{p[0],p[1],p[2],p[3]};
                std::array<u8,4> packed{};
                FramebufferTransfer::ColorFormat(fb.color_format,[&]<auto Format,unsigned Bpp>() {
                    FramebufferTransfer::Encode<Format>(value,packed.data());value=FramebufferTransfer::Decode<Format>(packed.data());
                });
                return value;
            };
            const auto format=outf==2?CF::RGB565:outf==3?CF::RGB5A1:CF(outf);
            for(unsigned y=0;y<oh;++y)for(unsigned x=0;x<ow;++x) {
                const unsigned sx=x<<(scale!=0),sy=y<<(scale==2);auto value=read(sx,sy);
                if(scale==1)value=((value+read(sx+1,sy))/2).Cast<u8>();
                if(scale==2)value=(((value+read(sx+1,sy))+(read(sx,sy+1)+read(sx+1,sy+1)))/4).Cast<u8>();
                const unsigned oy=config.flip_vertically?oh-y-1:y;
                const unsigned morton=(x&1)|((oy&1)<<1)|((x&2)<<1)|((oy&2)<<2)|((x&4)<<2)|((oy&4)<<3);
                const size_t pixel=outputLinear?size_t(oy)*ow+x:size_t(oy/8)*ow*8+(x/8)*64+morton;
                FramebufferTransfer::ColorFormat(format,[&]<auto Format,unsigned Bpp>() {FramebufferTransfer::Encode<Format>(value,expected.data()+pixel*Bpp);});
            }
            if(result!=expected)throw std::runtime_error("Resident display transfer differs from CPU packing reference");
            ++validatedTransfers;
            printf("Metal display validation passed: %llu source=%u,%u visible=%ux%u stride=%u nominal_height=%u\n",(unsigned long long)validatedTransfers,alias->x,alias->y,ow,oh,iw,ih);
        }
        if(validate)std::memcpy(memory.GetPhysicalPointer(dst),result.data(),result.size());
        else {
            if(profileEnabled)++profileStats.transfersQueued;
            pendingTransfers.push_back({{dst,destSize},std::move(ticket),params});
            SyncCachedPages();
        }
        ++transferBatches;if(direct)++directTransferBatches;
        if(profileEnabled)profileStats.transferSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
        return true;
    }catch(const std::exception& error) {
        if(loggedFailures.size()<32 && loggedFailures.emplace(error.what()).second)printf("Native Metal display transfer fallback: %s\n",error.what());
        return false;
    }
}
void Rasterizer::AddTriangle(const Pica::OutputVertex& a, const Pica::OutputVertex& b, const Pica::OutputVertex& c) {
    RasterizerAccelerated::AddTriangle(a,b,c);
    original.insert(original.end(), {a,b,c});
}
bool Rasterizer::AccelerateDrawBatch(bool is_indexed) {
    if(!FeatureEnabled("DSTV_METAL_GPU_VERTICES",true))return false;
    using T=Pica::PipelineRegs::TriangleTopology;
    const auto& pipeline=regs.pipeline;
    if(pipeline.use_gs==Pica::PipelineRegs::UseGS::Yes || pipeline.num_vertices>100000 || !pipeline.num_vertices) return false;
    const auto topology=pipeline.triangle_topology.Value();
    if(topology!=T::List && topology!=T::Shader && topology!=T::Strip && topology!=T::Fan)return false;
    try {
        // Decompile only supported fragment draws; unsupported effects keep the
        // established CPU-vertex/fallback path before consuming any primitives.
        auto& setup=pica.vs_setup;setup.DoProgramCodeFixup();
        const auto preparationStart=std::chrono::steady_clock::now();
        std::string key;
        auto append=[&](const auto& value) {key.append(reinterpret_cast<const char*>(&value),sizeof(value));};
        const auto codeHash=setup.GetProgramCodeHash(),swizzleHash=setup.GetSwizzleDataHash();
        append(codeHash);append(swizzleHash);
        const u32 entry=regs.vs.main_offset,mask=regs.vs.output_mask;
        append(entry);append(mask);
        append(regs.rasterizer.vs_output_total);append(regs.rasterizer.vs_output_attributes);
        if(rejectedVertexPrograms.contains(key))return false;
        auto group=vertexPrograms.find(key);
        VertexProgram* vertexProgram=nullptr;
        if(group!=vertexPrograms.end())for(auto& record:group->second) {
            // Full tags make hash collisions harmless. Large byte arrays are
            // compared once, instead of at every branch of a string-key tree.
            if(record.code==setup.GetProgramCode() && record.swizzle==setup.GetSwizzleData()) {vertexProgram=&record.program;break;}
        }
        if(!vertexProgram) {
            try {
                auto program=CompileVertex(setup,regs);
                if(vertexProgramCount>=128) {vertexPrograms.clear();vertexProgramCount=0;}
                auto& records=vertexPrograms[key];
                records.push_back({setup.GetProgramCode(),setup.GetSwizzleData(),std::move(program)});
                vertexProgram=&records.back().program;++vertexProgramCount;
            } catch(const std::exception&) {if(rejectedVertexPrograms.size()<128)rejectedVertexPrograms.insert(key);throw;}
        }
        const auto info=AnalyzeVertexArray(is_indexed);
        if(info.Invalid())return true;
        if(info.vs_input_index_max-info.vs_input_index_min>100000)return false;
        const auto base=pipeline.vertex_attributes.GetPhysicalBaseAddress();
        for(const auto& loader:pipeline.vertex_attributes.attribute_loaders)if(loader.component_count) {
            const uint64_t address=uint64_t(base)+loader.data_offset+uint64_t(info.vs_input_index_min)*loader.byte_count;
            const uint64_t bytes=uint64_t(info.vs_input_index_max-info.vs_input_index_min+1)*loader.byte_count;
            if(!loader.byte_count || address>UINT32_MAX || bytes>32*1024*1024 || memory.GetPhysicalRef(PAddr(address)).GetSize()<bytes)return false;
            FlushRegion(PAddr(address),u32(bytes));fallback.FlushRegion(PAddr(address),u32(bytes));
        }
        std::vector<uint32_t> vertexOrder;vertexOrder.reserve(pipeline.num_vertices);
        const auto indexRef=memory.GetPhysicalRef(base+pipeline.index_array.offset);
        const bool wide=pipeline.index_array.format!=0;
        if(is_indexed && indexRef.GetSize()<size_t(pipeline.num_vertices)*(wide?2:1))return false;
        std::vector<uint32_t> mapped(info.vs_input_index_max-info.vs_input_index_min+1,UINT32_MAX);
        hardwareBatch.inputs.clear();hardwareBatch.indices.clear();hardwareBatch.program=vertexProgram;
        Pica::VertexLoader loader(memory,pipeline);
        for(unsigned index=0;index<pipeline.num_vertices;++index) {
            uint32_t vertex=pipeline.vertex_offset+index;
            if(is_indexed) {if(wide) {uint16_t v;std::memcpy(&v,indexRef.GetPtr()+index*2,2);vertex=v;}else vertex=indexRef.GetPtr()[index];}
            auto& entry=mapped[vertex-info.vs_input_index_min];
            if(entry==UINT32_MAX) {
                Pica::AttributeBuffer input{};loader.LoadVertex(base,index,vertex,input,pica.input_default_attributes);
                std::array<float,64> registers{};
                for(unsigned attribute=0;attribute<=regs.vs.max_input_attribute_index;++attribute) {
                    const unsigned reg=regs.vs.GetRegisterForAttribute(attribute);
                    for(unsigned c=0;c<4;++c)registers[reg*4+c]=input[attribute][c].ToFloat32();
                }
                entry=hardwareBatch.inputs.size();hardwareBatch.inputs.push_back(registers);
            }
            vertexOrder.push_back(entry);
        }
        if(topology==T::List || topology==T::Shader)hardwareBatch.indices=vertexOrder;
        else for(unsigned i=2;i<vertexOrder.size();++i) {
            const unsigned a=topology==T::Fan?0:((i&1)?i-1:i-2);
            const unsigned b=topology==T::Fan?i-1:((i&1)?i-2:i-1);
            hardwareBatch.indices.insert(hardwareBatch.indices.end(),{vertexOrder[a],vertexOrder[b],vertexOrder[i]});
        }
        if(hardwareBatch.indices.empty())return true;
        hardwareBatch.uniforms.SetFromRegs(setup);
        hardwareActive=true;
        const auto drawStart=std::chrono::steady_clock::now();
        if(profileEnabled)profileStats.hardwarePreparationSeconds+=std::chrono::duration<double>(drawStart-preparationStart).count();
        NativeDraw();
        if(profileEnabled)profileStats.maxBatchSeconds=std::max(profileStats.maxBatchSeconds,std::chrono::duration<double>(std::chrono::steady_clock::now()-preparationStart).count());
        if(profileEnabled)profileStats.hardwareDrawSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-drawStart).count();
        hardwareActive=false;++hardwareBatches;++vertexBatches;++nativeBatches;
        return true;
    } catch(const std::exception& error) {
        hardwareActive=false;
        if(profileEnabled)++vertexReplayReasonCounts[error.what()];
        FlushAll();
        if(loggedFailures.size()<32 && loggedFailures.emplace(error.what()).second)printf("Native Metal GPU vertex fallback: %s\n",error.what());
        return false;
    }
}
void Rasterizer::DrawTriangles() {
    if (vertex_batch.empty()) return;
    const auto nativeDrawStart = profileEnabled ? std::chrono::steady_clock::now()
                                                : std::chrono::steady_clock::time_point{};
    try { NativeDraw(); ++nativeBatches; }
    catch (const std::exception& error) {
        const auto fallbackStart=profileEnabled?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
        FlushAll();
        ++fallbackBatches;
        ++fallbackReasonCounts[error.what()];
        if (loggedFailures.size()<32 && loggedFailures.emplace(error.what()).second) {
            printf("Native Metal batch fallback: %s\n", error.what());
        }
        // NativeDraw only changes guest RAM after a successful GPU completion.
        for (size_t i = 0; i < original.size(); i += 3) fallback.AddTriangle(original[i],original[i+1],original[i+2]);
        fallback.DrawTriangles();
        if(profileEnabled)profileStats.fallbackReplaySeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-fallbackStart).count();
    }
    if (profileEnabled) {
        profileStats.maxBatchSeconds=std::max(profileStats.maxBatchSeconds,std::chrono::duration<double>(std::chrono::steady_clock::now()-nativeDrawStart).count());
        profileStats.batchWallSeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - nativeDrawStart).count();
    }
    original.clear(); vertex_batch.clear();
}
void Rasterizer::ReportProfileFrame() {
    if (!profileEnabled) return;
    ++profileFrames;++totalProfileFrames;
    if (std::chrono::steady_clock::now() - profileStart >= std::chrono::seconds(5)) {
        PrintProfile();
    }
}
void Rasterizer::PrintProfile() {
    const auto now = std::chrono::steady_clock::now();
    const double elapsed = std::chrono::duration<double>(now - profileStart).count();
    const double frames = static_cast<double>(std::max<uint64_t>(profileFrames, 1));
    const Stats stats = context->TakeMeasurements();
    const auto nativeNow = nativeBatches.load();
    const auto fallbackNow = fallbackBatches.load();
    const auto perFrame = [frames](double seconds) { return seconds * 1000.0 / frames; };
    std::printf(
        "Metal profile: %.2fs frames=%llu native=%llu fallback=%llu draws=%llu cmd=%llu "
        "pipeline=%llu/%llu gpu_ms/frame=%.3f encode_ms/frame=%.3f wait_ms/frame=%.3f "
        "batch_wall_ms/frame=%.3f "
        "readback_ms/frame=%.3f fb_import_ms/frame=%.3f fb_export_ms/frame=%.3f fb_upload_prepare_ms/frame=%.3f "
        "texture_prep_ms/frame=%.3f texture_upload_ms/frame=%.3f lut_upload_ms/frame=%.3f "
        "shader_compile_ms/frame=%.3f fallback_sync_ms/frame=%.3f region_flush_ms/frame=%.3f "
        "pipeline_build_ms/frame=%.3f target_alloc_ms/frame=%.3f vertex_copy_ms/frame=%.3f "
        "vertex_buffer_ms/frame=%.3f lookup_convert_ms/frame=%.3f fb_upload=%lluB/frame "
        "readback=%lluB/frame texture_upload=%lluB/frame lut_upload=%lluB/frame unused_texture_skips=%llu/frame\n",
        elapsed, static_cast<unsigned long long>(profileFrames),
        static_cast<unsigned long long>(nativeNow - profileNativeStart),
        static_cast<unsigned long long>(fallbackNow - profileFallbackStart),
        static_cast<unsigned long long>(stats.draws),
        static_cast<unsigned long long>(stats.commandBuffers),
        static_cast<unsigned long long>(stats.pipelineBuilds),
        static_cast<unsigned long long>(stats.pipelineHits), perFrame(stats.gpuSeconds),
        perFrame(stats.cpuEncodeSeconds), perFrame(stats.gpuWaitSeconds),
        perFrame(profileStats.batchWallSeconds),
        perFrame(stats.readbackWallSeconds), perFrame(profileStats.framebufferImportSeconds),
        perFrame(profileStats.framebufferExportSeconds), perFrame(stats.framebufferUploadSeconds),
        perFrame(profileStats.texturePreparationSeconds), perFrame(stats.textureUploadSeconds),
        perFrame(stats.lutUploadSeconds), perFrame(profileStats.shaderCompileSeconds),
        perFrame(profileStats.fallbackSyncSeconds), perFrame(profileStats.regionFlushSeconds),
        perFrame(stats.pipelineBuildSeconds),
        perFrame(stats.targetAllocationSeconds), perFrame(profileStats.vertexCopySeconds),
        perFrame(stats.vertexBufferSeconds), perFrame(profileStats.lookupConversionSeconds),
        static_cast<unsigned long long>(stats.framebufferUploadBytes / frames),
        static_cast<unsigned long long>(stats.readbackBytes / frames),
        static_cast<unsigned long long>(stats.textureUploadBytes / frames),
        static_cast<unsigned long long>(stats.lutUploadBytes / frames),
        static_cast<unsigned long long>(profileStats.unusedTextureSkips / frames));
    printf("Metal resource reuse: upload_alloc=%llu upload_reuse=%llu readback_alloc=%llu readback_reuse=%llu target_alloc=%llu target_reuse=%llu\n",
        (unsigned long long)stats.uploadBufferAllocations,(unsigned long long)stats.uploadBufferReuses,
        (unsigned long long)stats.readbackBufferAllocations,(unsigned long long)stats.readbackBufferReuses,
        (unsigned long long)stats.targetAllocations,(unsigned long long)stats.targetReuses);
    for (const auto& [reason, count] : fallbackReasonCounts) {
        std::printf("Metal profile fallback reason: count=%llu reason=%s\n",
                    static_cast<unsigned long long>(count), reason.c_str());
    }
    printf("\nMetal hardware vertex batches total: %llu prep_ms/frame=%.3f draw_ms/frame=%.3f\n",static_cast<unsigned long long>(hardwareBatches),perFrame(profileStats.hardwarePreparationSeconds),perFrame(profileStats.hardwareDrawSeconds));
    printf("Metal texture resources: alloc=%llu white_reuse=%llu\n",(unsigned long long)stats.textureAllocations,(unsigned long long)stats.whiteTextureReuses);
    printf("Metal alias resources: snapshot_alloc=%llu snapshot_reuse=%llu scratch_alloc=%llu\n",(unsigned long long)stats.snapshotTextureAllocations,(unsigned long long)stats.snapshotTextureReuses,(unsigned long long)stats.aliasScratchAllocations);
    printf("Metal depth source: texture_snapshots=%llu buffer_snapshots=%llu avoided_plane_copy_bytes=%llu\n",(unsigned long long)stats.depthTextureSnapshots,(unsigned long long)stats.depthBufferSnapshots,(unsigned long long)stats.avoidedDepthCopyBytes);
    for(const auto& [reason,count]:vertexReplayReasonCounts)
        printf("Metal GPU vertex replay reason: count=%llu reason=%s\n",(unsigned long long)count,reason.c_str());
    printf("Metal deferred ownership: queued=%llu materialised=%llu discarded=%llu resident_screens=%llu cached_screens=%llu fallback_screens=%llu\n",
        (unsigned long long)profileStats.transfersQueued,(unsigned long long)profileStats.transfersMaterialised,
        (unsigned long long)profileStats.transfersDiscarded,(unsigned long long)profileStats.residentScreens,
        (unsigned long long)profileStats.cachedScreens,(unsigned long long)profileStats.fallbackScreens);
    printf("Metal resident fills total: %llu\n",(unsigned long long)clearBatches);
    printf("Metal display transfers total: %llu direct_GPU_source=%llu ms/frame=%.3f\n",static_cast<unsigned long long>(transferBatches),static_cast<unsigned long long>(directTransferBatches),perFrame(profileStats.transferSeconds));
    printf("Metal CPU stages: batches=%llu vertices=%llu shader_invocations=%llu geometry_batches=%llu total_ms/frame=%.3f sampled_batches=%llu sampled_shader_us/invocation=%.3f sampled_geometry_us/submission=%.3f\n",
        (unsigned long long)cpuProfile.batches,(unsigned long long)cpuProfile.vertices,
        (unsigned long long)cpuProfile.invocations,(unsigned long long)cpuProfile.geometryBatches,
        perFrame(cpuProfile.totalSeconds),(unsigned long long)cpuProfile.sampledBatches,
        cpuProfile.sampledInvocations?cpuProfile.sampledVertexSeconds*1e6/cpuProfile.sampledInvocations:0,
        cpuProfile.sampledSubmissions?cpuProfile.sampledGeometrySeconds*1e6/cpuProfile.sampledSubmissions:0);
    printf("Metal sync causes: region_flush=%llu target_switch=%llu readbacks=%llu texture_hits=%llu texture_misses=%llu fallback_ms/frame=%.3f max_batch_ms=%.3f\n",
        (unsigned long long)profileStats.regionFlushes,(unsigned long long)profileStats.targetSwitches,
        (unsigned long long)profileStats.readbacks,(unsigned long long)profileStats.textureHits,
        (unsigned long long)profileStats.textureMisses,perFrame(profileStats.fallbackReplaySeconds),profileStats.maxBatchSeconds*1000);
    printf("Metal surface cache: enabled=%d hits=%llu misses=%llu overlap_misses=%llu gpu_copies=%llu estimated_avoided_readback_bytes=%llu invalidations=%llu materialisations=%llu copy_encode_ms/frame=%.3f sync_wait_ms/frame=%.3f\n",
        FeatureEnabled("DSTV_METAL_SURFACE_CACHE",false),(unsigned long long)profileStats.surfaceHits,
        (unsigned long long)profileStats.surfaceMisses,(unsigned long long)profileStats.surfaceOverlapMisses,
        (unsigned long long)profileStats.surfaceCopies,(unsigned long long)profileStats.avoidedReadbackBytes,
        (unsigned long long)profileStats.surfaceInvalidations,(unsigned long long)profileStats.surfaceMaterialisations,
        perFrame(profileStats.surfaceCopySeconds),perFrame(stats.gpuWaitSeconds));
    cpuProfile={};
    profileStart = now;
    profileFrames = 0;
    profileNativeStart = nativeNow;
    profileFallbackStart = fallbackNow;
    profileStats = {};
    fallbackReasonCounts.clear();vertexReplayReasonCounts.clear();
}
void Rasterizer::NativeDraw() {
    using F = Pica::FramebufferRegs;
    using TC = Pica::TexturingRegs::TextureConfig;
    const unsigned requestedScale=std::clamp<unsigned>(Settings::values.resolution_factor.GetValue(),1,4);
    if(requestedScale!=renderScale) {FlushTarget();renderScale=requestedScale;displayScreens={};printf("Metal render scale: %ux\n",renderScale);}
    const auto& fb = regs.framebuffer.framebuffer;
    const unsigned width = fb.width, height = fb.height + 1;
    if (!width || width > 1024 || height > 1024 || width % 8 || height % 8)
        throw std::runtime_error("non-tiled framebuffer dimensions");
    if (regs.framebuffer.IsShadowRendering()) throw std::runtime_error("shadow target");
    const unsigned colorBpp = Pica::BytesPerPixel(Pica::PixelFormat(fb.color_format.Value()));
    const unsigned depthBpp = F::BytesPerDepthPixel(fb.depth_format);
    if (!colorBpp || !depthBpp || memory.GetPhysicalRef(fb.GetColorBufferPhysicalAddress()).GetSize() < size_t(width)*height*colorBpp || memory.GetPhysicalRef(fb.GetDepthBufferPhysicalAddress()).GetSize() < size_t(width)*height*depthBpp)
        throw std::runtime_error("invalid framebuffer range");
    const auto& saved=savedRegs.framebuffer;
    if(retained && (saved.width!=fb.width || saved.height!=fb.height || saved.color_format!=fb.color_format || saved.depth_format!=fb.depth_format || saved.GetColorBufferPhysicalAddress()!=fb.GetColorBufferPhysicalAddress() || saved.GetDepthBufferPhysicalAddress()!=fb.GetDepthBufferPhysicalAddress())) {
        if(profileEnabled)++profileStats.targetSwitches;
        FlushTarget();
    }
    if (!retained) {
        ResolveTransfers(fb.GetColorBufferPhysicalAddress(),u32(size_t(width)*height*colorBpp));
        ResolveTransfers(fb.GetDepthBufferPhysicalAddress(),u32(size_t(width)*height*depthBpp));
        // Import preserved bytes, then retire clean aliases before this target
        // becomes a new GPU writer of their guest-memory ranges.
        ResolveTransfers(fb.GetColorBufferPhysicalAddress(),u32(size_t(width)*height*colorBpp),true);
        ResolveTransfers(fb.GetDepthBufferPhysicalAddress(),u32(size_t(width)*height*depthBpp),true);
        const auto syncStart = profileEnabled ? std::chrono::steady_clock::now()
                                              : std::chrono::steady_clock::time_point{};
        fallback.FlushAndInvalidateRegion(fb.GetColorBufferPhysicalAddress(), u32(size_t(width) * height * colorBpp));
        fallback.FlushAndInvalidateRegion(fb.GetDepthBufferPhysicalAddress(), u32(size_t(width) * height * depthBpp));
        if (profileEnabled) {
            profileStats.fallbackSyncSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - syncStart).count();
        }
    }
    SyncDrawUniforms();
    fs_data.framebuffer_scale = renderScale;
    fs_data.scissor_x1 = regs.rasterizer.scissor_test.x1;
    fs_data.scissor_y1 = int(height) - int(regs.rasterizer.scissor_test.y2 + 1);
    fs_data.scissor_x2 = regs.rasterizer.scissor_test.x2 + 1;
    fs_data.scissor_y2 = int(height) - int(regs.rasterizer.scissor_test.y1);
    fs_data.scissor_x1*=renderScale;fs_data.scissor_y1*=renderScale;
    fs_data.scissor_x2*=renderScale;fs_data.scissor_y2*=renderScale;
    Pica::Shader::FSConfig config(regs);
    std::array<bool, 3> textureUsed{};
    constexpr std::array<unsigned, 6> tevSourceShifts{0, 4, 8, 16, 20, 24};
    for (const auto& stage : regs.texturing.GetTevStages()) {
        for (const unsigned shift : tevSourceShifts) {
            const unsigned source = (stage.sources_raw >> shift) & 0xf;
            if (source >= 3 && source <= 5) {
                textureUsed[source - 3] = true;
            }
        }
    }
    std::string key(reinterpret_cast<const char*>(&config), sizeof(config));
    auto found = programs.find(key);
    if (found == programs.end()) {
        if (programs.size() >= 128) programs.clear();
        const auto compileStart = profileEnabled ? std::chrono::steady_clock::now()
                                                 : std::chrono::steady_clock::time_point{};
        found = programs.emplace(key, CompileFragment(config)).first;
        if (profileEnabled) {
            profileStats.shaderCompileSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - compileStart).count();
        }
    }
    std::array<Texture, 3> textures;
    bool avoidedOwnerReadback=false;
    const auto configs = regs.texturing.GetTextures();
    for (unsigned unit = 0; unit < 3; ++unit) {
        const auto& c = configs[unit];
        if (!c.enabled) continue;
        if (!textureUsed[unit]) {
            if (profileEnabled) ++profileStats.unusedTextureSkips;
            continue;
        }
        const auto texturePreparationStart = profileEnabled ? std::chrono::steady_clock::now()
                                                            : std::chrono::steady_clock::time_point{};
        if ((unit == 0 && c.config.type != TC::Texture2D && c.config.type != TC::Projection2D) || c.config.lod.max_level || unsigned(c.config.wrap_s) == 4 || unsigned(c.config.wrap_s) == 5 || unsigned(c.config.wrap_t) == 4 || unsigned(c.config.wrap_t) == 5)
            throw std::runtime_error("texture type/mipmap/wrap");
        auto& t = textures[unit];
        t.width = c.config.width; t.height = c.config.height;
        if (!t.width || !t.height || t.width > 1024 || t.height > 1024 || t.width % 8 || t.height % 8)
            throw std::runtime_error("texture dimensions unit=" + std::to_string(unit) + " " +
                std::to_string(t.width) + "x" + std::to_string(t.height) + " address=" +
                std::to_string(c.config.GetPhysicalAddress()) +
                " format=" + std::to_string(static_cast<unsigned>(c.format)) + " type=" +
                std::to_string(static_cast<unsigned>(c.config.type.Value())) + " max_lod=" +
                std::to_string(static_cast<unsigned>(c.config.lod.max_level)));
        const auto info = Pica::Texture::TextureInfo::FromPicaRegister(c.config, c.format);
        const size_t sourceBytes = size_t(info.stride) * (t.height / 8);
        const PAddr textureAddress = c.config.GetPhysicalAddress();
        if(profileEnabled && retained) {
            const auto& source=savedRegs.framebuffer;
            const uint64_t base=source.GetColorBufferPhysicalAddress();
            if(std::any_of(cachedRanges.begin(),cachedRanges.end(),[&](auto range){return uint64_t(textureAddress)<uint64_t(range.first)+range.second && uint64_t(textureAddress)+sourceBytes>range.first;})) {
                const std::string message="alias texture="+std::to_string(textureAddress)+" "+std::to_string(t.width)+"x"+std::to_string(t.height)+" format="+std::to_string(unsigned(c.format))+" bytes="+std::to_string(sourceBytes)+" owner="+std::to_string(base)+" "+std::to_string(unsigned(source.width))+"x"+std::to_string(unsigned(source.height)+1)+" format="+std::to_string(unsigned(source.color_format.Value()))+" depth="+std::to_string(source.GetDepthBufferPhysicalAddress())+" depth_format="+std::to_string(unsigned(source.depth_format.Value()));
                if(loggedFailures.size()<96 && loggedFailures.emplace(message).second)printf("Metal %s\n",message.c_str());
            }
        }
        if(FeatureEnabled("DSTV_METAL_SURFACE_CACHE",false)) {
            const auto alias=c.format==Pica::TexturingRegs::TextureFormat::RGBA8
                ?surfaceOwner.FindRGBA8(textureAddress,t.width,t.height):std::nullopt;
            if(alias) {
                const auto copyStart=profileEnabled?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
                // Only unchanged components need original RAM bytes. Dirty
                // components are reconstructed on the GPU with exact packing.
                const bool needsOriginal=alias->depth && (!wroteDepth || !wroteStencil);
                const auto originalBytes=needsOriginal?std::span<const uint8_t>{memory.GetPhysicalPointer(textureAddress),sourceBytes}:std::span<const uint8_t>{};
                t.native=context->SnapshotSurface(alias->x,alias->y,t.width,t.height,alias->depth,wroteDepth,wroteStencil,originalBytes,renderScale);
                t.resolutionScale=renderScale;
                if(FeatureEnabled("DSTV_METAL_VALIDATE_SURFACES",false) && validatedSurfaces<64 && (surfaceValidationSequence++%97)==0) {
                    // Read-only correctness oracle: materialise to TEMPORARY
                    // buffers without altering guest RAM, ownership or dirty flags.
                    const auto referenceFrame=ReadGuestFrame();
                    const auto& source=savedRegs.framebuffer;
                    const auto* colorRAM=memory.GetPhysicalPointer(source.GetColorBufferPhysicalAddress());
                    const auto* depthRAM=memory.GetPhysicalPointer(source.GetDepthBufferPhysicalAddress());
                    std::vector<uint8_t> color(colorRAM,colorRAM+surfaceOwner.color.range.bytes);
                    std::vector<uint8_t> depth(depthRAM,depthRAM+surfaceOwner.depth.range.bytes);
                    FramebufferTransfer::Export(referenceFrame,color.data(),depth.data(),source.color_format,source.depth_format,wroteColor,wroteDepth,wroteStencil);
                    const auto& plane=alias->depth?surfaceOwner.depth:surfaceOwner.color;
                    const auto& bytes=alias->depth?depth:color;
                    const auto* raw=bytes.data()+(uint64_t(textureAddress)-plane.range.address);
                    std::vector<uint8_t> expected(size_t(t.width)*t.height*4);
                    for(unsigned y=0;y<t.height;++y)for(unsigned x=0;x<t.width;++x) {
                        const auto value=Pica::Texture::LookupTexture(raw,x,t.height-1-y,info);
                        std::memcpy(expected.data()+(size_t(y)*t.width+x)*4,value.AsArray(),4);
                    }
                    auto actual=context->ReadTexture(t.native);
                    if(renderScale>1)actual=Resolution::DownsampleRGBA(actual,t.width*renderScale,t.height*renderScale,renderScale,true);
                    if(actual!=expected)throw std::runtime_error("GPU surface validation differs from CPU texture decode");
                    ++validatedSurfaces;
                    printf("Metal surface validation passed: %llu plane=%s offset=%llu size=%ux%u\n",(unsigned long long)validatedSurfaces,alias->depth?"depth":"color",(unsigned long long)(uint64_t(textureAddress)-plane.range.address),t.width,t.height);
                }
                t.rgba.clear();
                t.wrapS=c.config.wrap_s;t.wrapT=c.config.wrap_t;
                t.linearMin=c.config.min_filter==TC::Linear;t.linearMag=c.config.mag_filter==TC::Linear;
                if(profileEnabled) {
                    ++profileStats.surfaceHits;++profileStats.surfaceCopies;
                    profileStats.surfaceCopySeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-copyStart).count();
                    profileStats.texturePreparationSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-texturePreparationStart).count();
                    if(!avoidedOwnerReadback) {
                        const auto& owner=savedRegs.framebuffer;
                        profileStats.avoidedReadbackBytes+=uint64_t(owner.width)*(owner.height+1)*((wroteColor?4:0)+(wroteDepth?4:0)+(wroteStencil?1:0));
                        avoidedOwnerReadback=true;
                    }
                }
                continue;
            }
            if(profileEnabled) {++profileStats.surfaceMisses;if(surfaceOwner.Overlaps(textureAddress,sourceBytes))++profileStats.surfaceOverlapMisses;}
        }
        // Synchronize both renderer caches before reading guest texture memory.
        const auto regionFlushStart = profileEnabled ? std::chrono::steady_clock::now()
                                                     : std::chrono::steady_clock::time_point{};
        FlushRegion(textureAddress, u32(sourceBytes));
        if (profileEnabled) {
            profileStats.regionFlushSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - regionFlushStart).count();
        }
        const auto syncStart = profileEnabled ? std::chrono::steady_clock::now()
                                              : std::chrono::steady_clock::time_point{};
        fallback.FlushAndInvalidateRegion(textureAddress, u32(sourceBytes));
        if (profileEnabled) {
            profileStats.fallbackSyncSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - syncStart).count();
        }
        const auto memoryRef = memory.GetPhysicalRef(c.config.GetPhysicalAddress());
        if(memoryRef.GetSize()<sourceBytes) throw std::runtime_error("texture memory range");
        const auto textureKey=std::tuple{c.config.GetPhysicalAddress(),t.width,t.height,unsigned(c.format)};
        auto cached=decodedTextures.find(textureKey);
        if(cached!=decodedTextures.end() && cached->second.bytes.size()==sourceBytes && std::memcmp(cached->second.bytes.data(),memoryRef.GetPtr(),sourceBytes)==0) {
            if(profileEnabled)++profileStats.textureHits;
            t=cached->second.texture;
        } else {
            if(profileEnabled)++profileStats.textureMisses;
            if(cached!=decodedTextures.end()) {
                decodedBytes-=cached->second.bytes.size()+cached->second.texture.Pixels().size();
                decodedTextures.erase(cached);
            }
            t.rgba.resize(size_t(t.width)*t.height*4);
            for(unsigned y=0;y<t.height;++y)for(unsigned x=0;x<t.width;++x) {
                auto color=Pica::Texture::LookupTexture(memoryRef.GetPtr(),x,t.height-1-y,info);
                std::memcpy(t.rgba.data()+(size_t(y)*t.width+x)*4,color.AsArray(),4);
            }
            if(decodedBytes+sourceBytes+t.rgba.size()>32*1024*1024 || decodedTextures.size()>=128) { decodedTextures.clear(); decodedBytes=0; }
            // Immutable decoded texels are shared by cache hits and draw state;
            // copying Texture must not allocate/copy a full RGBA image per draw.
            t.immutableRGBA=std::make_shared<const std::vector<uint8_t>>(std::move(t.rgba));
            t.cacheIdentity=++nextTextureIdentity;
            DecodedTexture entry;entry.bytes.assign(memoryRef.GetPtr(),memoryRef.GetPtr()+sourceBytes);entry.texture=t;
            decodedBytes+=entry.bytes.size()+entry.texture.Pixels().size();
            decodedTextures.emplace(textureKey,std::move(entry));
        }
        t.wrapS = c.config.wrap_s; t.wrapT = c.config.wrap_t;
        t.linearMin = c.config.min_filter == TC::Linear;
        t.linearMag = c.config.mag_filter == TC::Linear;
        if (profileEnabled) {
            profileStats.texturePreparationSeconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - texturePreparationStart).count();
        }
    }
    const auto lookupConversionStart = profileEnabled ? std::chrono::steady_clock::now()
                                                      : std::chrono::steady_clock::time_point{};
    auto& luts = lookupTables;
    const auto tablesChanged =
        !lookupTablesValid ||
        std::memcmp(lightingLutSnapshot.data(), pica.lighting.luts.data(),
                    sizeof(lightingLutSnapshot)) != 0 ||
        std::memcmp(fogLutSnapshot.data(), pica.fog.lut.data(), sizeof(fogLutSnapshot)) != 0 ||
        std::memcmp(noiseLutSnapshot.data(), pica.proctex.noise_table.data(),
                    sizeof(noiseLutSnapshot)) != 0 ||
        std::memcmp(colorMapLutSnapshot.data(), pica.proctex.color_map_table.data(),
                    sizeof(colorMapLutSnapshot)) != 0 ||
        std::memcmp(alphaMapLutSnapshot.data(), pica.proctex.alpha_map_table.data(),
                    sizeof(alphaMapLutSnapshot)) != 0 ||
        std::memcmp(proceduralColorSnapshot.data(), pica.proctex.color_table.data(),
                    sizeof(proceduralColorSnapshot)) != 0 ||
        std::memcmp(proceduralColorDiffSnapshot.data(), pica.proctex.color_diff_table.data(),
                    sizeof(proceduralColorDiffSnapshot)) != 0;
    for (unsigned i = 0; i < 24; ++i) {
        fs_data.lighting_lut_offset[i/4][i%4] = i*256;
    }
    fs_data.fog_lut_offset = 24*256;
    fs_data.proctex_noise_lut_offset=0; fs_data.proctex_color_map_offset=128; fs_data.proctex_alpha_map_offset=256;
    fs_data.proctex_lut_offset=0; fs_data.proctex_diff_lut_offset=256;
    if (tablesChanged) {
        for (unsigned i = 0; i < 24; ++i) {
            for (unsigned j = 0; j < 256; ++j) {
                luts.lightingFog[i*256+j] = {pica.lighting.luts[i][j].ToFloat(),
                                              pica.lighting.luts[i][j].DiffToFloat()};
            }
        }
        for (unsigned j = 0; j < 128; ++j) {
            luts.lightingFog[24*256+j] = {pica.fog.lut[j].ToFloat(),
                                          pica.fog.lut[j].DiffToFloat()};
        }
        const auto updateValueLut = [&](const auto& source, unsigned offset) {
            for (unsigned j = 0; j < source.size(); ++j) {
                luts.procedural[offset+j] = {source[j].ToFloat(), source[j].DiffToFloat()};
            }
        };
        updateValueLut(pica.proctex.noise_table, 0);
        updateValueLut(pica.proctex.color_map_table, 128);
        updateValueLut(pica.proctex.alpha_map_table, 256);
        for (unsigned j = 0; j < 256; ++j) {
            const auto color = pica.proctex.color_table[j].ToVector();
            const auto difference = pica.proctex.color_diff_table[j].ToVector();
            for (unsigned channel = 0; channel < 4; ++channel) {
                luts.proceduralColor[j][channel] = color[channel] / 255.f;
                luts.proceduralColor[256+j][channel] = difference[channel] / 255.f;
            }
        }
        lightingLutSnapshot = pica.lighting.luts;
        fogLutSnapshot = pica.fog.lut;
        noiseLutSnapshot = pica.proctex.noise_table;
        colorMapLutSnapshot = pica.proctex.color_map_table;
        alphaMapLutSnapshot = pica.proctex.alpha_map_table;
        proceduralColorSnapshot = pica.proctex.color_table;
        proceduralColorDiffSnapshot = pica.proctex.color_diff_table;
        lookupTablesValid = true;
    }
    if (profileEnabled) {
        profileStats.lookupConversionSeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - lookupConversionStart).count();
    }
    const auto framebufferImportStart = profileEnabled ? std::chrono::steady_clock::now()
                                                       : std::chrono::steady_clock::time_point{};
    Frame frame; frame.width=width;frame.height=height;
    if(!retained) FramebufferTransfer::Import(frame,memory.GetPhysicalPointer(fb.GetColorBufferPhysicalAddress()),memory.GetPhysicalPointer(fb.GetDepthBufferPhysicalAddress()),fb.color_format,fb.depth_format);
    if (profileEnabled && !retained) {
        profileStats.framebufferImportSeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - framebufferImportStart).count();
    }
    const bool hasStencil = fb.depth_format == F::DepthFormat::D24S8;
    DrawState state;
    state.hardware=hardwareActive?&hardwareBatch:nullptr;
    const auto viewport=regs.rasterizer.GetViewportRect();
    state.viewportX=viewport.left; state.viewportY=int(height)-viewport.top;
    state.viewportWidth=viewport.right-viewport.left;state.viewportHeight=viewport.top-viewport.bottom;
    if(state.viewportWidth<=0||state.viewportHeight<=0)throw std::runtime_error("empty viewport");
    // CPU framebuffer access uses PICA coordinates; rows above were reversed
    // to Metal top-left coordinates. Metal already maps NDC +Y to the top.
    state.flipY=false;state.vertexUniforms=vs_data;
    const auto& merger=regs.framebuffer.output_merger;
    state.colorMask=fb.allow_color_write ? (merger.depth_color_mask>>8)&15 : 0;
    state.depthFunc=merger.depth_test_enable ? unsigned(merger.depth_test_func.Value()) : 1;
    state.depthWrite=fb.allow_depth_stencil_write && merger.depth_write_enable;
    state.stencilEnabled=hasStencil && merger.stencil_test.enable;
    state.stencilFunc=unsigned(merger.stencil_test.func.Value());
    state.stencilFail=unsigned(merger.stencil_test.action_stencil_fail.Value());
    state.depthFail=unsigned(merger.stencil_test.action_depth_fail.Value());
    state.depthPass=unsigned(merger.stencil_test.action_depth_pass.Value());
    state.stencilReadMask=merger.stencil_test.input_mask;
    state.stencilWriteMask=fb.allow_depth_stencil_write ? unsigned(merger.stencil_test.write_mask) : 0;
    state.stencilRef=merger.stencil_test.reference_value;
    const auto cull=regs.rasterizer.cull_mode.Value();
    state.cull=cull==Pica::RasterizerRegs::CullMode::KeepClockWise ? 1 : (cull==Pica::RasterizerRegs::CullMode::KeepCounterClockWise ? 2 : 0);
    static_assert(sizeof(HardwareVertex)==sizeof(Vertex));
    const auto vertexCopyStart = profileEnabled ? std::chrono::steady_clock::now()
                                                : std::chrono::steady_clock::time_point{};
    metalVertices.resize(vertex_batch.size());
    std::memcpy(metalVertices.data(),vertex_batch.data(),metalVertices.size()*sizeof(Vertex));
    if (profileEnabled) {
        profileStats.vertexCopySeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - vertexCopyStart).count();
    }
    Resolution::Upscale(frame,renderScale);
    state.viewportX*=renderScale;state.viewportY*=renderScale;
    state.viewportWidth*=renderScale;state.viewportHeight*=renderScale;
    context->DrawFrame(found->second,metalVertices,fs_data,frame,state,textures,luts,true);
    if(!retained) {
        savedRegs=regs.framebuffer;
        surfaceOwner.color={{fb.GetColorBufferPhysicalAddress(),uint64_t(width)*height*colorBpp},width,height,colorBpp,unsigned(fb.color_format.Value()),true};
        surfaceOwner.depth={{fb.GetDepthBufferPhysicalAddress(),uint64_t(width)*height*depthBpp},width,height,depthBpp,unsigned(fb.depth_format.Value()),true};
        surfaceOwner.generation=++nextSurfaceGeneration;surfaceOwner.valid=true;
        // Merge page-aligned ranges: the memory cache marker is boolean and
        // overlapping colour/depth pages must be marked exactly once.
        auto region=[](PAddr address,u32 bytes) {
            const PAddr start=address&~PAddr(4095);
            const auto end=(uint64_t(address)+bytes+4095)&~uint64_t(4095);
            return std::pair<PAddr,u32>{start,u32(end-start)};
        };
        cachedRanges={region(fb.GetColorBufferPhysicalAddress(),width*height*colorBpp),region(fb.GetDepthBufferPhysicalAddress(),width*height*depthBpp)};
        std::sort(cachedRanges.begin(),cachedRanges.end());
        if(uint64_t(cachedRanges[0].first)+cachedRanges[0].second>=cachedRanges[1].first) {
            cachedRanges[0].second=u32(std::max(uint64_t(cachedRanges[0].first)+cachedRanges[0].second,uint64_t(cachedRanges[1].first)+cachedRanges[1].second)-cachedRanges[0].first);
            cachedRanges.resize(1);
        }
        SyncCachedPages();
        retained=true;
    }
    wroteColor |= state.colorMask != 0;
    wroteDepth |= state.depthWrite;
    wroteStencil |= state.stencilEnabled && state.stencilWriteMask;
    if(wroteColor)surfaceOwner.dirtyColor=surfaceOwner.color.range;
    if(wroteDepth)surfaceOwner.dirtyDepth=surfaceOwner.depth.range;
    if(wroteStencil)surfaceOwner.dirtyStencil=surfaceOwner.depth.range;
}
}
