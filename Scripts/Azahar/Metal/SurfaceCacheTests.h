// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalSurfaceCache.h"
#include "MetalFramebuffer.h"
#include <random>
inline void TestSurfaceCache() {
    using namespace AzaharMetal;
    auto check=[](bool ok,const char* message){if(!ok)throw std::runtime_error(message);};
    SurfaceRange range{0x1000,0x100};
    check(range.CoveredBy(0x1000,0x100) && range.CoveredBy(0xff0,0x120),"Full overwrite not recognised");
    check(!range.CoveredBy(0x1001,0xff) && !range.CoveredBy(0x1000,0xff) && !range.CoveredBy(0,0),"Partial overwrite discarded live bytes");
    check(!SurfaceRange{UINT64_MAX-8,8}.CoveredBy(UINT64_MAX-4,UINT64_MAX),"Overflowing overwrite containment");
    SurfaceOwner owner;
    owner.valid=true;owner.generation=1;
    owner.color={{0x18000000,256*512*4},256,512,4,0,true};
    owner.depth={{0x19000000,256*512*4},256,512,4,3,true};
    auto topTransfer=owner.FindColorTransfer(0x18000000+114688,256,240,400,4,0);
    auto bottomTransfer=owner.FindColorTransfer(0x18000000+196608,256,240,320,4,0);
    check(topTransfer && topTransfer->y==112 && bottomTransfer && bottomTransfer->y==192,"Contained display footprint missed");
    check(!owner.FindColorTransfer(0x18000000+196608,256,240,400,4,0),"Display copy escaped resident surface");
    check(!owner.FindColorTransfer(0x18000004,256,240,400,4,0),"Unaligned display input accepted");
    check(!owner.FindColorTransfer(0x18000000,128,120,400,4,0),"Mismatched display stride accepted");
    for(unsigned offset:{0u,114688u,196608u}) {
        const auto c=owner.FindRGBA8(owner.color.range.address+offset,256,128);
        const auto d=owner.FindRGBA8(owner.depth.range.address+offset,256,128);
        check(c && d && c->y==offset/1024 && d->depth,"Tile-aligned ORAS subrect alias was missed");
    }
    check(!owner.FindRGBA8(owner.color.range.address+114688,256,512),"Out-of-bounds nominal ORAS transfer was accepted");
    check(!owner.FindRGBA8(owner.color.range.address+4,256,128),"Unaligned alias accepted");
    check(!owner.FindRGBA8(owner.color.range.address,128,128),"Incompatible tiled stride accepted");
    check(owner.FindRGBA8(owner.color.range.address+256,8,8).has_value(),"Single tile subrect missed");
    check(!owner.FindRGBA8(owner.color.range.address+256*31,16,8),"Subrect crossing row edge accepted");
    auto invalid=owner;invalid.color.tiled=false;check(!invalid.FindRGBA8(invalid.color.range.address,256,128),"Linear/tiled reinterpret accepted");
    invalid=owner;invalid.depth.format=2;check(!invalid.FindRGBA8(invalid.depth.range.address,256,128),"Unsupported depth format accepted");
    invalid=owner;invalid.Invalidate();check(!invalid.FindRGBA8(owner.color.range.address,256,128),"Invalidated owner reused");
    check(owner.Overlaps(owner.depth.range.address+4095,2),"Cross-page CPU write overlap missed");
    check(!owner.Overlaps(owner.depth.range.address+owner.depth.range.bytes,4),"Adjacent range overlaps owner");

    Pica::RegsInternal regs{};
    using T=Pica::TexturingRegs::TevStageConfig;
    using F=Pica::FramebufferRegs;
    regs.framebuffer.output_merger.logic_op.Assign(F::LogicOp::Copy);regs.lighting.disable.Assign(1);
    auto stage=[](T::Source source){T result{};result.color_source1.Assign(source);result.alpha_source1.Assign(source);return result;};
    regs.texturing.tev_stage0=stage(T::Source::PrimaryColor);
    regs.texturing.tev_stage1=regs.texturing.tev_stage2=regs.texturing.tev_stage3=regs.texturing.tev_stage4=regs.texturing.tev_stage5=stage(T::Source::Previous);
    auto solid=CompileFragment(Pica::Shader::FSConfig(regs));
    regs.texturing.main_config.texture0_enable.Assign(1);regs.texturing.tev_stage0=stage(T::Source::Texture0);
    auto textured=CompileFragment(Pica::Shader::FSConfig(regs));
    std::array<Vertex,3> triangle{};
    triangle[0].position={-1,-1,-0.5,1};triangle[1].position={3,-1,-0.5,1};triangle[2].position={-1,3,-0.5,1};
    triangle[0].uv0={0,1};triangle[1].uv0={2,1};triangle[2].uv0={0,-1};
    for(auto& v:triangle){v.color={1,1,1,1};v.uv0w=1;v.quaternion={0,0,0,1};}
    Pica::Shader::Generator::FSUniformData uniforms{};uniforms.framebuffer_scale=1;uniforms.depth_scale=1;
    DrawContext context;context.SetProfilingEnabled(true);
    Frame frame;frame.width=256;frame.height=512;
    const size_t count=size_t(frame.width)*frame.height;
    frame.rgba.resize(count*4);frame.depth.resize(count);frame.stencil.resize(count);
    std::mt19937 random(0x51ac);
    for(size_t i=0;i<count;++i) {
        for(unsigned c=0;c<4;++c)frame.rgba[i*4+c]=random();
        frame.depth[i]=float(random()&0xffffff)/16777215.f;
        frame.stencil[i]=random();
    }
    DrawState preserve;preserve.colorMask=0;preserve.depthWrite=false;
    for(bool depth:{false,true})for(unsigned dirty=0;dirty<(depth?4u:1u);++dirty)for(unsigned offset:{0u,256u,114688u,196608u}) {
        const auto alias=owner.FindRGBA8((depth?owner.depth:owner.color).range.address+offset,offset==256?8:256,offset==256?8:128);
        check(bool(alias),"Reference alias missing");
        const unsigned width=alias->width,height=alias->height;
        std::vector<uint8_t> original(size_t(width)*height*4);
        for(auto& b:original)b=random();
        Texture expected;expected.width=width;expected.height=height;expected.rgba.resize(original.size());
        FramebufferTransfer::Tiles(width,height,[&](size_t linear,size_t tiled) {
            const unsigned x=linear%width,y=linear/width;
            const size_t source=(size_t(alias->y+y)*frame.width+alias->x+x);
            auto* output=expected.rgba.data()+(size_t(height-1-y)*width+x)*4;
            if(!depth)std::memcpy(output,frame.rgba.data()+source*4,4);
            else {
                uint8_t packed[4];std::memcpy(packed,original.data()+tiled*4,4);
                if(dirty&1)Common::Color::EncodeD24(uint32_t(double(frame.depth[source])*16777215),packed);
                if(dirty&2)packed[3]=frame.stencil[source];
                auto color=Common::Color::DecodeRGBA8(packed);std::memcpy(output,color.AsArray(),4);
            }
        });
        context.DrawFrame(solid,triangle,uniforms,frame,preserve,{},{},true);
        const auto bytesBefore=context.Measurements().readbackBytes;
        Texture actual;actual.width=width;actual.height=height;actual.rgba.clear();
        actual.native=context.SnapshotSurface(alias->x,alias->y,width,height,depth,dirty&1,dirty&2,original);
        check(context.Measurements().readbackBytes==bytesBefore,"GPU alias snapshot performed CPU readback");
        Frame output;output.width=width;output.height=height;output.rgba.assign(original.size(),0);output.depth.assign(size_t(width)*height,1);output.stencil.assign(size_t(width)*height,0);
        auto image=context.DrawFrame(textured,triangle,uniforms,output,{},std::span(&actual,1),{});
        auto reference=context.DrawFrame(textured,triangle,uniforms,output,{},std::span(&expected,1),{});
        check(image.rgba==reference.rgba,"GPU alias packing/orientation differs from CPU materialisation");
        // Immutable snapshots survive owner replacement and later draw commands.
        context.DiscardFrame();
        auto again=context.DrawFrame(textured,triangle,uniforms,output,{},std::span(&actual,1),{});
        check(again.rgba==reference.rgba,"Owner transition corrupted snapshot");
    }
    // Pooling may recycle only snapshots no longer held by the CPU and whose
    // last GPU consumer completed. Keep one old handle while cycling new images.
    {
        DrawContext pool;
        Frame seed;seed.width=seed.height=8;seed.rgba.assign(8*8*4,255);seed.depth.assign(64,1);seed.stencil.assign(64,0);
        pool.DrawFrame(solid,triangle,uniforms,seed,preserve,{},{},true);
        auto held=pool.SnapshotSurface(0,0,8,8,false);
        const auto original=pool.ReadTexture(held);
        for(unsigned i=0;i<16;++i) {
            SurfaceClear clear;clear.color=true;clear.rgba={uint8_t(i),42,87,255};pool.ClearSurface(clear);
            auto next=pool.SnapshotSurface(0,0,8,8,false);const auto bytes=pool.ReadTexture(next);
            for(size_t p=0;p<64;++p)for(unsigned c=0;c<4;++c)check(bytes[p*4+c]==clear.rgba[c],"Recycled snapshot has stale texels");
            check(pool.ReadTexture(held)==original,"Snapshot recycled while still held");
        }
        check(pool.Measurements().snapshotTextureAllocations<=3 && pool.Measurements().snapshotTextureReuses>=14,"Snapshot pool did not reuse completed images");
        check(pool.Measurements().aliasScratchAllocations==2,"Alias scratch repeatedly allocated");
        // A second queue consuming an image disqualifies its original lease.
        DrawContext foreign;Texture texture;texture.width=texture.height=8;texture.native=held;texture.rgba.clear();
        Frame output=seed;
        foreign.DrawFrame(textured,triangle,uniforms,output,{},std::span(&texture,1),{},true);
        check(pool.ReadTexture(held)==original,"Foreign consumer changed immutable snapshot");
        texture.native.reset();held.reset();
        SurfaceClear changed;changed.color=true;changed.rgba={100,101,102,255};pool.ClearSurface(changed);
        auto recycled=pool.SnapshotSurface(0,0,8,8,false);pool.ReadTexture(recycled);
        const auto foreignResult=foreign.ReadFrame();
        for(auto value:foreignResult.rgba)check(value==255,"Snapshot reused while foreign queue still referenced it");
    }
    // Independent double-precision oracle for exact GPU D24 packing. Include
    // tiny floats, D24-derived values, dense [0.5,1) mantissas and endpoints.
    {
        DrawContext precision;
        Frame frame;frame.width=frame.height=1024;
        const size_t pixels=1024*1024;
        frame.rgba.resize(pixels*4);frame.depth.resize(pixels);frame.stencil.resize(pixels);
        std::mt19937 random(1749);
        for(size_t i=0;i<pixels;++i) {
            uint32_t bits=(i&1)?(0x3f000000u|(random()&0x7fffff)):(random()%0x3f800001u);
            std::memcpy(&frame.depth[i],&bits,4);
            if(i%4==0)frame.depth[i]=float(random()&0xffffffu)/16777215.f;
            frame.stencil[i]=uint8_t(random());
        }
        frame.depth[0]=0;frame.depth[1]=1;frame.depth[2]=0.5f;
        precision.DrawFrame(solid,triangle,uniforms,frame,preserve,{},{},true);
        auto packed=precision.ReadTexture(precision.SnapshotSurface(0,0,1024,1024,true));
        for(unsigned y=0;y<1024;++y)for(unsigned x=0;x<1024;++x) {
            const size_t src=size_t(1023-y)*1024+x,dst=size_t(y)*1024+x;
            const uint32_t z=uint32_t(double(frame.depth[src])*16777215.0);
            const std::array<uint8_t,4> expected{frame.stencil[src],uint8_t(z>>16),uint8_t(z>>8),uint8_t(z)};
            check(std::memcmp(packed.data()+dst*4,expected.data(),4)==0,"Exact 32-bit D24 packing differs from double oracle");
        }
    }
    // Test uniform fill decoding against complete CPU fill -> tiled import,
    // across every supported framebuffer colour/depth format and fill width.
    for(unsigned colorFormat=0;colorFormat<5;++colorFormat)for(unsigned depthFormat:{0u,2u,3u})for(unsigned pattern:{2u,3u,4u}) {
        const auto cf=F::ColorFormat(colorFormat);const auto df=F::DepthFormat(depthFormat);
        constexpr uint32_t value=0x12abcdef;
        auto fillBytes=[&](auto format,unsigned pixels) {
            unsigned bpp=0;
            if constexpr(std::is_same_v<decltype(format),F::ColorFormat>)FramebufferTransfer::ColorFormat(format,[&]<auto,unsigned Bpp>() {bpp=Bpp;});
            else FramebufferTransfer::DepthFormat(format,[&]<auto,unsigned Bpp,unsigned>() {bpp=Bpp;});
            std::vector<uint8_t> bytes(size_t(pixels)*bpp);
            for(size_t i=0;i<bytes.size();++i)bytes[i]=uint8_t(value>>((i%pattern)*8));
            return bytes;
        };
        auto colorBytes=fillBytes(cf,64),depthBytes=fillBytes(df,64);
        Frame cpu;cpu.width=cpu.height=8;FramebufferTransfer::Import(cpu,colorBytes.data(),depthBytes.data(),cf,df);
        const auto colorFill=FramebufferTransfer::UniformColorFill(cf,pattern,value);
        const auto depthFill=FramebufferTransfer::UniformDepthFill(df,pattern,value);
        DrawContext fills;fills.DrawFrame(solid,triangle,uniforms,cpu,preserve,{},{},true);
        if(colorFill)fills.ClearSurface(*colorFill);
        if(depthFill)fills.ClearSurface(*depthFill);
        const auto actual=fills.ReadFrame();
        check(actual.rgba==cpu.rgba && actual.depth==cpu.depth && actual.stencil==cpu.stencil,"Uniform GPU fill differs from CPU pattern/import");
        check(bool(colorFill)==(colorBytes.size()/64%pattern==0),"Nonuniform colour fill accepted");
        check(bool(depthFill)==(depthBytes.size()/64%pattern==0),"Nonuniform depth fill accepted");
    }
    // Full resident clears must preserve every unselected attachment. Compare
    // packed guest bytes against the CPU fill/import/export path, including
    // D24 quantisation and stencil. No RAM materialisation occurs before clear.
    for(uint32_t pattern:{0u,0xffffffffu,0x12345678u,0x00abcdefu}) {
        context.DrawFrame(solid,triangle,uniforms,frame,preserve,{},{},true);
        SurfaceClear colorClear;colorClear.color=true;colorClear.rgba={12,34,56,78};
        context.ClearSurface(colorClear);
        auto colorResult=context.ReadFrame();
        for(size_t p=0;p<count;++p)for(unsigned c=0;c<4;++c)check(colorResult.rgba[p*4+c]==colorClear.rgba[c],"Resident colour clear differs");
        check(colorResult.depth==frame.depth && colorResult.stencil==frame.stencil,"Colour clear overwrote depth/stencil");
        SurfaceClear depthClear;depthClear.depth=depthClear.stencil=true;
        depthClear.depthValue=float(pattern&0xffffffu)/16777215.f;depthClear.stencilValue=pattern>>24;
        context.ClearSurface(depthClear);auto depthResult=context.ReadFrame();
        check(depthResult.rgba==colorResult.rgba,"Depth clear overwrote colour");
        for(size_t p=0;p<count;++p)check(depthResult.depth[p]==depthClear.depthValue && depthResult.stencil[p]==depthClear.stencilValue,"Resident depth/stencil clear differs");
        // Subsequent draws and GPU snapshots must consume the newly cleared data.
        auto snapshot=context.SnapshotSurface(0,0,256,128,false);
        const auto snapshotBytes=context.ReadTexture(snapshot);
        for(size_t p=0;p<256*128;++p)for(unsigned c=0;c<4;++c)check(snapshotBytes[p*4+c]==colorClear.rgba[c],"Clear not visible to GPU snapshot");
    }
    // A partial CPU write must happen after materialisation and before reimport.
    // Exercise the same export/write/import sequence used by InvalidateRegion.
    context.DrawFrame(solid,triangle,uniforms,frame,preserve,{},{},true);
    auto materialised=context.ReadFrame();
    std::vector<uint8_t> colorRAM(count*4),depthRAM(count*4);
    FramebufferTransfer::Export(materialised,colorRAM.data(),depthRAM.data(),F::ColorFormat::RGBA8,F::DepthFormat::D24S8,true,true,true);
    const auto oldColor=colorRAM,oldDepth=depthRAM;
    colorRAM[114688+5]=123;depthRAM[196608+3]=77;
    owner.Invalidate();context.DiscardFrame();
    Frame imported;imported.width=256;imported.height=512;
    FramebufferTransfer::Import(imported,colorRAM.data(),depthRAM.data(),F::ColorFormat::RGBA8,F::DepthFormat::D24S8);
    auto after=context.DrawFrame(solid,triangle,uniforms,imported,preserve,{},{});
    std::vector<uint8_t> afterColor(count*4),afterDepth(count*4);
    // Preserve untouched depth bytes: a no-depth-write draw does not export depth.
    afterDepth=depthRAM;
    FramebufferTransfer::Export(after,afterColor.data(),afterDepth.data(),F::ColorFormat::RGBA8,F::DepthFormat::D24S8,true,false,false);
    check(afterColor==colorRAM && afterDepth==depthRAM,"Partial overlapping CPU write lost on transition");
    for(size_t i=0;i<count*4;++i) {
        if(i!=114688+5)check(colorRAM[i]==oldColor[i],"Partial CPU write changed adjacent colour bytes");
        if(i!=196608+3)check(depthRAM[i]==oldDepth[i],"Partial CPU write changed adjacent depth bytes");
    }
    // Partial native writes must be visible to aliases while untouched channels
    // and pixels retain their imported values.
    context.DrawFrame(solid,triangle,uniforms,imported,preserve,{},{},true);
    Frame retained;retained.width=256;retained.height=512;
    DrawState partial;partial.colorMask=1;partial.depthWrite=true;
    partial.viewportX=16;partial.viewportY=32;partial.viewportWidth=128;partial.viewportHeight=128;
    partial.stencilEnabled=true;partial.stencilFunc=1;partial.depthPass=2;
    partial.stencilRef=13;partial.stencilWriteMask=15;
    context.DrawFrame(solid,triangle,uniforms,retained,partial,{},{},true);
    auto updated=context.ReadFrame();
    FramebufferTransfer::Export(updated,colorRAM.data(),depthRAM.data(),F::ColorFormat::RGBA8,F::DepthFormat::D24S8,true,true,true);
    for(bool depth:{false,true}) {
        auto native=context.SnapshotSurface(0,0,256,512,depth,true,true);
        const auto actual=context.ReadTexture(native);
        std::vector<uint8_t> expected(actual.size());
        const auto& packed=depth?depthRAM:colorRAM;
        FramebufferTransfer::Tiles(256,512,[&](size_t linear,size_t tiled) {
            auto color=Common::Color::DecodeRGBA8(packed.data()+tiled*4);
            const size_t x=linear%256,y=linear/256;
            std::memcpy(expected.data()+((511-y)*256+x)*4,color.AsArray(),4);
        });
        check(actual==expected,"Partial native framebuffer update missing from GPU alias");
    }
    context.DiscardFrame();

}
