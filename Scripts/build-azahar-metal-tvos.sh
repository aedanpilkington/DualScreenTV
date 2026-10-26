#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$repo_root/build/azahar-metal-2126.2}"
if [[ ! -d "$source_dir/.git" ]]; then
    git clone --depth 1 --branch 2126.2 --recurse-submodules --shallow-submodules \
        https://github.com/azahar-emu/azahar.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == 219d743a1e698101fe1ab8bef43e6563126c3c27 ]]
# Remove our renderer patches before rechecking their overlapping base patches.
screen_blit_patch="$repo_root/Scripts/Patches/azahar-metal-screen-blit.patch"
if git -C "$source_dir" apply --reverse --check "$screen_blit_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$screen_blit_patch"
fi
resolution_scale_patch="$repo_root/Scripts/Patches/azahar-metal-resolution-scale.patch"
# This is a deletion-only patch: reverse applicability alone also matches pristine
# upstream. Only peel it after the Metal API registration has actually been added.
if git -C "$source_dir" grep -q -F 'if (name == "Metal")' -- src/citra_libretro/core_settings.cpp && \
   git -C "$source_dir" apply --reverse --check "$resolution_scale_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$resolution_scale_patch"
fi
metal_patch="$repo_root/Scripts/Patches/azahar-native-metal-registration.patch"
hybrid_patch="$repo_root/Scripts/Patches/azahar-native-metal-hybrid.patch"
if git -C "$source_dir" apply --reverse --check "$hybrid_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$hybrid_patch"
fi
if git -C "$source_dir" apply --reverse --check "$metal_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$metal_patch"
fi
# Peel only our exact extension before checking the older scanout patch.
resident_scanout_patch="$repo_root/Scripts/Patches/azahar-metal-resident-scanout.patch"
if git -C "$source_dir" apply --reverse --check "$resident_scanout_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$resident_scanout_patch"
fi
decoder_masks_patch="$repo_root/Scripts/Patches/azahar-metal-decoder-masks.patch"
if git -C "$source_dir" apply --reverse --check "$decoder_masks_patch" 2>/dev/null; then
    git -C "$source_dir" apply --reverse "$decoder_masks_patch"
fi
for patch_file in "$repo_root/Scripts/Patches/azahar-direct-touch.patch" "$repo_root/Scripts/Patches/azahar-offscreen-vulkan.patch" "$repo_root/Scripts/Patches/azahar-interpreter-decode-cache.patch" "$repo_root/Scripts/Patches/azahar-vulkan-present-sync.patch" "$repo_root/Scripts/Patches/azahar-presentation-cadence.patch" "$repo_root/Scripts/Patches/azahar-live-resolution.patch" "$repo_root/Scripts/Patches/azahar-native-metal-profiling.patch" "$repo_root/Scripts/Patches/azahar-metal-interpreter-stack.patch" "$repo_root/Scripts/Patches/azahar-metal-decoder-masks.patch" "$repo_root/Scripts/Patches/azahar-metal-scanout-cache.patch" "$repo_root/Scripts/Patches/azahar-metal-resident-scanout.patch"; do
    if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
        git -C "$source_dir" apply "$patch_file"
    else
        git -C "$source_dir" apply --reverse --check "$patch_file"
    fi
done
git -C "$source_dir" apply --check "$metal_patch"
git -C "$source_dir" apply "$metal_patch"
git -C "$source_dir" apply --check "$hybrid_patch"
git -C "$source_dir" apply "$hybrid_patch"
git -C "$source_dir" apply --check "$resolution_scale_patch"
git -C "$source_dir" apply "$resolution_scale_patch"
git -C "$source_dir" apply --check "$screen_blit_patch"
git -C "$source_dir" apply "$screen_blit_patch"
spirv_dir="$source_dir/build/spirv-cross"
if [[ ! -d "$spirv_dir/.git" ]]; then
    git clone --depth 1 --branch vulkan-sdk-1.4.304.1 https://github.com/KhronosGroup/SPIRV-Cross.git "$spirv_dir"
fi
[[ "$(git -C "$spirv_dir" rev-parse HEAD)" == ebe2aa0cd80f5eb5cd8a605da604cacf72205f3b ]]
cp "$repo_root/Scripts/Azahar/offscreen_vulkan.cpp" "$repo_root/Scripts/Azahar/offscreen_vulkan.h" "$source_dir/src/citra_libretro/"
cp "$repo_root/Scripts/Azahar/Metal/MetalScreenBlit.h" "$source_dir/src/citra_libretro/emu_window/"
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
    -DDSTV_NATIVE_METAL_DIR="$repo_root/Scripts/Azahar/Metal" \
    -DDSTV_SPIRV_CROSS_DIR="$spirv_dir" \
    -DDSTV_MOLTENVK_LIBRARY="$moltenvk_dir/MoltenVK/MoltenVK/static/MoltenVK.xcframework/tvos-arm64_arm64e/libMoltenVK.a"
cmake --build "$source_dir/build/dstv-tvos" --target citra_libretro -j 8
cp "$source_dir/build/dstv-tvos/bin/Release/azahar_libretro.dylib" \
    "$repo_root/Apps/tvOS/DualScreenTV/Frameworks/azahar_metal_libretro.dylib"
strip -x "$repo_root/Apps/tvOS/DualScreenTV/Frameworks/azahar_metal_libretro.dylib"
install_name_tool -id @rpath/azahar_metal_libretro.dylib "$repo_root/Apps/tvOS/DualScreenTV/Frameworks/azahar_metal_libretro.dylib"
