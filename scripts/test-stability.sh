#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${SOUNDLANE_OUTPUT_DIR:-$HOME/Library/Developer/SoundLane}"
modules="$output_dir/StabilityModules"
mkdir -p "$modules"
# Compile the production bridge/model directly. SwiftPM's generated object and
# module-map locations differ between Command Line Tools and Xcode releases.
python3 - "$modules/module.modulemap" <<'PY'
import json,pathlib,sys
header=pathlib.Path('Sources/AudioBridge/include/AudioBridge.h').resolve()
pathlib.Path(sys.argv[1]).write_text('module AudioBridge { header '+json.dumps(str(header))+' export * }\n')
PY
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.2 -arch arm64 \
    -I Sources/AudioBridge/include -c Sources/AudioBridge/AudioBridge.mm -o "$output_dir/StabilityAudioBridge.o"
swiftc -parse-as-library -swift-version 5 -I "$modules" \
    -Xcc "-fmodule-map-file=$modules/module.modulemap" \
    Sources/SoundLane/AudioRuntime.swift Sources/SoundLane/Models.swift Sources/SoundLane/Views.swift \
    Tests/Stability/LifecycleTests.swift "$output_dir/StabilityAudioBridge.o" \
    -framework CoreAudio -framework AVFoundation -lc++ -o "$output_dir/StabilityTests"
"$output_dir/StabilityTests"
