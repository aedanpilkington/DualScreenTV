#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -framework Metal -framework Foundation "$root/Tests/DSMetalTests.mm" -o "$output/metal-tests"
"$output/metal-tests" "$root/Scripts/DeSmuME/MetalRasterizer.metal"
