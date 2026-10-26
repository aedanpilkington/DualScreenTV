#!/bin/bash
# Experimental headless GPU measurement only; not a playable libretro core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${DSTV_DUST_BUILD_DIR:-$ROOT/build/dust}"
REV=76d79f25e4ea3ce355c4ac868f5ac9a233e64b89
TOOLCHAIN=nightly-2025-12-18
mkdir -p "$WORK"
if [[ ! -d "$WORK/dust/.git" ]]; then
    git clone https://github.com/kelpsyberry/dust.git "$WORK/dust"
fi
if [[ "$(git -C "$WORK/dust" rev-parse HEAD)" != "$REV" ]]; then
    if [[ -n "$(git -C "$WORK/dust" status --porcelain)" ]]; then
        echo 'Dust checkout is modified at a different revision; use another DSTV_DUST_BUILD_DIR.' >&2
        exit 1
    fi
    git -C "$WORK/dust" checkout "$REV"
fi
if git -C "$WORK/dust" apply --check "$ROOT/Scripts/Patches/dust-gpu-benchmark.patch" 2>/dev/null; then
    git -C "$WORK/dust" apply "$ROOT/Scripts/Patches/dust-gpu-benchmark.patch"
else
    git -C "$WORK/dust" apply --reverse --check "$ROOT/Scripts/Patches/dust-gpu-benchmark.patch"
fi
mkdir -p "$WORK/bench/src"
cp "$ROOT/Scripts/Dust/${DSTV_DUST_MODE:-benchmark}.rs" "$WORK/bench/src/lib.rs"
cp "$ROOT/Scripts/Dust/Cargo.lock" "$WORK/bench/Cargo.lock"
python3 - "$WORK" <<'PY'
import pathlib, sys
w=pathlib.Path(sys.argv[1]); d=w/'dust'
(w/'bench/Cargo.toml').write_text(f'''[package]
name = "dstv-dust-bench"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
dust-core = {{ path = "{d}/core" }}
dust-wgpu-2d = {{ path = "{d}/render/wgpu-2d" }}
dust-wgpu-3d = {{ path = "{d}/render/wgpu-3d", features = ["threaded"] }}
wgpu = "=23.0.1"
pollster = "=0.4.0"
serde_json = "1"
libc = "0.2"
naga = {{ version = "=23.1.0", features = ["msl-out"] }}
[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
panic = "abort"
''')
PY
cargo +"$TOOLCHAIN" fetch --manifest-path "$WORK/bench/Cargo.toml"
python3 - "$WORK" <<'PY'
import pathlib, shutil, sys, os, re
w=pathlib.Path(sys.argv[1]); registry=pathlib.Path(os.environ.get('CARGO_HOME',str(pathlib.Path.home()/'.cargo')))/'registry/src'
packages={'wgpu':'23.0.1','wgpu-core':'23.0.1','wgpu-hal':'23.0.1','metal':'0.29.0','block':'0.1.6','objc':'0.2.7'}
with (w/'bench/Cargo.toml').open('a') as f:
 f.write('\n[patch.crates-io]\n')
 for name,version in packages.items():
  matches=list(registry.glob(f'*/{name}-{version}'))
  if not matches: raise RuntimeError(f'Missing fetched crate {name}-{version}')
  dst=w/'platform'/name
  shutil.copytree(matches[0],dst,dirs_exist_ok=True)
  for p in list(dst.rglob('*.rs'))+list(dst.rglob('Cargo.toml')):
   s=p.read_text()
   s=s.replace('target_os = "ios"','any(target_os = "ios", target_os = "tvos")')
   s=s.replace(r'target_os = \"ios\"',r'any(target_os = \"ios\", target_os = \"tvos\")')
   s=s.replace(r'target_os=\"ios\"',r'any(target_os=\"ios\", target_os=\"tvos\")')
   s=s.replace('target_os="ios"','any(target_os="ios", target_os="tvos")')
   p.write_text(s)
  f.write(f'{name} = {{ path = "{dst}" }}\n')
PY
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)"
export SDKROOT
export DUST_SOURCE="$WORK/dust"
export RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SDKROOT -C link-arg=-Wl,-fixup_chains -C link-arg=-Wl,-platform_version,tvos,17.0,27.0 -C link-arg=-Wl,-install_name,@rpath/dust_${DSTV_DUST_MODE:-benchmark}.dylib"
cargo +"$TOOLCHAIN" build -Zbuild-std=std,panic_abort --target aarch64-apple-tvos --release --lib --manifest-path "$WORK/bench/Cargo.toml"
output="$WORK/bench/target/aarch64-apple-tvos/release/libdstv_dust_bench.dylib"
if [[ "${DSTV_DUST_MODE:-benchmark}" == libretro ]]; then
    cp "$output" "$ROOT/Apps/tvOS/DualScreenTV/Frameworks/dust_libretro.dylib"
    cp "$WORK/dust/LICENSE" "$ROOT/Apps/tvOS/DualScreenTV/DualScreenTV/Dust-LICENSE.txt"
    python3 "$ROOT/Scripts/Dust/collect-licenses.py" "$WORK/bench/Cargo.toml" "$ROOT/Apps/tvOS/DualScreenTV/DualScreenTV/Dust-THIRD-PARTY-LICENSES.txt" "$TOOLCHAIN"
fi
echo "$output"
