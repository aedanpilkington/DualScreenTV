// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalShaderCompiler.h"
#include <array>
#include <memory>
#include <span>
#include <cstdint>
#include "video_core/shader/generator/shader_uniforms.h"
namespace AzaharMetal {
// Matches RasterizerAccelerated::HardwareVertex byte-for-byte (no SIMD alignment padding).
struct Vertex {
    std::array<float, 4> position, color;
    std::array<float, 2> uv0, uv1, uv2;
    float uv0w;
    std::array<float, 4> quaternion;
    std::array<float, 3> view;
};
static_assert(sizeof(Vertex) == 88);
struct NativeTexture;
struct TransferTicket;
struct Texture {
    std::shared_ptr<NativeTexture> native; // Immutable, GPU-only snapshot.
    uint64_t cacheIdentity = 0; // Immutable payload identity within one DrawContext.
    unsigned wrapS = 0, wrapT = 0;
    bool linearMin = false, linearMag = false;
    unsigned width = 1, height = 1;
    unsigned resolutionScale=1; // Guest dimensions above; physical native image scale.
    std::vector<uint8_t> rgba{255, 255, 255, 255};
    std::shared_ptr<const std::vector<uint8_t>> immutableRGBA;
    std::span<const uint8_t> Pixels() const {
        return immutableRGBA?std::span<const uint8_t>(*immutableRGBA):std::span<const uint8_t>(rgba);
    }
};
struct LookupTables {
    std::vector<std::array<float, 2>> lightingFog = std::vector<std::array<float, 2>>(4096);
    std::vector<std::array<float, 2>> procedural = std::vector<std::array<float, 2>>(4096);
    std::vector<std::array<float, 4>> proceduralColor = std::vector<std::array<float, 4>>(4096);
};
struct Frame {
    unsigned width = 0, height = 0;
    std::vector<uint8_t> rgba, stencil;
    std::vector<float> depth;
};
struct VertexProgram { std::string source,entry; uint64_t identity=0; };
struct HardwareBatch {
    const VertexProgram* program = nullptr;
    std::vector<std::array<float,64>> inputs;
    std::vector<uint32_t> indices;
    Pica::Shader::Generator::VSPicaUniformData uniforms{};
};
VertexProgram CompileVertex(Pica::ShaderSetup&,const Pica::RegsInternal&);
struct DrawState {
    const HardwareBatch* hardware = nullptr;
    double viewportX = 0, viewportY = 0, viewportWidth = 0, viewportHeight = 0;
    unsigned colorMask = 15, depthFunc = 1, cull = 0;
    bool depthWrite = true, stencilEnabled = false, flipY = false;
    unsigned stencilFunc = 1, stencilFail = 0, depthFail = 0, depthPass = 0;
    unsigned stencilReadMask = 255, stencilWriteMask = 255, stencilRef = 0;
    Pica::Shader::Generator::VSUniformData vertexUniforms{};
};
struct SurfaceClear {
    bool color=false,depth=false,stencil=false;
    std::array<uint8_t,4> rgba{};
    float depthValue=1;
    uint8_t stencilValue=0;
};
struct DisplayTransfer {
    uint32_t inputWidth,inputHeight,outputWidth,outputHeight;
    uint32_t inputFormat,outputFormat,inputLinear,outputLinear,scaling,flip,useImage;
    uint32_t sourceX=0,sourceY=0,resolutionScale=1;
};
struct Stats {
    uint64_t draws = 0, pipelineBuilds = 0, pipelineHits = 0, commandBuffers = 0;
    uint64_t framebufferUploadBytes = 0, textureUploadBytes = 0, lutUploadBytes = 0;
    uint64_t readbackBytes = 0;
    uint64_t uploadBufferAllocations=0,uploadBufferReuses=0;
    uint64_t readbackBufferAllocations=0,readbackBufferReuses=0;
    uint64_t targetAllocations=0,targetReuses=0;
    uint64_t textureAllocations=0,whiteTextureReuses=0;
    uint64_t snapshotTextureAllocations=0,snapshotTextureReuses=0,aliasScratchAllocations=0;
    uint64_t depthTextureSnapshots=0,depthBufferSnapshots=0,avoidedDepthCopyBytes=0;
    double gpuSeconds = 0, cpuEncodeSeconds = 0, gpuWaitSeconds = 0;
    double readbackWallSeconds = 0, pipelineBuildSeconds = 0;
    double targetAllocationSeconds = 0, vertexBufferSeconds = 0;
    double framebufferUploadSeconds = 0, textureUploadSeconds = 0, lutUploadSeconds = 0;
};
// Native offscreen GPU draws with retained targets. Single-owner/thread;
// bounded asynchronous submissions drain on explicit Flush/ReadFrame.
class DrawContext {
public:
    DrawContext();
    ~DrawContext();
    DrawContext(const DrawContext&) = delete;
    DrawContext& operator=(const DrawContext&) = delete;
    std::vector<uint8_t> Draw(const FragmentProgram& program, std::span<const Vertex> vertices,
        const Pica::Shader::Generator::FSUniformData& uniforms,
        unsigned width, unsigned height, std::span<const Texture> textures = {}, const LookupTables& luts = {});
    Frame DrawFrame(const FragmentProgram& program, std::span<const Vertex> vertices,
        const Pica::Shader::Generator::FSUniformData& uniforms, const Frame& initial,
        const DrawState& state, std::span<const Texture> textures, const LookupTables& luts, bool retainTarget = false);
    Frame ReadFrame(bool readColor = true, bool readDepth = true, bool readStencil = true);
    void DiscardFrame();
    void ClearSurface(const SurfaceClear&);
    std::vector<uint8_t> ReadTexture(const std::shared_ptr<NativeTexture>&); // Opt-in validation only.
    std::shared_ptr<NativeTexture> SnapshotSurface(unsigned x,unsigned y,unsigned width,unsigned height,
        bool depth,bool dirtyDepth=true,bool dirtyStencil=true,std::span<const uint8_t> original={},unsigned resolutionScale=1);
    // Submit without waiting. Each ticket owns its output until materialisation.
    std::shared_ptr<TransferTicket> EnqueueTransfer(const DisplayTransfer&,std::span<const uint8_t> source = {});
    // Convert a packed transfer destination into the existing libretro RGBA
    // screen ABI on the GPU. tail preserves the pinned scanout border pixel.
    std::shared_ptr<TransferTicket> EnqueueScanout(const std::shared_ptr<TransferTicket>&,
        unsigned width,unsigned height,unsigned format,std::array<uint8_t,4> tail,bool highResolution=false);
    unsigned PresentationScale(const std::shared_ptr<TransferTicket>&) const;
    std::vector<uint8_t> ResolveTransfer(const std::shared_ptr<TransferTicket>&);
    std::vector<uint8_t> Transfer(const DisplayTransfer&,std::span<const uint8_t> source = {});
    void SetProfilingEnabled(bool enabled);
    Stats TakeMeasurements();
    const Stats& Measurements() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
