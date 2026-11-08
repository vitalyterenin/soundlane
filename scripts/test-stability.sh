#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${SOUNDLANE_OUTPUT_DIR:-$HOME/Library/Developer/SoundLane}"
swift build --scratch-path "$output_dir/Build"
# Compile the actual model with a standalone assertion runner: CLT has no XCTest.
binary_dir="$(swift build --scratch-path "$output_dir/Build" --show-bin-path)"
swiftc -parse-as-library -swift-version 5 -I Sources/AudioBridge/include \
    -Xcc "-fmodule-map-file=$output_dir/Build/out/Intermediates.noindex/GeneratedModuleMaps/AudioBridge.modulemap" \
    Sources/SoundLane/AudioRuntime.swift Sources/SoundLane/Models.swift Sources/SoundLane/Views.swift \
    Tests/Stability/LifecycleTests.swift "$binary_dir/AudioBridge.o" \
    -framework CoreAudio -framework AVFoundation -lc++ -o "$output_dir/StabilityTests"
"$output_dir/StabilityTests"
