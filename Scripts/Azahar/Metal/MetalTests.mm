#include "InterpreterStack.h"
#include "SoftwareScanoutTests.h"
#include <boost/circular_buffer.hpp>
#include "FramebufferTests.h"
#include "TransferTests.h"
#include "SurfaceCacheTests.h"
// SPDX-License-Identifier: GPL-2.0-or-later
#include "MetalDraw.h"
#include "common/logging/log.h"
#include "video_core/renderer_software/sw_texturing.h"
#include <iostream>
#include <stdexcept>
#include <fstream>
// Standalone validation executable only. Never linked as the core's logger.
namespace Common::Log {
void Stop() {}
void FmtLogMessageImpl(Class, Level, const char*, unsigned int, const char*, fmt::string_view format, const fmt::format_args& args) {
    throw std::runtime_error(fmt::vformat(format, args));
}
}
using namespace AzaharMetal;
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
int main(int argc, char** argv) {
    try {
        Pica::RegsInternal regs{};
        using T = Pica::TexturingRegs::TevStageConfig;
        using F = Pica::FramebufferRegs;
        regs.framebuffer.output_merger.logic_op.Assign(F::LogicOp::Copy);
        regs.lighting.disable.Assign(1);
        // Stage zero primary colour, all subsequent stages pass through.
        auto stage = [](T::Source source) {
            T t{};
            t.color_source1.Assign(source); t.alpha_source1.Assign(source);
            t.color_op.Assign(T::Operation::Replace); t.alpha_op.Assign(T::Operation::Replace);
            return t;
        };
        regs.texturing.tev_stage0 = stage(T::Source::PrimaryColor);
        regs.texturing.tev_stage1 = regs.texturing.tev_stage2 = regs.texturing.tev_stage3 =
            regs.texturing.tev_stage4 = regs.texturing.tev_stage5 = stage(T::Source::Previous);
        auto program = CompileFragment(Pica::Shader::FSConfig(regs));
        if (argc > 1) { std::ofstream(argv[1]) << program.shader->source; }
        TestFramebufferTransfers();
        TestSoftwareScanout();
        TestSurfaceCache();
        auto stackTest=[]<size_t Capacity>() {
            Pica::Shader::InterpreterStack<unsigned,Capacity> actual;
            boost::circular_buffer<unsigned> expected(Capacity);
            std::mt19937 random(321);
            for(unsigned i=0;i<1000000;++i) {
                if(!expected.empty() && random()%3==0) {actual.pop_back();expected.pop_back();}
                else {const auto value=random();actual.push_back(value);expected.push_back(value);}
                Check(actual.size()==expected.size() && actual.empty()==expected.empty(),"Interpreter stack size differs from upstream");
                if(!expected.empty()) {
                    Check(actual.back()==expected.back(),"Interpreter stack overflow/order differs from upstream");
                    if(random()%7==0) {actual.back()^=123;expected.back()^=123;}
                }
            }
        };
        stackTest.template operator()<4>();stackTest.template operator()<8>();
        DrawContext context;
        std::array<Vertex, 3> triangle{};
        triangle[0].position = {-1, -1, -0.5, 1};
        triangle[1].position = {3, -1, -0.5, 1};
        triangle[2].position = {-1, 3, -0.5, 1};
        for (auto& v : triangle) { v.color = {1, 0, 0, 1}; v.uv0w = 1; v.quaternion = {0, 0, 0, 1}; }
        Pica::Shader::Generator::FSUniformData uniforms{};
        uniforms.framebuffer_scale = 1;
        uniforms.depth_scale = 1;
        for (unsigned scale : {1, 2, 3, 4}) {
            auto image = context.Draw(program, triangle, uniforms, 400 * scale, 240 * scale);
            for (size_t i = 0; i < image.size(); i += 4)
                Check(image[i] == 255 && image[i+1] == 0 && image[i+2] == 0 && image[i+3] == 255, "Primary-colour triangle mismatch");
        }
        regs.texturing.main_config.texture0_enable.Assign(1);
        regs.texturing.tev_stage0 = stage(T::Source::Texture0);
        auto textured = CompileFragment(Pica::Shader::FSConfig(regs));
        Texture tex; tex.rgba = {0, 255, 0, 255};
        auto image = context.Draw(textured, triangle, uniforms, 64, 64, std::span(&tex, 1));
        for (size_t i = 0; i < image.size(); i += 4)
            Check(image[i] == 0 && image[i+1] == 255 && image[i+2] == 0 && image[i+3] == 255, "Texture sample mismatch");
        // Sharing decoded texels must retain lifetime and exact sampling even
        // when the source vector is released. Coloured 1x1 images are not white.
        {
            DrawContext sharing;
            Texture shared=tex;shared.immutableRGBA=std::make_shared<const std::vector<uint8_t>>(std::move(shared.rgba));
            Texture copy=shared;shared={};
            auto sharedImage=sharing.Draw(textured,triangle,uniforms,8,8,std::span(&copy,1));
            for(size_t i=0;i<sharedImage.size();i+=4)Check(sharedImage[i]==0 && sharedImage[i+1]==255 && sharedImage[i+2]==0,"Shared texture lifetime/sampling changed");
            const auto beforeWhite=sharing.Measurements().textureAllocations;
            sharing.Draw(program,triangle,uniforms,8,8);
            sharing.Draw(program,triangle,uniforms,8,8);
            Check(sharing.Measurements().textureAllocations==beforeWhite,"Inactive sampler bindings keep allocating textures");
            Check(sharing.Measurements().whiteTextureReuses>=6,"White sampler texture not shared");
        }
        tex.cacheIdentity=1;
        auto green=context.Draw(textured,triangle,uniforms,16,16,std::span(&tex,1));
        Texture blue=tex;blue.cacheIdentity=2;blue.rgba={0,0,255,255};
        auto blueImage=context.Draw(textured,triangle,uniforms,16,16,std::span(&blue,1));
        Check(blueImage[2]==255 && blueImage[1]==0,"New texture identity retained stale contents");
        auto greenAgain=context.Draw(textured,triangle,uniforms,16,16,std::span(&tex,1));
        Check(green==greenAgain,"Texture cache reuse changed sampling");
        tex.cacheIdentity=0;
        // Real upstream TEV multiplication, rather than a hand-written stand-in fragment shader.
        regs.texturing.tev_stage0.color_source2.Assign(T::Source::PrimaryColor);
        regs.texturing.tev_stage0.color_op.Assign(T::Operation::Modulate);
        for (auto& v : triangle) v.color = {0.5f, 0.5f, 0.5f, 1};
        tex.rgba = {128, 128, 128, 255};
        image = context.Draw(CompileFragment(Pica::Shader::FSConfig(regs)), triangle, uniforms, 64, 64, std::span(&tex, 1));
        for (size_t i = 0; i < image.size(); i += 4)
            Check(image[i] == 64 && image[i+1] == 64 && image[i+2] == 64 && image[i+3] == 255, "TEV modulation mismatch");
        regs.texturing.tev_stage0 = stage(T::Source::PrimaryColor);
        for (auto& v : triangle) v.color = {1, 0, 0, 1};
        regs.texturing.fog_mode.Assign(Pica::TexturingRegs::FogMode::Fog);
        uniforms.fog_color = {0, 0, 1};
        LookupTables luts;
        for (auto& entry : luts.lightingFog) entry = {0.5f, 0};
        image = context.Draw(CompileFragment(Pica::Shader::FSConfig(regs)), triangle, uniforms, 64, 64, {}, luts);
        for (size_t i = 0; i < image.size(); i += 4)
            Check(image[i] == 128 && image[i+1] == 0 && image[i+2] == 128 && image[i+3] == 255, "Fog lookup mismatch");
        regs.texturing.fog_mode.Assign(Pica::TexturingRegs::FogMode::None);
        regs.framebuffer.output_merger.alpha_test.enable.Assign(1);
        regs.framebuffer.output_merger.alpha_test.func.Assign(F::CompareFunc::Never);
        image = context.Draw(CompileFragment(Pica::Shader::FSConfig(regs)), triangle, uniforms, 64, 64);
        for (auto b : image) Check(b == 0, "Discarded fragment wrote colour");
        regs.framebuffer.output_merger.alpha_test.enable.Assign(0);
        const Common::Vec4<u8> primary{64, 128, 192, 128}, texture{200, 100, 50, 200}, constant{128, 64, 32, 64};
        for (auto& v : triangle) v.color = {64.f/255, 128.f/255, 192.f/255, 128.f/255};
        tex.rgba = {200, 100, 50, 200};
        uniforms.const_color[0] = {128.f/255, 64.f/255, 32.f/255, 64.f/255};
        auto& tev = regs.texturing.tev_stage0;
        tev.color_source1.Assign(T::Source::PrimaryColor); tev.alpha_source1.Assign(T::Source::PrimaryColor);
        tev.color_source2.Assign(T::Source::Texture0); tev.alpha_source2.Assign(T::Source::Texture0);
        tev.color_source3.Assign(T::Source::Constant); tev.alpha_source3.Assign(T::Source::Constant);
        const std::array<Common::Vec3<u8>, 3> rgb{primary.rgb(), texture.rgb(), constant.rgb()};
        const std::array<u8, 3> alpha{primary.a(), texture.a(), constant.a()};
        for (unsigned op = 0; op < 10; ++op) {
            auto operation = static_cast<T::Operation>(op);
            tev.color_op.Assign(operation);
            bool dot = operation == T::Operation::Dot3_RGB || operation == T::Operation::Dot3_RGBA;
            tev.alpha_op.Assign(dot ? T::Operation::Replace : operation);
            auto expected = SwRenderer::ColorCombine(operation, rgb);
            auto expectedAlpha = operation == T::Operation::Dot3_RGBA ? expected.r() : SwRenderer::AlphaCombine(dot ? T::Operation::Replace : operation, alpha);
            image = context.Draw(CompileFragment(Pica::Shader::FSConfig(regs)), triangle, uniforms, 16, 16, std::span(&tex, 1));
            for (size_t i = 0; i < image.size(); i += 4) {
                for (unsigned channel = 0; channel < 3; ++channel)
                    Check(std::abs(int(image[i+channel]) - int(expected[channel])) <= 1, "TEV CPU-reference RGB mismatch");
                Check(std::abs(int(image[i+3]) - int(expectedAlpha)) <= 1, "TEV CPU-reference alpha mismatch");
            }
        }
        regs.texturing.tev_stage0 = stage(T::Source::PrimaryColor);
        for (auto& v : triangle) v.color = {1, 0, 0, 0.5f};
        auto& merger = regs.framebuffer.output_merger;
        merger.alphablend_enable.Assign(1);
        merger.alpha_blending.blend_equation_rgb.Assign(F::BlendEquation::Add);
        merger.alpha_blending.blend_equation_a.Assign(F::BlendEquation::Add);
        merger.alpha_blending.factor_source_rgb.Assign(F::BlendFactor::SourceAlpha);
        merger.alpha_blending.factor_dest_rgb.Assign(F::BlendFactor::OneMinusSourceAlpha);
        merger.alpha_blending.factor_source_a.Assign(F::BlendFactor::One);
        merger.alpha_blending.factor_dest_a.Assign(F::BlendFactor::Zero);
        auto blended = CompileFragment(Pica::Shader::FSConfig(regs));
        image = context.Draw(blended, triangle, uniforms, 32, 32);
        for (size_t i = 0; i < image.size(); i += 4)
            Check(image[i] == 128 && image[i+1] == 0 && image[i+2] == 0 && image[i+3] == 128, "Native alpha blending mismatch");
        // Same MSL, different blend factors must produce a different native pipeline.
        blended.blend[1] = unsigned(F::BlendFactor::One);
        image = context.Draw(blended, triangle, uniforms, 32, 32);
        Check(image[0] == 255 && image[3] == 128, "Blend pipeline key omitted native state");
        merger.alphablend_enable.Assign(0);
        regs.texturing.tev_stage0 = stage(T::Source::PrimaryColor);
        for (auto& v : triangle) v.color = {1, 0, 0, 1};
        uniforms.depth_scale = -1;
        auto solid = CompileFragment(Pica::Shader::FSConfig(regs));
        Frame initial; initial.width=8;initial.height=8;
        initial.rgba.resize(8*8*4); initial.depth.resize(64,0.25f); initial.stencil.resize(64,2);
        for(unsigned i=0;i<64;++i) { initial.rgba[i*4+2]=255;initial.rgba[i*4+3]=255; }
        DrawState state; state.depthFunc=4; // Less; generated depth is 0.5.
        auto kept=context.DrawFrame(solid,triangle,uniforms,initial,state,{},{});
        Check(kept.rgba==initial.rgba && kept.depth==initial.depth && kept.stencil==initial.stencil,"Depth rejection corrupted preserved framebuffer");
        state.stencilEnabled=true;state.stencilFunc=2;state.stencilRef=3;state.stencilFail=2;
        kept=context.DrawFrame(solid,triangle,uniforms,initial,state,{},{});
        for(auto value:kept.stencil)Check(value==3,"Stencil fail Replace did not round-trip");
        Check(kept.rgba==initial.rgba,"Stencil rejection wrote colour");
        initial=kept;initial.depth.assign(64,0.75f);
        state.colorMask=1;state.depthPass=2;
        kept=context.DrawFrame(solid,triangle,uniforms,initial,state,{},{});
        for(unsigned i=0;i<64;++i) {
            Check(kept.rgba[i*4]==255 && kept.rgba[i*4+2]==255,"Red-only colour mask overwrote blue");
            Check(std::abs(kept.depth[i]-0.5f)<0.000001f && kept.stencil[i]==3,"Depth/stencil write did not round-trip");
        }

        // Retain two draw batches without an intervening CPU readback. Compare
        // with the same draws using explicit framebuffer round trips.
        state.depthFunc=1; state.stencilEnabled=false; state.colorMask=15;
        auto first=context.DrawFrame(solid,triangle,uniforms,initial,state,{},{});
        state.colorMask=4;
        for(auto& v:triangle) v.color={0,0,0.25f,1};
        auto expected=context.DrawFrame(solid,triangle,uniforms,first,state,{},{});
        state.colorMask=15;
        for(auto& v:triangle) v.color={1,0,0,1};
        const auto commandsBefore=context.Measurements().commandBuffers;
        context.DrawFrame(solid,triangle,uniforms,initial,state,{},{},true);
        Frame retained;retained.width=8;retained.height=8;
        state.colorMask=4;
        for(auto& v:triangle) v.color={0,0,0.25f,1};
        context.DrawFrame(solid,triangle,uniforms,retained,state,{},{},true);
        Check(context.Measurements().commandBuffers==commandsBefore,"Retained draws submitted individually");
        auto combined=context.ReadFrame();
        Check(context.Measurements().commandBuffers==commandsBefore+1,"Compatible draws did not share a command buffer");
        Check(combined.rgba==expected.rgba && combined.depth==expected.depth && combined.stencil==expected.stencil,"Retained GPU batches differ from round-trip reference");
        auto colorOnly=context.ReadFrame(true,false,false);
        Check(colorOnly.rgba==expected.rgba && colorOnly.depth.empty() && colorOnly.stencil.empty(),"Selective framebuffer readback returned incorrect planes");
        // Cross the bounded pass boundary and verify a queued pass can consume
        // the preceding pass's stored attachments without losing masks/depth.
        const auto boundedBefore=context.Measurements().commandBuffers;
        context.DrawFrame(solid,triangle,uniforms,combined,state,{},{},true);
        for(unsigned draw=1;draw<130;++draw) context.DrawFrame(solid,triangle,uniforms,retained,state,{},{},true);
        Check(context.Measurements().commandBuffers==boundedBefore+1,"Draw pass bound not enforced");
        auto bounded=context.ReadFrame();
        Check(bounded.rgba==combined.rgba && bounded.depth==combined.depth && bounded.stencil==combined.stencil,"Bounded pass transition lost framebuffer data");
        context.DiscardFrame();
        bool emptyRejected=false;
        try { context.ReadFrame(); } catch(const std::exception&) { emptyRejected=true; }
        Check(emptyRejected,"Discarded framebuffer remained readable");
        // GPU vertex pulling, index order and the 1616-byte PICA uniform block
        // must agree with pre-transformed CPU vertices through the same fragment shader.
        VertexProgram hwProgram;
        hwProgram.entry="test_vertex";
        hwProgram.source=R"MSL(
#include <metal_stdlib>
using namespace metal;
struct U { uint b;uint4 i[4];float4 f[96]; };
struct VS {uint clip,flip;float4 coefficient;};
struct Out {float4 position [[position]];float4 color [[user(locn1)]];float2 uv0 [[user(locn2)]];float2 uv1 [[user(locn3)]];float2 uv2 [[user(locn4)]];float uv0w [[user(locn5)]];float4 q [[user(locn6)]];float3 view [[user(locn7)]];float clip [[clip_distance]] [2];};
vertex Out test_vertex(uint id [[vertex_id]],device const float4* input [[buffer(0)]],constant VS& state [[buffer(1)]],constant U& uniforms [[buffer(2)]],device const uint* order [[buffer(3)]]) {
    Out o;uint v=order[id]*16u;float4 p=input[v];p.x+=uniforms.f[0].x;
    o.position=float4(p.xy,-p.z,p.w);if(state.flip)o.position.y=-o.position.y;
    o.color=input[v+1]*(uniforms.b==1u?0.5f:1.0f);o.uv0=o.uv1=o.uv2=float2(0);o.uv0w=1;o.q=float4(0,0,0,1);o.view=float3(0);o.clip[0]=-p.z;o.clip[1]=0;return o;
}
)MSL";
        HardwareBatch hw;hw.program=&hwProgram;hw.inputs.resize(3);hw.indices={0,1,2};hw.uniforms.b=1;hw.uniforms.f[0]={0.25f,0,0,0};
        for(unsigned v=0;v<3;++v) {
            for(unsigned c=0;c<4;++c)hw.inputs[v][c]=triangle[v].position[c];
            hw.inputs[v][4]=0;hw.inputs[v][5]=1;hw.inputs[v][6]=0;hw.inputs[v][7]=1;
            triangle[v].position[0]+=0.25f;triangle[v].color={0,0.5f,0,0.5f};
        }
        DrawState hwState;
        auto expectedHW=context.DrawFrame(solid,triangle,uniforms,initial,hwState,{},{});
        hwState.hardware=&hw;
        auto actualHW=context.DrawFrame(solid,{},uniforms,initial,hwState,{},{});
        Check(actualHW.rgba==expectedHW.rgba && actualHW.depth==expectedHW.depth,"GPU vertex inputs/indices/PICA uniform ABI differ from CPU reference");
        // Distinct per-draw stripes expose premature upload reuse: changing
        // later CPU vertices must never alter earlier draws still on the GPU.
        // Cross upload-page and 128-draw command boundaries, then recycle only
        // after synchronous readback. Check repeated imports and resized targets.
        {
            DrawContext pooled;
            Frame seed;seed.width=160;seed.height=8;seed.rgba.resize(160*8*4);
            seed.depth.resize(160*8,0.75f);seed.stencil.resize(160*8,37);
            Frame resident;resident.width=160;resident.height=8;
            DrawState stripe;stripe.viewportWidth=1;stripe.viewportHeight=8;
            std::vector<Vertex> many(60);
            uint64_t warmedAllocations=0;
            for(unsigned frame=0;frame<5;++frame) {
                for(unsigned draw=0;draw<160;++draw) {
                    for(unsigned v=0;v<many.size();++v) {
                        many[v]=triangle[v%3];
                        many[v].position=v%3==0?std::array<float,4>{-1,-1,-0.5f,1}:v%3==1?std::array<float,4>{3,-1,-0.5f,1}:std::array<float,4>{-1,3,-0.5f,1};
                        many[v].color={float(draw&1),float((draw>>1)&1),float((draw>>2)&1),1};
                    }
                    stripe.viewportX=draw;
                    pooled.DrawFrame(solid,many,uniforms,draw?resident:seed,stripe,{},{},true);
                }
                auto result=pooled.ReadFrame();
                for(unsigned y=0;y<8;++y)for(unsigned x=0;x<160;++x) {
                    const auto pixel=y*160+x;
                    for(unsigned c=0;c<3;++c)Check(result.rgba[pixel*4+c]==(((x>>c)&1)?255:0),"In-flight upload slice overwritten");
                    Check(result.rgba[pixel*4+3]==255 && result.stencil[pixel]==37 && std::abs(result.depth[pixel]-0.5f)<0.000001f,"Pooled planes lost depth/stencil contents");
                }
                pooled.DiscardFrame();pooled.DiscardFrame(); // repeated release retains scratch only
                const auto& counters=pooled.Measurements();
                if(frame==1)warmedAllocations=counters.uploadBufferAllocations;
                if(frame>1)Check(counters.uploadBufferAllocations==warmedAllocations,"Warmed upload pool keeps allocating");
            }
            const auto counters=pooled.Measurements();
            Check(counters.targetAllocations==1 && counters.targetReuses==4,"Framebuffer target reuse failed");
            Check(counters.readbackBufferAllocations==3 && counters.readbackBufferReuses==12,"Readback scratch reuse failed");
            // A size change must replace the targets without stale dimensions.
            auto resized=pooled.Draw(solid,triangle,uniforms,320,16);
            Check(resized.size()==320*16*4,"Pooled target resize failed");
            std::cout << "Resource pool validation: 800 distinct queued draws, upload allocations=" << counters.uploadBufferAllocations
                      << " reuse=" << counters.uploadBufferReuses << ", target allocations=" << counters.targetAllocations
                      << " reuse=" << counters.targetReuses << ", readback allocations=" << counters.readbackBufferAllocations
                      << " reuse=" << counters.readbackBufferReuses << " passed\n";
        }
        TestDisplayTransfers(context,solid,triangle,uniforms);
        regs.framebuffer.output_merger.logic_op.Assign(F::LogicOp::Xor);
        bool rejected = false;
        try { CompileFragment(Pica::Shader::FSConfig(regs)); } catch (const std::exception&) { rejected = true; }
        Check(rejected, "Unsupported logic operation silently accepted");
        const auto& stats = context.Measurements();
        Check(stats.draws == 163 && stats.pipelineHits >= 3 && stats.pipelineBuilds <= 21, "Pipeline cache counters mismatch");
        std::cout << "Native Metal PICA: primary colour 1x-4x, texture sampling, all ten TEV operations vs upstream CPU reference (1-LSB tolerance), fog LUT, alpha discard, native blending, framebuffer preservation, depth/stencil round-trip, colour masks, tiled format transfers, compute display copies/scaling/format conversion from memory and GPU images, deferred output ownership and out-of-order resolution, asynchronous target recycling, resident GPU scanout versus CPU reference in all five formats, true 2x raster detail and scaled depth/color aliases, exact-size screen compositor, native vertex input/uniform ABI, alias subrectangles, exact D24S8 reinterpretation and partial-write coherence, retained multi-batch framebuffer coherence, pipeline reuse and unsupported-state rejection passed. GPU time " << stats.gpuSeconds << " s\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
