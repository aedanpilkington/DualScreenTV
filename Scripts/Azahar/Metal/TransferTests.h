// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "MetalFramebuffer.h"
#include "MetalSurfaceCache.h"
#include "TransferOwnership.h"
#include "SoftwareScanout.h"
#include "MetalResolution.h"
#include "MetalScreenBlit.h"
namespace AzaharMetal {
inline void TestDisplayTransfers(DrawContext& context,const FragmentProgram& program,std::span<const Vertex> triangle,const Pica::Shader::Generator::FSUniformData& uniforms) {
    // Ownership must survive shared pages, partial overwrites, and 32-bit ends.
    {
        TransferRange range{4090,20};std::set<uint32_t> pages;
        range.AddPages(pages);TransferRange{4100,9000}.AddPages(pages);
        std::vector<uint32_t> flat;range.AddPages(flat);TransferRange{4100,9000}.AddPages(flat);
        std::sort(flat.begin(),flat.end());flat.erase(std::unique(flat.begin(),flat.end()),flat.end());
        if(std::set<uint32_t>(flat.begin(),flat.end())!=pages)throw std::runtime_error("Flat cached-page union lost an owner");
        if(pages!=std::set<uint32_t>{0,4096,8192,12288} || !range.Overlaps(4109,1) || range.Overlaps(4110,1) || range.Overlaps(4090,0) || range.CoveredBy(4091,20) || !range.CoveredBy(4080,30))
            throw std::runtime_error("Transfer ownership range/page union incorrect");
        if(!TransferRange{0xfffffff0,16}.CoveredBy(0xffffffe0,32) || TransferRange{0xfffffff0,16}.Overlaps(0,16))
            throw std::runtime_error("Transfer ownership address arithmetic overflow");
    }
    // Several distinct in-flight outputs must retain their own contents even
    // when resolved out of order and after later transfers reuse the source.
    {
        DrawContext queued;
        std::vector<std::shared_ptr<TransferTicket>> tickets;
        std::vector<std::vector<uint8_t>> expected;
        const DisplayTransfer transfer{16,16,16,16,0,0,1,1,0,0,0};
        for(unsigned i=0;i<12;++i) {
            std::vector<uint8_t> source(16*16*4,uint8_t(i*19));
            expected.push_back(source);
            tickets.push_back(queued.EnqueueTransfer(transfer,source));
        }
        for(int i=11;i>=0;--i)if(queued.ResolveTransfer(tickets[i])!=expected[i])
            throw std::runtime_error("Deferred transfer output was overwritten or reordered");
        // Recycle a retained target while its transfer still uses it. A later
        // upload must be ordered after the old GPU read without a CPU drain.
        Frame initial;initial.width=16;initial.height=16;initial.rgba.assign(1024,73);
        initial.depth.assign(256,0.5f);initial.stencil.assign(256,0);
        DrawState preserve;preserve.colorMask=0;preserve.depthWrite=false;
        queued.DrawFrame(program,triangle,uniforms,initial,preserve,{},{},true);
        const DisplayTransfer resident{16,16,16,16,0,0,0,1,0,0,1};
        auto beforeReuse=queued.EnqueueTransfer(resident);
        queued.DiscardFrame();initial.rgba.assign(1024,191);
        queued.DrawFrame(program,triangle,uniforms,initial,preserve,{},{},true);
        auto afterReuse=queued.EnqueueTransfer(resident);
        if(queued.ResolveTransfer(afterReuse)!=std::vector<uint8_t>(1024,191) || queued.ResolveTransfer(beforeReuse)!=std::vector<uint8_t>(1024,73))
            throw std::runtime_error("Asynchronous target recycle overwrote an earlier transfer");
        auto discarded=queued.EnqueueTransfer(transfer,expected.front());discarded.reset();
        if(queued.ResolveTransfer(queued.EnqueueTransfer(transfer,expected.back()))!=expected.back())
            throw std::runtime_error("Discarding transfer ticket corrupted following output");
    }
    // Resident GPU scanout must match the pinned CPU screen ABI byte-for-byte,
    // including its unusual border pixel and all five packed pixel formats.
    {
        DrawContext scanout;
        std::mt19937 random(1937);
        for(auto dimensions:{std::pair{13u,9u},std::pair{240u,320u},std::pair{240u,400u}})
        for(unsigned format=0;format<5;++format) {
            auto [width,height]=dimensions;unsigned bpp=format==0?4:format==1?3:2;
            std::vector<uint8_t> source((size_t(width)*height+1)*bpp);
            for(auto& byte:source)byte=uint8_t(random());
            std::array<uint8_t,4> tail{};std::memcpy(tail.data(),source.data()+source.size()-bpp,bpp);
            DisplayTransfer transfer{width,height,width,height,format,format,1,1,0,0,0};
            auto packed=scanout.EnqueueTransfer(transfer,std::span<const uint8_t>(source.data(),source.size()-bpp));
            auto converted=scanout.EnqueueScanout(packed,width,height,format,tail);
            if(format==0 && width==13) {
                DrawContext foreign;bool rejected=false;
                try {foreign.EnqueueScanout(packed,width,height,format,tail);}catch(const std::exception&) {rejected=true;}
                if(!rejected)throw std::runtime_error("Unordered foreign-queue scanout accepted");
            }
            Scanout::Cache reference;std::vector<uint8_t> expected(size_t(width)*height*4);
            if(!reference.Update(expected,source.data(),source.size(),width,height,Pica::PixelFormat(format),false,{}) || scanout.ResolveTransfer(converted)!=expected)
                throw std::runtime_error("Resident GPU scanout differs from pinned CPU reference");
        }
    }
    // Real ORAS buffers meet at 0x18070800, halfway through a page. The LCD
    // range must not flush the adjacent retained render target.
    {
        SurfaceOwner owner;owner.valid=true;
        owner.color.range={0x18070800,256*512*4};
        owner.depth.range={0x18270800,256*512*4};
        if(owner.Overlaps(0x18038400,240*320*3) || !owner.Overlaps(0x180707ff,2) ||
            !owner.Overlaps(0x18070800,1) || owner.Overlaps(0x18070800+256*512*4,1))
            throw std::runtime_error("Page-adjacent LCD access invalidated exact surface ownership");
    }
    // True 2x rasterisation must retain subpixel detail into the displayed
    // screen while guest CPU transfers and depth aliases stay native-sized.
    {
        DrawContext scaled;
        Frame frame;frame.width=16;frame.height=16;frame.rgba.assign(1024,0);
        frame.depth.assign(256,0.5f);frame.stencil.assign(256,37);
        Resolution::Upscale(frame,2);
        DrawState state;state.viewportWidth=32;state.viewportHeight=32;
        std::array<Vertex,3> edge{triangle[0],triangle[1],triangle[2]};
        edge[0].position={-0.7f,-0.8f,-0.2f,1};edge[1].position={0.9f,-0.3f,-0.6f,1};edge[2].position={-0.4f,0.9f,-0.8f,1};
        scaled.DrawFrame(program,edge,uniforms,frame,state,{},{},true);
        auto physical=scaled.ReadFrame();
        auto guest=Resolution::Downsample(physical,2);
        if(physical.width!=32 || physical.height!=32 || guest.width!=16)throw std::runtime_error("2x target dimensions incorrect");
        bool subpixels=false;
        for(unsigned y=0;y<32;y+=2)for(unsigned x=0;x<32;x+=2)
            if(std::memcmp(physical.rgba.data()+(y*32+x)*4,physical.rgba.data()+((y+1)*32+x+1)*4,4))subpixels=true;
        if(!subpixels)throw std::runtime_error("2x render was only a nearest-upscaled native image");
        DisplayTransfer p{16,16,16,16,0,0,0,1,0,0,1,0,0,2};
        auto ticket=scaled.EnqueueTransfer(p);
        std::vector<uint8_t> expectedGuest(1024);
        for(size_t i=0;i<256;++i)Common::Color::EncodeRGBA8({guest.rgba[i*4],guest.rgba[i*4+1],guest.rgba[i*4+2],guest.rgba[i*4+3]},expectedGuest.data()+i*4);
        if(scaled.ResolveTransfer(ticket)!=expectedGuest || scaled.PresentationScale(ticket)!=2)throw std::runtime_error("2x guest materialisation or presentation scale incorrect");
        std::vector<uint8_t> packed((32*32+1)*4,0),expectedScreen(32*32*4);
        for(size_t i=0;i<1024;++i)Common::Color::EncodeRGBA8({physical.rgba[i*4],physical.rgba[i*4+1],physical.rgba[i*4+2],physical.rgba[i*4+3]},packed.data()+i*4);
        Scanout::Cache oracle;oracle.Update(expectedScreen,packed.data(),packed.size(),32,32,Pica::PixelFormat::RGBA8,false,{});
        if(scaled.ResolveTransfer(scaled.EnqueueScanout(ticket,16,16,0,{},true))!=expectedScreen)throw std::runtime_error("2x screen lost physical raster detail");
        auto colorAlias=scaled.ReadTexture(scaled.SnapshotSurface(0,0,16,16,false,true,true,{},2));
        auto colorGuest=Resolution::DownsampleRGBA(colorAlias,32,32,2,true);
        for(unsigned y=0;y<16;++y)for(unsigned x=0;x<16;++x)
            if(std::memcmp(colorGuest.data()+(y*16+x)*4,guest.rgba.data()+((15-y)*16+x)*4,4))throw std::runtime_error("2x color alias guest sample phase incorrect");
        auto physicalDepth=scaled.ReadTexture(scaled.SnapshotSurface(0,0,16,16,true,true,true,{},2));
        if(physicalDepth.size()!=32*32*4)throw std::runtime_error("2x depth-derived texture fell back to 1x");
        for(unsigned y=0;y<32;++y)for(unsigned x=0;x<32;++x) {
            const size_t pixel=(31-y)*32+x;
            const uint32_t z=uint32_t(double(physical.depth[pixel])*16777215.0);
            const std::array<uint8_t,4> expected{physical.stencil[pixel],uint8_t(z>>16),uint8_t(z>>8),uint8_t(z)};
            if(std::memcmp(physicalDepth.data()+(y*32+x)*4,expected.data(),4))throw std::runtime_error("2x depth texture did not preserve physical samples");
        }
        std::vector<uint8_t> original(1024);
        for(size_t i=0;i<256;++i) {original[i*4]=0x12;original[i*4+1]=0x34;original[i*4+2]=0x56;original[i*4+3]=0x78;}
        for(bool dirtyDepth:{false,true}) {
            auto partial=scaled.ReadTexture(scaled.SnapshotSurface(0,0,16,16,true,dirtyDepth,!dirtyDepth,original,2));
            for(unsigned y=0;y<32;++y)for(unsigned x=0;x<32;++x) {
                const size_t pixel=(31-y)*32+x;
                const uint32_t z=dirtyDepth?uint32_t(double(physical.depth[pixel])*16777215.0):0x563412;
                const std::array<uint8_t,4> expected{dirtyDepth?uint8_t(0x78):physical.stencil[pixel],uint8_t(z>>16),uint8_t(z>>8),uint8_t(z)};
                if(std::memcmp(partial.data()+(y*32+x)*4,expected.data(),4))throw std::runtime_error("2x depth alias changed an untouched component");
            }
        }
        // Exercise actual render binding, not only snapshot readback. Guest
        // texture dimensions stay 16x16 while the native image is truly 32x32.
        Texture binding;binding.width=16;binding.height=16;binding.resolutionScale=2;
        binding.native=scaled.SnapshotSurface(0,0,16,16,true,true,true,{},2);binding.rgba.clear();
        scaled.DrawFrame(program,triangle,uniforms,Frame{32,32},state,std::span(&binding,1),{},true);
        scaled.ReadFrame(); // Complete the producer before using a foreign queue.
        DrawContext consumer;
        auto bound=consumer.Draw(program,triangle,uniforms,16,16,std::span(&binding,1));
        if(bound.size()!=16*16*4)throw std::runtime_error("Scaled native texture binding failed");
        binding.resolutionScale=1;bool rejected=false;
        try {consumer.Draw(program,triangle,uniforms,16,16,std::span(&binding,1));}catch(const std::exception&) {rejected=true;}
        consumer.DiscardFrame(); // Close the encoder after the expected rejection.
        if(!rejected)throw std::runtime_error("Incorrect native texture scale metadata was accepted");
        auto depth=Resolution::DownsampleRGBA(physicalDepth,32,32,2,true);
        for(unsigned y=0;y<16;++y)for(unsigned x=0;x<16;++x) {
            const size_t pixel=(15-y)*16+x;
            const uint32_t z=uint32_t(double(guest.depth[pixel])*16777215.0);
            const std::array<uint8_t,4> expected{guest.stencil[pixel],uint8_t(z>>16),uint8_t(z>>8),uint8_t(z)};
            if(std::memcmp(depth.data()+(y*16+x)*4,expected.data(),4))throw std::runtime_error("2x depth alias differs from native guest sample");
        }
    }
    // Exact-size compositor preserves channel order, zero alpha, row padding
    // and surrounding canvas bytes; mismatched rectangles retain old fallback.
    {
        std::mt19937 random(552);
        for(auto size:{std::pair{13u,9u},std::pair{800u,480u},std::pair{640u,480u}}) {
            auto [width,height]=size;const unsigned left=3,top=2;const size_t pitch=(width+11)*4;
            std::vector<uint8_t> source(size_t(width)*height*4),actual(pitch*(height+5),197),expected=actual;
            for(auto& byte:source)byte=uint8_t(random());
            for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x) {
                auto* dst=expected.data()+size_t(top+y)*pitch+(left+x)*4;const auto* src=source.data()+(size_t(y)*width+x)*4;
                dst[0]=src[2];dst[1]=src[1];dst[2]=src[0];dst[3]=0;
            }
            if(!BlitExactRGBA(source.data(),source.size(),width,height,actual.data(),pitch,height+5,left,top,width,height) || actual!=expected)
                throw std::runtime_error("Exact-size screen compositor differs from reference");
            if(BlitExactRGBA(source.data(),source.size(),width,height,actual.data(),pitch,height+5,left,top,width+1,height) ||
               BlitExactRGBA(source.data(),source.size()-1,width,height,actual.data(),pitch,height+5,left,top,width,height))throw std::runtime_error("Invalid screen compositor input accepted");
        }
    }
    // Source-offset copies model the real 256x512 stride with smaller visible
    // 240x400/240x320 footprints; the nominal input height need not fit the owner.
    {
        DrawContext resident;
        Frame frame;frame.width=256;frame.height=512;frame.rgba.resize(256*512*4);frame.depth.resize(256*512,0.5f);frame.stencil.resize(256*512);
        std::mt19937 values(456);for(auto& value:frame.rgba)value=uint8_t(values());
        DrawState preserve;preserve.colorMask=0;preserve.depthWrite=false;
        resident.DrawFrame(program,triangle,uniforms,frame,preserve,{},{},true);
        for(unsigned sourceY:{112u,192u})for(unsigned scale:{0u,1u,2u})for(unsigned flip:{0u,1u})for(unsigned outputFormat=0;outputFormat<5;++outputFormat) {
            const unsigned height=sourceY==112?400:320,w=240>>(scale!=0),h=height>>(scale==2);
            DisplayTransfer p{256,512,w,h,0,outputFormat,0,1,scale,flip,1,0,sourceY};
            const auto actual=resident.Transfer(p);
            const unsigned bytes=outputFormat==0?4:outputFormat==1?3:2;
            std::vector<uint8_t> expected(w*h*bytes);
            auto read=[&](unsigned x,unsigned y) {auto* c=frame.rgba.data()+((y+sourceY)*256+x)*4;return Common::Vec4<u8>{c[0],c[1],c[2],c[3]};};
            const auto format=outputFormat==2?Pica::FramebufferRegs::ColorFormat::RGB565:outputFormat==3?Pica::FramebufferRegs::ColorFormat::RGB5A1:Pica::FramebufferRegs::ColorFormat(outputFormat);
            for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
                const unsigned sx=x<<(scale!=0),sy=y<<(scale==2);auto c=read(sx,sy);
                if(scale==1)c=((c+read(sx+1,sy))/2).Cast<u8>();
                if(scale==2)c=(((c+read(sx+1,sy))+(read(sx,sy+1)+read(sx+1,sy+1)))/4).Cast<u8>();
                FramebufferTransfer::ColorFormat(format,[&]<auto F,unsigned Bpp>() {FramebufferTransfer::Encode<F>(c,expected.data()+((flip?h-y-1:y)*w+x)*Bpp);});
            }
            if(actual!=expected)throw std::runtime_error("Resident subrectangle display copy differs from CPU reference");
        }
        bool rejected=false;
        try {resident.Transfer({256,512,240,400,0,0,0,1,0,0,1,0,192});}catch(const std::exception&) {rejected=true;}
        if(!rejected)throw std::runtime_error("Out-of-bounds resident display transfer accepted");
    }
    auto offset=[](unsigned x,unsigned y,unsigned width,bool linear) {
        if(linear)return y*width+x;
        unsigned m=0;for(unsigned bit=0;bit<3;++bit){m|=((x>>bit)&1)<<(bit*2);m|=((y>>bit)&1)<<(bit*2+1);}
        return (y/8)*(width/8)*64+(x/8)*64+m;
    };
    auto framebufferFormat=[](unsigned f){return f==2?Pica::FramebufferRegs::ColorFormat::RGB565:(f==3?Pica::FramebufferRegs::ColorFormat::RGB5A1:Pica::FramebufferRegs::ColorFormat(f));};
    auto bpp=[](unsigned f){return f==0?4u:(f==1?3u:2u);};
    Frame image;image.width=16;image.height=16;image.rgba.resize(1024);image.depth.resize(256,1);image.stencil.resize(256);
    std::mt19937 random(789);for(auto& value:image.rgba)value=uint8_t(random());
    DrawState noWrites;noWrites.colorMask=0;noWrites.depthWrite=false;
    context.DrawFrame(program,triangle,uniforms,image,noWrites,{},{},true);
    for(unsigned inputFormat=0;inputFormat<5;++inputFormat)
    for(unsigned outputFormat=0;outputFormat<5;++outputFormat)
    for(unsigned linear=0;linear<2;++linear)for(unsigned scale=0;scale<3;++scale) {
        if(linear && scale)continue;
        std::vector<uint8_t> source(16*16*bpp(inputFormat));
        FramebufferTransfer::ColorFormat(framebufferFormat(inputFormat),[&]<auto Format,unsigned Bpp>() {
            for(unsigned y=0;y<16;++y)for(unsigned x=0;x<16;++x) {
                auto* c=image.rgba.data()+(y*16+x)*4;
                FramebufferTransfer::Encode<Format>({c[0],c[1],c[2],c[3]},source.data()+offset(x,y,16,linear)*Bpp);
            }
        });
        for(unsigned outputLinear=0;outputLinear<2;++outputLinear)for(unsigned flip=0;flip<2;++flip) {
            const unsigned w=16>>(scale!=0),h=16>>(scale==2);
            DisplayTransfer params{16,16,w,h,inputFormat,outputFormat,linear,outputLinear,scale,flip,0};
            std::vector<uint8_t> expected(w*h*bpp(outputFormat));
            auto read=[&](unsigned x,unsigned y) {
                Common::Vec4<u8> value;
                FramebufferTransfer::ColorFormat(framebufferFormat(inputFormat),[&]<auto Format,unsigned Bpp>() {value=FramebufferTransfer::Decode<Format>(source.data()+offset(x,y,16,linear)*Bpp);});
                return value;
            };
            for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
                const unsigned sx=x<<(scale!=0),sy=y<<(scale==2);
                auto value=read(sx,sy);
                if(scale==1)value=((value+read(sx+1,sy))/2).Cast<u8>();
                if(scale==2)value=(((value+read(sx+1,sy))+(read(sx,sy+1)+read(sx+1,sy+1)))/4).Cast<u8>();
                FramebufferTransfer::ColorFormat(framebufferFormat(outputFormat),[&]<auto Format,unsigned Bpp>() {FramebufferTransfer::Encode<Format>(value,expected.data()+offset(x,flip?h-y-1:y,w,outputLinear)*Bpp);});
            }
            auto actual=context.Transfer(params,source);
            if(actual!=expected) {
                const auto at=std::mismatch(actual.begin(),actual.end(),expected.begin()).first-actual.begin();
                throw std::runtime_error("GPU display transfer differs: in="+std::to_string(inputFormat)+" out="+std::to_string(outputFormat)+" linear="+std::to_string(linear)+" outLinear="+std::to_string(outputLinear)+" scale="+std::to_string(scale)+" flip="+std::to_string(flip)+" byte="+std::to_string(at)+" actual="+std::to_string(actual[at])+" expected="+std::to_string(expected[at]));
            }
            if(!linear) {
                params.useImage=1;
                auto direct=context.Transfer(params);
                if(direct!=expected)throw std::runtime_error("Direct GPU framebuffer transfer differs from guest-memory reference");
            }
        }
    }
}
}
