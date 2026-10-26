#!/bin/bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_output="$(mktemp -d)"
trap 'rm -rf "$test_output"' EXIT
cd "$repo_root"
source_dir=Apps/tvOS/DualScreenTV/DualScreenTV
backup_shared=Shared/Companion/Sources/DualScreenLink/AutomaticSaveBackup.swift
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/StickDirections.swift" Tests/StickDirectionsTests.swift \
    -o "$test_output/stick-tests"
"$test_output/stick-tests"
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$source_dir" Tests/AudioRingTests.c "$source_dir/AudioRing.c" \
    -o "$test_output/audio-tests"
"$test_output/audio-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$backup_shared" "$source_dir/SaveStorage.swift" Tests/SaveStorageTests.swift \
    -o "$test_output/save-tests"
"$test_output/save-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/AudioLifecycle.swift" Tests/AudioLifecycleTests.swift \
    -o "$test_output/audio-lifecycle-tests"
"$test_output/audio-lifecycle-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/FrontendPreferences.swift" "$source_dir/ScreenShortcut.swift" Tests/FrontendPreferencesTests.swift \
    -o "$test_output/preferences-tests"
"$test_output/preferences-tests" "$source_dir/Settings.bundle/Root.plist"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/FrontendPreferences.swift" "$source_dir/ScreenShortcut.swift" "$source_dir/GamePreferences.swift" Tests/GamePreferencesTests.swift \
    -o "$test_output/game-preferences-tests"
"$test_output/game-preferences-tests"

swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/FramePacer.swift" Tests/FramePacerTests.swift \
    -o "$test_output/pacer-tests"
"$test_output/pacer-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/DSResolutionController.swift" Tests/DSResolutionControllerTests.swift \
    -o "$test_output/ds-resolution-tests"
"$test_output/ds-resolution-tests"

swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/StateStorage.swift" Tests/StateStorageTests.swift \
    -o "$test_output/state-tests"
"$test_output/state-tests"

swiftc -parse-as-library -default-isolation MainActor \
    "$backup_shared" "$source_dir/SaveStorage.swift" "$source_dir/SaveManager.swift" \
    "$source_dir/StateStorage.swift" "$source_dir/StateManager.swift" Tests/StateManagerTests.swift \
    -o "$test_output/state-manager-tests"
"$test_output/state-manager-tests"

clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$source_dir" Tests/PixelEnhancementTests.c "$source_dir/PixelEnhancement.c" \
    -o "$test_output/pixel-tests"
"$test_output/pixel-tests"

clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    Tests/DSColorConvertTests.c -o "$test_output/ds-color-tests"
"$test_output/ds-color-tests"

clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$source_dir" Tests/VideoFramesTests.c "$source_dir/VideoFrames.c" \
    -o "$test_output/video-tests"
"$test_output/video-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/FrontendPreferences.swift" "$source_dir/ScreenShortcut.swift" Tests/ScreenShortcutTests.swift \
    -o "$test_output/shortcut-tests"
"$test_output/shortcut-tests"

swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/GameArtwork.swift" "$source_dir/GameLibrary.swift" "$backup_shared" "$source_dir/SaveStorage.swift" \
    "$source_dir/StateStorage.swift" "$source_dir/SaveTransfer.swift" \
    "$source_dir/TransferHTTP.swift" Tests/ArtworkFixture.swift Tests/GameLibraryTests.swift \
    -o "$test_output/library-tests"
"$test_output/library-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$source_dir/GameArtwork.swift" "$source_dir/GameLibrary.swift" "$backup_shared" "$source_dir/SaveStorage.swift" \
    "$source_dir/StateStorage.swift" "$source_dir/SaveTransfer.swift" \
    "$source_dir/TransferHTTP.swift" "$source_dir/TransferPage.swift" \
    "$source_dir/AutomaticBackupSource.swift" "$source_dir/LocalTransferServer.swift" Tests/ArtworkFixture.swift Tests/TransferServerTests.swift \
    -o "$test_output/transfer-server-tests"
swiftc -parse-as-library -default-isolation MainActor \
    "$backup_shared" "$source_dir/GameArtwork.swift" "$source_dir/GameLibrary.swift" "$source_dir/SaveStorage.swift" \
    "$source_dir/StateStorage.swift" "$source_dir/SaveTransfer.swift" "$source_dir/TransferHTTP.swift" \
    "$source_dir/TransferPage.swift" "$source_dir/AutomaticBackupSource.swift" "$source_dir/LocalTransferServer.swift" \
    Tests/ArtworkFixture.swift Tests/AutomaticBackupTests.swift -o "$test_output/automatic-backup-tests"
"$test_output/automatic-backup-tests"

"$test_output/transfer-server-tests"

clang -O1 -std=c17 -Wall -Wextra -Werror -Wl,-dead_strip \
    Tests/BridgeInputTests.c "$source_dir/VideoFrames.c" -o "$test_output/bridge-input-tests"
"$test_output/bridge-input-tests"

swiftc -parse-as-library -default-isolation MainActor \
    Apps/iPadOS/DualScreenTVCompanion/DualScreenTVCompanion/TransferAddress.swift \
    Tests/CompanionTransferAddressTests.swift -o "$test_output/companion-address-tests"
"$test_output/companion-address-tests"

swift test --package-path Shared/Companion
