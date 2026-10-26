#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$repo_root/build/azahar-2126.2}"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == 219d743a1e698101fe1ab8bef43e6563126c3c27 ]]
test_output="$(mktemp -d)"
trap 'rm -rf "$test_output"' EXIT
git -C "$source_dir" show HEAD:src/core/arm/dyncom/arm_dyncom_dec.cpp > "$test_output/reference.cpp"
clang++ -O3 -std=c++20 -I "$source_dir/src" -DDecodeARMInstruction=ReferenceDecodeARMInstruction \
    -c "$test_output/reference.cpp" -o "$test_output/reference.o"
clang++ -O3 -std=c++20 -Wall -Wextra -Werror -I "$source_dir/src" \
    "$repo_root/Tests/AzaharDecoderTests.cpp" "$source_dir/src/core/arm/dyncom/arm_dyncom_dec.cpp" \
    "$test_output/reference.o" -o "$test_output/decoder-tests"
"$test_output/decoder-tests"
# Check the same cache replacement and per-thread storage under sanitizers.
clang++ -O1 -g -std=c++20 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I "$source_dir/src" -DDecodeARMInstruction=ReferenceDecodeARMInstruction \
    -c "$test_output/reference.cpp" -o "$test_output/reference-sanitized.o"
clang++ -O1 -g -std=c++20 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer -I "$source_dir/src" \
    "$repo_root/Tests/AzaharDecoderTests.cpp" "$source_dir/src/core/arm/dyncom/arm_dyncom_dec.cpp" \
    "$test_output/reference-sanitized.o" -o "$test_output/decoder-tests-sanitized"
"$test_output/decoder-tests-sanitized"
