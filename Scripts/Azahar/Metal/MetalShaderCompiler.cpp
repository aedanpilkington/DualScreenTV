// SPDX-License-Identifier: GPL-2.0-or-later
#include "MetalShaderCompiler.h"
#include <spirv_msl.hpp>
#include <stdexcept>
#include <atomic>
#include <map>
#include <mutex>
#include "video_core/shader/generator/shader_uniforms.h"

namespace AzaharMetal {
std::vector<uint32_t> GenerateFragmentIR(const Pica::Shader::FSConfig&, const Pica::Shader::Profile&);
FragmentProgram CompileFragment(const Pica::Shader::FSConfig& config) {
    using F = Pica::FramebufferRegs;
    using T = Pica::TexturingRegs;
    if (config.texture.texture0_type == T::TextureConfig::TextureType::TextureCube)
        throw std::runtime_error("Metal prototype: cube texture upload unsupported");
    if (config.UsesSpirvIncompatibleConfig() || config.texture.fog_mode == T::FogMode::Gas)
        throw std::runtime_error("Metal prototype: shadow/gas shader unsupported");
    if (!config.framebuffer.alphablend_enable &&
        config.framebuffer.requested_logic_op != F::LogicOp::Copy &&
        config.framebuffer.requested_logic_op != F::LogicOp::Clear &&
        config.framebuffer.requested_logic_op != F::LogicOp::Set)
        throw std::runtime_error("Metal prototype: destination logic operation unsupported");
    Pica::Shader::Profile profile{};
    profile.is_vulkan = true; // Upstream SPIR-V coordinate/resource dialect, not a runtime API.
    profile.enable_accurate_mul = true;
    auto words = GenerateFragmentIR(config, profile);
    spirv_cross::CompilerMSL compiler(std::move(words));
    auto options = compiler.get_msl_options();
    options.platform = spirv_cross::CompilerMSL::Options::iOS;
    options.set_msl_version(2, 3);
    options.enable_decoration_binding = false;
    options.texel_buffer_texture_width = 4096;
    compiler.set_msl_options(options);
    FragmentProgram result;
    result.blendEnabled = config.framebuffer.alphablend_enable;
    if (result.blendEnabled) {
        const auto& rgb = config.framebuffer.requested_rgb_blend;
        const auto& alpha = config.framebuffer.requested_alpha_blend;
        if (rgb.eq == F::BlendEquation::Min || rgb.eq == F::BlendEquation::Max ||
            alpha.eq == F::BlendEquation::Min || alpha.eq == F::BlendEquation::Max)
            throw std::runtime_error("Metal prototype: PICA min/max blend factors need emulation");
        result.blend = {unsigned(rgb.eq), unsigned(rgb.src_factor), unsigned(rgb.dst_factor),
                        unsigned(alpha.eq), unsigned(alpha.src_factor), unsigned(alpha.dst_factor)};
    }
    for (const auto& resource : compiler.get_shader_resources().uniform_buffers) {
        if (compiler.get_declared_struct_size(compiler.get_type(resource.base_type_id)) != sizeof(Pica::Shader::Generator::FSUniformData))
            throw std::runtime_error("PICA/Metal fragment uniform ABI mismatch");
    }
    // Stable native slots. Do not rely on dead-resource elimination or reflection order.
    auto bind = [&](unsigned set, unsigned binding, unsigned buffer, unsigned texture, unsigned sampler) {
        spirv_cross::MSLResourceBinding r{};
        r.stage = spv::ExecutionModelFragment;
        r.desc_set = set; r.binding = binding;
        r.msl_buffer = buffer; r.msl_texture = texture; r.msl_sampler = sampler;
        compiler.add_msl_resource_binding(r);
        result.bindings.push_back({set, binding, buffer, texture, sampler});
    };
    bind(0, 2, 0, 0, 0); // FSUniformData
    for (unsigned i = 0; i < 3; ++i) bind(0, 3 + i, 1 + i, 3 + i, 3 + i); // LUTs
    for (unsigned i = 0; i < 3; ++i) bind(1, i, 4 + i, i, i); // PICA textures
    // Intern at compilation time, never copy/compare shader text on a draw.
    // Shared immutable objects survive program copies; IDs cannot alias after
    // cache eviction or allocator address reuse.
    static std::mutex shaderMutex;
    static std::atomic<uint64_t> nextIdentity{0};
    static std::map<std::pair<std::string,std::string>,std::weak_ptr<const FragmentShader>> shaders;
    auto key=std::make_pair(compiler.compile(),compiler.get_cleansed_entry_point_name("main",spv::ExecutionModelFragment));
    std::lock_guard lock(shaderMutex);
    if(auto found=shaders.find(key);found!=shaders.end())result.shader=found->second.lock();
    if(!result.shader) {
        result.shader=std::make_shared<const FragmentShader>(FragmentShader{key.first,key.second,++nextIdentity});
        if(shaders.size()>=256)shaders.clear();
        shaders[std::move(key)]=result.shader;
    }
    return result;
}
}
