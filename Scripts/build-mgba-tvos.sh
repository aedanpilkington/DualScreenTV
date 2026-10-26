#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${DSTV_MGBA_SOURCE_DIR:-$root/build/mgba}"
pin=26b7884bc25a5933960f3cdcd98bac1ae14d42e2
if [[ ! -d "$source_dir/.git" ]]; then git clone https://github.com/mgba-emu/mgba.git "$source_dir"; fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$pin" ]] || git -C "$source_dir" checkout "$pin"
cmake -S "$source_dir" -B "$source_dir/dstv-tvos" -G Ninja \
 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos \
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
 -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
 -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DUSE_FFMPEG=OFF -DUSE_PNG=OFF \
 -DUSE_ZLIB=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_SQLITE3=OFF -DUSE_LUA=OFF \
 -DUSE_LZMA=OFF -DUSE_DEBUGGERS=OFF -DUSE_GDB_STUB=OFF
cmake --build "$source_dir/dstv-tvos" --target mgba_libretro -j8
output="$root/Apps/tvOS/DualScreenTV/Frameworks/mgba_libretro.dylib"
cp "$source_dir/dstv-tvos/mgba_libretro.dylib" "$output"
install_name_tool -id @rpath/mgba_libretro.dylib "$output"
strip -x "$output"
