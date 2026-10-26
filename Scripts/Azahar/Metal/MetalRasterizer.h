// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalDraw.h"
#include "MetalSurfaceCache.h"
#include "TransferOwnership.h"
#include "video_core/pica/output_vertex.h"
#include "video_core/pica/pica_core.h"
#include "video_core/rasterizer_accelerated.h"
#include "video_core/pica/regs_lcd.h"
#include "video_core/renderer_software/renderer_software.h"
#include "video_core/renderer_vulkan/renderer_vulkan.h"
#include <chrono>
#include <map>
#include <tuple>
#include <set>
namespace AzaharMetal {
// Native draw batches and deferred display transfers with explicit guest-memory
// ownership. Unsupported operations preserve the established CPU fallback.
class Rasterizer : public VideoCore::RasterizerAccelerated {
public:
    Rasterizer(Memory::MemorySystem& memory, Pica::PicaCore& pica,
               VideoCore::RasterizerInterface& fallback);
    bool AccelerateDrawBatch(bool is_indexed) override;
    bool AccelerateFill(const Pica::MemoryFillConfig&) override;
    bool AccelerateDisplayTransfer(const Pica::DisplayTransferConfig&) override;
    void FlushDisplayRegions();
    void PrepareDisplay();
    bool LoadDisplay(int,SwRenderer::ScreenInfo&);
    const SwRenderer::ScreenInfo* BorrowDisplayScreen(VideoCore::ScreenId) const noexcept;
    void AddTriangle(const Pica::OutputVertex&, const Pica::OutputVertex&, const Pica::OutputVertex&) override;
    void DrawTriangles() override;
    ~Rasterizer() override;
    void FlushAll() override;
    void FlushRegion(PAddr, u32) override;
    void InvalidateRegion(PAddr a, u32 n) override;
    void FlushAndInvalidateRegion(PAddr a, u32 n) override { FlushRegion(a,n); InvalidateRegion(a,n); }
    void ClearAll(bool) override;
    void ReportProfileFrame();
private:
    struct ProfileStats {
        double texturePreparationSeconds = 0;
        double hardwarePreparationSeconds=0,hardwareDrawSeconds=0,transferSeconds=0;
        double shaderCompileSeconds = 0;
        double fallbackSyncSeconds = 0;
        double regionFlushSeconds = 0;
        double framebufferImportSeconds = 0;
        double framebufferExportSeconds = 0;
        double lookupConversionSeconds = 0;
        double vertexCopySeconds = 0;
        double batchWallSeconds = 0;
        uint64_t unusedTextureSkips = 0;
        uint64_t transfersQueued=0,transfersMaterialised=0,transfersDiscarded=0;
        uint64_t residentScreens=0,cachedScreens=0,fallbackScreens=0;
        uint64_t regionFlushes=0,targetSwitches=0,readbacks=0,textureHits=0,textureMisses=0;
        double fallbackReplaySeconds=0,maxBatchSeconds=0;
        uint64_t surfaceHits=0,surfaceMisses=0,surfaceOverlapMisses=0,surfaceCopies=0;
        uint64_t avoidedReadbackBytes=0,surfaceInvalidations=0,surfaceMaterialisations=0;
        double surfaceCopySeconds=0;
    };
    void NativeDraw();
    Frame ReadGuestFrame(bool color=true,bool depth=true,bool stencil=true);
    unsigned renderScale=1;
    void ReleaseTarget();
    void FlushTarget();
    void SyncCachedPages();
    void ResolveTransfers(PAddr,u32,bool discardCovered=false);
    void ResolveAllTransfers();
    struct PendingTransfer { TransferRange range; std::shared_ptr<TransferTicket> ticket; DisplayTransfer params; bool dirty=true; };
    struct DisplayScreen {
        bool valid=false;
        std::shared_ptr<TransferTicket> source;
        std::array<uint8_t,4> tail{};
        SwRenderer::ScreenInfo screen{};
    };
    std::array<DisplayScreen,2> displayScreens;
    std::vector<PendingTransfer> pendingTransfers;
    std::vector<PAddr> markedPages;
    void PrintProfile();
    bool profileEnabled = false;
    std::chrono::steady_clock::time_point profileStart{};
    uint64_t profileFrames = 0,totalProfileFrames=0;
    unsigned tracedFlushes=0;
    uint64_t profileNativeStart = 0, profileFallbackStart = 0;
    ProfileStats profileStats{};
    SurfaceOwner surfaceOwner;
    uint64_t nextSurfaceGeneration=0, surfaceValidationSequence=0, validatedSurfaces=0;
    uint64_t transferValidationSequence=0,validatedTransfers=0;
    bool retained = false;
    bool wroteColor = false, wroteDepth = false, wroteStencil = false;
    Pica::FramebufferRegs savedRegs{};
    std::vector<std::pair<PAddr,u32>> cachedRanges;
    VideoCore::RasterizerInterface& fallback;
    std::vector<Pica::OutputVertex> original;
    HardwareBatch hardwareBatch;
    bool hardwareActive=false;
    uint64_t hardwareBatches=0,transferBatches=0,directTransferBatches=0,clearBatches=0;
    struct VertexRecord { Pica::ProgramCode code;Pica::SwizzleData swizzle;VertexProgram program; };
    std::map<std::string,std::vector<VertexRecord>> vertexPrograms;
    unsigned vertexProgramCount=0;
    std::set<std::string> rejectedVertexPrograms;
    std::unique_ptr<DrawContext> context;
    std::map<std::string, FragmentProgram> programs;
    LookupTables lookupTables;
    std::array<std::array<Pica::PicaCore::Lighting::LutEntry, 256>, 24> lightingLutSnapshot{};
    std::array<Pica::PicaCore::Fog::LutEntry, 128> fogLutSnapshot{};
    std::array<Pica::PicaCore::ProcTex::ValueEntry, 128> noiseLutSnapshot{};
    std::array<Pica::PicaCore::ProcTex::ValueEntry, 128> colorMapLutSnapshot{};
    std::array<Pica::PicaCore::ProcTex::ValueEntry, 128> alphaMapLutSnapshot{};
    std::array<Pica::PicaCore::ProcTex::ColorEntry, 256> proceduralColorSnapshot{};
    std::array<Pica::PicaCore::ProcTex::ColorDifferenceEntry, 256> proceduralColorDiffSnapshot{};
    bool lookupTablesValid = false;
    std::vector<Vertex> metalVertices;
    struct DecodedTexture { std::vector<uint8_t> bytes; Texture texture; };
    std::map<std::tuple<PAddr,unsigned,unsigned,unsigned>,DecodedTexture> decodedTextures;
    size_t decodedBytes = 0;
    uint64_t nextTextureIdentity = 0;
    std::set<std::string> loggedFailures;
    std::map<std::string, uint64_t> fallbackReasonCounts;
    std::map<std::string, uint64_t> vertexReplayReasonCounts;
};
class Renderer : public SwRenderer::RendererSoftware {
public:
    Renderer(Core::System&, Pica::PicaCore&, Frontend::EmuWindow&);
    void SwapBuffers() override {
        native.PrepareDisplay();
        native.ReportProfileFrame();
        SwRenderer::RendererSoftware::SwapBuffers();
    }
    VideoCore::RasterizerInterface* Rasterizer() override { return &native; }
    const SwRenderer::ScreenInfo& Screen(VideoCore::ScreenId id) const noexcept override {
        if(auto screen=native.BorrowDisplayScreen(id))return *screen;
        return SwRenderer::RendererSoftware::Screen(id);
    }
protected:
    bool LoadNativeScreen(int i,SwRenderer::ScreenInfo& info) override {return native.LoadDisplay(i,info);}
private:
    AzaharMetal::Rasterizer native;
};
class HybridRenderer : public Vulkan::RendererVulkan {
public:
    HybridRenderer(Core::System&, Pica::PicaCore&, Frontend::EmuWindow&,
                   Frontend::EmuWindow*);
    VideoCore::RasterizerInterface* Rasterizer() override { return &native; }
    void SwapBuffers() override;
private:
    AzaharMetal::Rasterizer native;
};
}
