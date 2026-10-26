#!/bin/bash
set -euo pipefail
# Experimental high-resolution DS core, GPL-2.0; no OpenGL or JIT.
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${DSTV_DESMUME_SOURCE_DIR:-$root/build/desmume}"
pin=95b4d798731caa809125b6c3c11d17cc332ff6ef
if ! git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git clone https://github.com/libretro/desmume.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$pin" ]] || git -C "$source_dir" checkout "$pin"
patch="$root/Scripts/Patches/desmume-tvos-high-resolution.patch"
if git -C "$source_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
    : # Already patched.
else
    git -C "$source_dir" apply --check "$patch"
    git -C "$source_dir" apply "$patch"
fi
metal_patch="$root/Scripts/Patches/desmume-metal-fragments.patch"
if ! git -C "$source_dir" apply --reverse --check "$metal_patch" >/dev/null 2>&1; then
    git -C "$source_dir" apply --check "$metal_patch"
    git -C "$source_dir" apply "$metal_patch"
fi
# Upstream slot sources use CRLF; the lifecycle patch uses LF.
python3 - "$source_dir" <<'PYNEWLINES'
from pathlib import Path
import sys
for name in ('slot1.cpp', 'slot2.cpp', 'render3D.cpp'):
    p = Path(sys.argv[1]) / 'desmume/src' / name
    p.write_bytes(p.read_bytes().replace(b'\r\n', b'\n'))
PYNEWLINES
lifecycle_patch="$root/Scripts/Patches/desmume-reinitialization.patch"
if ! git -C "$source_dir" apply --reverse --check "$lifecycle_patch" >/dev/null 2>&1; then
    git -C "$source_dir" apply --check "$lifecycle_patch"
    git -C "$source_dir" apply "$lifecycle_patch"
fi
cp "$root/Scripts/DeSmuME/MetalRasterizer.h" "$source_dir/desmume/src/MetalRasterizer.h"
cp "$root/Scripts/DeSmuME/DSColorConvert.h" "$source_dir/desmume/src/DSColorConvert.h"
metal_build="$source_dir/dstv-metal-build"
mkdir -p "$metal_build"
python3 - "$root/Scripts/DeSmuME/MetalRasterizer.metal" "$metal_build/MetalShaderSource.h" <<'PYSHADER'
import pathlib, sys
shader = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text('static const char dstvMetalShaderSource[] = R"DSTV(' + shader + ')DSTV";\n')
PYSHADER
# Reuse DeSmuME's vectorized compositor/capture paths as native ARM NEON.
neon_source="${DSTV_SSE2NEON_SOURCE_DIR:-$root/build/sse2neon}"
neon_pin=60fc9391e378b58c60899791c0e9ee9cdaf43c08
if ! git -C "$neon_source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git clone https://github.com/DLTcollab/sse2neon.git "$neon_source"
fi
[[ "$(git -C "$neon_source" rev-parse HEAD)" == "$neon_pin" ]] || git -C "$neon_source" checkout "$neon_pin"
mkdir -p "$metal_build/neon"
cp "$neon_source/sse2neon.h" "$metal_build/neon/sse2neon.h"
cp "$root/Scripts/DeSmuME/NEON/"*.h "$metal_build/neon/"
neon_flags="-DENABLE_SSE -DENABLE_SSE2 -I${metal_build}/neon"
sdk="$(xcrun --sdk appletvos --show-sdk-path)"
xcrun --sdk appletvos clang++ -arch arm64 -isysroot "$sdk" -mtvos-version-min=17.0 \
    -std=c++17 -O3 -fobjc-arc -DDSTV_METAL -D__RETRO_ARM__ $neon_flags \
    -I"$source_dir/desmume/src" -I"$source_dir/desmume/src/libretro-common/include" -I"$metal_build" \
    -c "$root/Scripts/DeSmuME/MetalRasterizer.mm" -o "$metal_build/MetalRasterizer.o"
# Force a consistent rebuild: Make does not track flags or the external Metal object.
make -B -C "$source_dir/desmume/src/frontend/libretro" -j8 platform=tvos-arm64 DESMUME_JIT=0 DESMUME_JIT_ARM=0 DESMUME_OPENGL=0 DESMUME_OPENGL_CORE=0 EXTRA_CPPFLAGS="-DDSTV_METAL $neon_flags" LIBS="${metal_build}/MetalRasterizer.o -framework Metal -framework Foundation"
output="$root/Apps/tvOS/DualScreenTV/Frameworks/desmume_libretro.dylib"
cp "$source_dir/desmume/src/frontend/libretro/desmume_libretro_tvos.dylib" "$output"
install_name_tool -id @rpath/desmume_libretro.dylib "$output"
strip -x "$output"
