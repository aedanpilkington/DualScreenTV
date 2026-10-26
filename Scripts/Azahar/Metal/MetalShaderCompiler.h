// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>
#include <vector>
#include <memory>
#include <cstdint>
#include "video_core/shader/generator/pica_fs_config.h"

namespace AzaharMetal {
struct Binding {
    unsigned set, binding, buffer, texture, sampler;
};
struct FragmentShader {
    const std::string source,entry;
    const uint64_t identity;
};
struct FragmentProgram {
    std::shared_ptr<const FragmentShader> shader;
    std::vector<Binding> bindings;
    bool blendEnabled = false;
    std::array<unsigned, 6> blend{}; // RGB equation/source/dest, then alpha.
};
// Shader IR only: emits MSL without creating a Vulkan device or command buffer.
// Unsupported operations throw instead of silently substituting another effect.
FragmentProgram CompileFragment(const Pica::Shader::FSConfig& config);
}
