#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for command in git cmake ninja python3 xcrun cargo rustup; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command (see README.md)" >&2; exit 1; }
done
xcrun --sdk appletvos --show-sdk-path >/dev/null
mkdir -p "$root/build" "$root/Apps/tvOS/DualScreenTV/Frameworks"
for core in melonds desmume dust mgba ppsspp azahar azahar-metal; do
    echo "Building $core for physical Apple TV…"
    bash "$root/Scripts/build-$core-tvos.sh"
done
echo 'Cores built. Open the Xcode project and configure your own signing team.'
