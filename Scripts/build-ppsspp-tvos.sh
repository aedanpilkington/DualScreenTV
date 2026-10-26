#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${DSTV_PPSSPP_SOURCE_DIR:-$root/build/ppsspp}"
pin=dd6bd1a53d38773c1d07985fcb7d2f56fcaa872c
if [[ ! -d "$source_dir/.git" ]]; then git clone --no-checkout https://github.com/hrydgard/ppsspp.git "$source_dir"; fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$pin" ]] || git -C "$source_dir" checkout "$pin"
git -C "$source_dir" submodule update --init --recursive
patch_file="$root/Scripts/Patches/ppsspp-tvos-offscreen.patch"
if git -C "$source_dir" apply --check "$patch_file"; then git -C "$source_dir" apply "$patch_file"; else git -C "$source_dir" apply --reverse --check "$patch_file"; fi
cp "$root/Scripts/PPSSPP/offscreen_vulkan.cpp" "$root/Scripts/PPSSPP/offscreen_vulkan.h" "$source_dir/libretro/"
moltenvk_dir="${DSTV_MOLTENVK_DIR:-$root/build/moltenvk}"
if [[ ! -f "$moltenvk_dir/MoltenVK/MoltenVK/include/vulkan/vulkan.h" ]]; then
 archive="$source_dir/MoltenVK-1.4.1.tar"
 curl -L --fail https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-all.tar -o "$archive"
 [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == 2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557 ]]
 mkdir -p "$moltenvk_dir"; tar -xf "$archive" -C "$moltenvk_dir"
fi
build_dir="${DSTV_PPSSPP_BUILD_DIR:-$source_dir/dstv-tvos}"
cmake -S "$source_dir" -B "$build_dir" -G Ninja \
 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos \
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_SYSTEM_PROCESSOR=arm64 \
 -DCMAKE_BUILD_TYPE=Release -DIOS=ON -DIOS_PLATFORM=TVOS -DIOS_APP_STORE=ON -DLIBRETRO=ON \
 -DNO_OPENGL=OFF -DUSING_GLES2=ON -DOPENGL_LIBRARIES='-framework OpenGLES' \
 -DUSE_FFMPEG=ON -DFFMPEG_DIR="$source_dir/ffmpeg/tvos/arm64" -DUSE_MINIUPNPC=OFF \
 -DUSE_DISCORD=OFF -DUNITTEST=OFF -DHEADLESS=OFF -DUSE_SYSTEM_ZLIB=OFF -DUSE_SYSTEM_LIBPNG=OFF \
 -DDSTV_MOLTENVK_LIBRARY="$moltenvk_dir/MoltenVK/MoltenVK/static/MoltenVK.xcframework/tvos-arm64_arm64e/libMoltenVK.a" \
 -DDSTV_MOLTENVK_HEADERS="$moltenvk_dir/MoltenVK/MoltenVK/include" \
 -DCMAKE_C_FLAGS='-DDSTV_TVOS -DGL_ETC1_RGB8_OES=0' -DCMAKE_CXX_FLAGS='-DDSTV_TVOS -DGL_ETC1_RGB8_OES=0'
cmake --build "$build_dir" --target ppsspp_libretro -j8
output="$root/Apps/tvOS/DualScreenTV/Frameworks/ppsspp_libretro.dylib"
cp "$build_dir/lib/ppsspp_libretro.dylib" "$output"
install_name_tool -id @rpath/ppsspp_libretro.dylib "$output"
strip -x "$output"
assets="$root/Apps/tvOS/DualScreenTV/DualScreenTV/PPSSPP"
mkdir -p "$assets"
for name in compat.ini lang shaders flash0 ppge_atlas.zim ppge_atlas.meta; do cp -R "$source_dir/assets/$name" "$assets/"; done
