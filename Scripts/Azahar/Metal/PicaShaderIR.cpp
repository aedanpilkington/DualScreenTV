// SPDX-License-Identifier: GPL-2.0-or-later
// Keep Sirit's scoped SPIR-V enums separate from SPIRV-Cross's legacy enums.
#include "video_core/shader/generator/pica_fs_config.h"
#include "video_core/shader/generator/spv_fs_shader_gen.h"
namespace AzaharMetal {
std::vector<uint32_t> GenerateFragmentIR(const Pica::Shader::FSConfig& config,
                                       const Pica::Shader::Profile& profile) {
    return Pica::Shader::Generator::SPIRV::GenerateFragmentShader(config, profile);
}
}
