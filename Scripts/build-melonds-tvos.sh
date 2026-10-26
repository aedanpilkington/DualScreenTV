#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/build/melonds-ds"
pin=a3c57f066870c18d3104895f52a1fe08794e2cdc
mkdir -p "$root/build" "$root/Apps/tvOS/DualScreenTV/Frameworks"
if [[ ! -d "$source_dir/.git" ]]; then
    git clone https://github.com/JesseTG/melonds-ds.git "$source_dir"
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$pin" ]]; then
    [[ -z "$(git -C "$source_dir" status --porcelain)" ]] || { echo 'Modified melonDS checkout; use a clean build directory.' >&2; exit 1; }
    git -C "$source_dir" checkout "$pin"
fi
cmake -S "$source_dir" -B "$source_dir/build-tvos" -G Ninja \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_TOOLCHAIN_FILE="$source_dir/cmake/toolchain/ios.toolchain.cmake" \
    -DPLATFORM=TVOS -DDEPLOYMENT_TARGET=17.0 -DENABLE_BITCODE=OFF \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_AS_SHARED_LIBRARY=ON \
    -DBUILD_TESTING=OFF -DENABLE_JIT=OFF -DENABLE_OPENGL=OFF
cmake --build "$source_dir/build-tvos" --target melondsds_libretro -j 8
output="$root/Apps/tvOS/DualScreenTV/Frameworks/melondsds_libretro.dylib"
cp "$source_dir/build-tvos/src/libretro/melondsds_libretro.dylib" "$output"
install_name_tool -id @rpath/melondsds_libretro.dylib "$output"
strip -x "$output"
cp "$source_dir/build-tvos/melondsds-LICENSE.txt" "$root/Apps/tvOS/DualScreenTV/DualScreenTV/CoreLicenses/melonDS-ThirdParty.txt"
