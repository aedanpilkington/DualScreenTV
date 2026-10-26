// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
namespace AzaharMetal {
// The PICA command processor and rasterizer share one emulation thread.
// Detailed per-vertex timers sample one batch in 64; coarse totals are exact.
struct CpuProfile {
    double totalSeconds=0, sampledVertexSeconds=0, sampledGeometrySeconds=0;
    uint64_t batches=0, vertices=0, invocations=0, geometryBatches=0;
    uint64_t sampledBatches=0, sampledInvocations=0, sampledSubmissions=0;
};
inline CpuProfile cpuProfile;
inline uint64_t cpuProfileSequence=0;
}
