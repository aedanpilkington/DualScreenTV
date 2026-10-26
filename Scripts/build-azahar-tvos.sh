#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$repo_root/build/azahar-2126.2}"
if [[ ! -d "$source_dir/.git" ]]; then
    git clone --depth 1 --branch 2126.2 --recurse-submodules --shallow-submodules \
        https://github.com/azahar-emu/azahar.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == 219d743a1e698101fe1ab8bef43e6563126c3c27 ]]
for patch_file in "$repo_root/Scripts/Patches/azahar-direct-touch.patch" "$repo_root/Scripts/Patches/azahar-offscreen-vulkan.patch" "$repo_root/Scripts/Patches/azahar-interpreter-decode-cache.patch" "$repo_root/Scripts/Patches/azahar-vulkan-present-sync.patch" "$repo_root/Scripts/Patches/azahar-presentation-cadence.patch" "$repo_root/Scripts/Patches/azahar-live-resolution.patch"; do
    if git -C "$source_dir" apply --check "$patch_file"; then
        git -C "$source_dir" apply "$patch_file"
    else
        git -C "$source_dir" apply --reverse --check "$patch_file"
    fi
done
cp "$repo_root/Scripts/Azahar/offscreen_vulkan.cpp" "$repo_root/Scripts/Azahar/offscreen_vulkan.h" "$source_dir/src/citra_libretro/"
# Pinned Metal implementation; its Apache licence ships in CoreLicenses.
moltenvk_dir="$source_dir/build/MoltenVK-1.4.1"
moltenvk_archive="$source_dir/build/MoltenVK-1.4.1.tar"
if [[ ! -f "$moltenvk_archive" ]]; then
    mkdir -p "$source_dir/build"
    curl -L --fail https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar -o "$moltenvk_archive"
fi
[[ "$(shasum -a 256 "$moltenvk_archive" | cut -d ' ' -f 1)" == 2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557 ]]
if [[ ! -d "$moltenvk_dir" ]]; then
    mkdir -p "$moltenvk_dir"
    tar -xf "$moltenvk_archive" -C "$moltenvk_dir"
fi
cmake -S "$source_dir" -B "$source_dir/build/dstv-tvos" -G Ninja \
    -DENABLE_LIBRETRO=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS=-DIOS -DCMAKE_CXX_FLAGS=-DIOS \
    -DIOS=ON -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF -DCMAKE_OSX_SYSROOT=appletvos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DENABLE_VULKAN=ON -DENABLE_LTO=OFF \
    -DDSTV_MOLTENVK_LIBRARY="$moltenvk_dir/MoltenVK/MoltenVK/static/MoltenVK.xcframework/tvos-arm64_arm64e/libMoltenVK.a"
cmake --build "$source_dir/build/dstv-tvos" --target citra_libretro -j 8
cp "$source_dir/build/dstv-tvos/bin/Release/azahar_libretro.dylib" \
    "$repo_root/Apps/tvOS/DualScreenTV/Frameworks/azahar_libretro.dylib"
strip -x "$repo_root/Apps/tvOS/DualScreenTV/Frameworks/azahar_libretro.dylib"
