#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${SOUNDLANE_OUTPUT_DIR:-$HOME/Library/Developer/SoundLane}"
mkdir -p "$output_dir"
clang++ -std=c++17 -fobjc-arc Tests/HALTopology.mm -framework Foundation -framework CoreAudio -o "$output_dir/HALTopologyTests"
"$output_dir/HALTopologyTests"
