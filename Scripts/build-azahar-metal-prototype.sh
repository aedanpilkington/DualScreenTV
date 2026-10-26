#!/bin/bash
# Standalone native Metal validation only. Does not replace the shipping core.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="${DSTV_METAL_WORK_ROOT:-$repo_root/.build/azahar-metal-prototype}"
azahar_commit=219d743a1e698101fe1ab8bef43e6563126c3c27
cross_commit=ebe2aa0cd80f5eb5cd8a605da604cacf72205f3b
mkdir -p "$work_root"
fetch_pinned() {
    local url="$1" directory="$2" revision="$3"
    if [[ ! -d "$directory/.git" ]]; then
        git init "$directory"
        git -C "$directory" remote add origin "$url"
        git -C "$directory" fetch --depth 1 origin "$revision"
        git -C "$directory" checkout --detach FETCH_HEAD
    fi
    [[ "$(git -C "$directory" rev-parse HEAD)" == "$revision" ]]
}
fetch_pinned https://github.com/azahar-emu/azahar.git "$work_root/core" "$azahar_commit"
# Only shader-generator dependencies are needed; no JIT or game assets.
git -C "$work_root/core" submodule update --init --depth 1 \
    externals/boost externals/fmt externals/sirit externals/spirv-headers externals/xxHash
fetch_pinned https://github.com/KhronosGroup/SPIRV-Cross.git "$work_root/spirv-cross" "$cross_commit"
cmake -S "$repo_root/Scripts/Azahar/Metal" -B "$work_root/host-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DAZAHAR_SOURCE="$work_root/core" -DSPIRV_CROSS_SOURCE="$work_root/spirv-cross"
cmake --build "$work_root/host-build" -j 6
MTL_DEBUG_LAYER=1 "$work_root/host-build/metal-pica-tests" "$work_root/generated-fragment.metal"
cmake -S "$repo_root/Scripts/Azahar/Metal" -B "$work_root/tvos-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DAZAHAR_SOURCE="$work_root/core" -DSPIRV_CROSS_SOURCE="$work_root/spirv-cross"
cmake --build "$work_root/tvos-build" -j 6
xcrun -sdk appletvos metal -std=ios-metal2.3 -c "$work_root/generated-fragment.metal" -o "$work_root/generated-fragment.air"
# The prototype must have no Vulkan/MoltenVK API dependency.
if nm -u "$work_root/host-build/metal-pica-tests" | rg -q '_(vk[A-Z]|MVK|MoltenVK)'; then
    echo 'Unexpected Vulkan/MoltenVK runtime dependency' >&2
    exit 1
fi
echo "Native Metal validation complete. Shipping Azahar core unchanged."
