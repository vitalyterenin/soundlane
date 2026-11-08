#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${SOUNDLANE_OUTPUT_DIR:-$HOME/Library/Developer/SoundLane}"
python3 scripts/build-driver.py
objects=()
for obj in "$out/DriverBuild/"*.o; do
    case "$obj" in */SoundLane-Driver.o) ;; *) objects+=("$obj");; esac
done
xcrun clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -Wno-reorder-init-list \
    -I Vendor/libASPL/include Tests/DriverTests.cpp "${objects[@]}" \
    -framework CoreAudio -framework CoreFoundation -o "$out/DriverTests"
"$out/DriverTests"
swift build --scratch-path "$out/Build"
bin="$(swift build --scratch-path "$out/Build" --show-bin-path)"
"$bin/SoundLane" --self-test
"$bin/SoundLane" --list-devices
