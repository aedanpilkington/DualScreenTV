#!/bin/bash
set -euo pipefail
export DSTV_DUST_MODE=libretro
exec "$(dirname "$0")/build-dust-benchmark.sh" "$@"
