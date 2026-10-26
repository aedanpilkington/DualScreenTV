// SPDX-License-Identifier: GPL-2.0-or-later
#include "MetalDraw.h"
#include "video_core/pica/regs_internal.h"
#include "video_core/pica/shader_setup.h"
#include "video_core/shader/generator/glsl_shader_decompiler.h"
#include "video_core/renderer_vulkan/vk_shader_util.h"
#include <spirv_msl.hpp>
#include <fmt/format.h>
#include <stdexcept>
#include <atomic>
namespace AzaharMetal {
VertexProgram CompileVertex(Pica::ShaderSetup& setup,const Pica::RegsInternal& regs) {
    setup.DoProgramCodeFixup();
    auto program=Pica::Shader::Generator::GLSL::DecompileProgram(setup.GetProgramCode(),setup.GetSwizzleData(),regs.vs.main_offset,
        [](u32 r){return fmt::format("inputs[{}]",r);},[](u32 r){return fmt::format("outputs[{}]",r);},true);
    if(program.empty()) throw std::runtime_error("PICA vertex program cannot be decompiled");
    std::string source=R"(
#version 450
layout(set=0,binding=0,std140) uniform PicaUniforms { uint b;uvec4 i[4];vec4 f[96]; } uniforms;
layout(set=0,binding=1,std430) readonly buffer VertexInputs { vec4 v[]; } inputData;
layout(set=0,binding=2,std430) readonly buffer VertexOrder { uint v[]; } orderData;
layout(set=0,binding=3,std140) uniform VertexState { uint enableClip;uint flip;vec4 coefficient; } state;
layout(location=1) out vec4 primaryColor;
layout(location=2) out vec2 uv0;
layout(location=3) out vec2 uv1;
layout(location=4) out vec2 uv2;
layout(location=5) out float uv0w;
layout(location=6) out vec4 quaternion;
layout(location=7) out vec3 view;
out gl_PerVertex { invariant vec4 gl_Position;float gl_ClipDistance[2]; };
vec4 inputs[16];vec4 outputs[16];
)";
    source+=program;
    source+="\nvoid runVertex(uint index) {\n conditional_code=bvec2(false);address_registers=ivec3(0);\n";
    for(unsigned r=0;r<16;++r) source+=fmt::format("inputs[{0}]=inputData.v[index*16u+{0}u];outputs[{0}]=vec4(0,0,0,1);reg_tmp{0}=vec4(0,0,0,1);\n",r);
    source+="exec_shader();\n}\n";
    // Map compacted enabled output registers to PICA's semantic slots exactly as
    // ShaderUnit::WriteOutput followed by OutputVertex does.
    std::array<std::string,32> slots;slots.fill("1.0");
    unsigned attribute=0;
    for(unsigned reg=0;reg<16;++reg)if(regs.vs.output_mask&(1u<<reg)) {
        if(attribute<(regs.rasterizer.vs_output_total&7)) {
            const auto map=regs.rasterizer.vs_output_attributes[attribute];
            const unsigned semantics[]={unsigned(map.map_x),unsigned(map.map_y),unsigned(map.map_z),unsigned(map.map_w)};
            for(unsigned c=0;c<4;++c)slots[semantics[c]]=fmt::format("outputs[{}].{}",reg,"xyzw"[c]);
        }
        ++attribute;
    }
    auto vector=[&](unsigned start,unsigned n) {
        std::string value=fmt::format("vec{}(",n);
        for(unsigned i=0;i<n;++i)value+=(i?",":"")+slots[start+i];
        return value+")";
    };
    using S=Pica::RasterizerRegs::VSOutputAttributes;
    const auto quat=vector(S::QUATERNION_X,4);
    source+="void main() {\n vec4 firstQuaternion;\n";
    source+="runVertex(orderData.v[(uint(gl_VertexIndex)/3u)*3u]);firstQuaternion="+quat+";\n";
    source+="runVertex(orderData.v[gl_VertexIndex]);quaternion="+quat+";\n";
    source+="if(dot(firstQuaternion,quaternion)<0.0)quaternion=-quaternion;\n";
    source+="vec4 position="+vector(S::POSITION_X,4)+";\n";
    source+=R"(
float ndc=position.z/position.w;
if(ndc>0.0 && ndc<0.000001)position.z=0.0;
if(ndc< -1.0 && ndc> -1.00001)position.z=-position.w;
gl_Position=vec4(position.xy,-position.z,position.w);
if(state.flip!=0u)gl_Position.y=-gl_Position.y;
gl_ClipDistance[0]=-position.z;
gl_ClipDistance[1]=state.enableClip!=0u?dot(state.coefficient,position):0.0;
)";
    source+="primaryColor=min(abs("+vector(S::COLOR_R,4)+"),vec4(1.0));\n";
    source+="uv0="+vector(S::TEXCOORD0_U,2)+";uv1="+vector(S::TEXCOORD1_U,2)+";uv2="+vector(S::TEXCOORD2_U,2)+";\n";
    source+="uv0w="+slots[S::TEXCOORD0_W]+";view="+vector(S::VIEW_X,3)+";\n}\n";
    // Reuse upstream's GLSL -> SPIR-V compiler only. No Vulkan device, pipeline,
    // command buffer or MoltenVK translation participates in this vertex path.
    auto words=Vulkan::CompileGLSL(source,vk::ShaderStageFlagBits::eVertex,"");
    if(words.empty())throw std::runtime_error("PICA vertex GLSL compilation failed");
    spirv_cross::CompilerMSL compiler(std::move(words));
    auto options=compiler.get_msl_options();options.platform=spirv_cross::CompilerMSL::Options::iOS;options.set_msl_version(2,3);
    compiler.set_msl_options(options);
    for(auto [binding,buffer]:{std::pair{0u,2u},{1u,0u},{2u,3u},{3u,1u}}) {
        spirv_cross::MSLResourceBinding r{};r.stage=spv::ExecutionModelVertex;r.desc_set=0;r.binding=binding;r.msl_buffer=buffer;compiler.add_msl_resource_binding(r);
    }
    static std::atomic<uint64_t> nextIdentity{};
    VertexProgram result;result.identity=++nextIdentity;result.source=compiler.compile();result.entry=compiler.get_cleansed_entry_point_name("main",spv::ExecutionModelVertex);return result;
}
}
