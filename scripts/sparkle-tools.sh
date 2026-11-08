#!/bin/bash
set -euo pipefail
# Keep this version in sync with Package.swift.
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
cache="${SOUNDLANE_TOOLS_DIR:-$HOME/Library/Developer/SoundLane/Sparkle-$version}"
if [[ ! -x "$cache/bin/generate_appcast" ]]; then
    mkdir -p "$cache"
    archive="$(mktemp -t soundlane-sparkle)"
    trap 'rm -f "$archive"' EXIT
    curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$checksum" ]] || { echo "Sparkle checksum mismatch" >&2; exit 1; }
    tar -xJf "$archive" -C "$cache"
fi
printf '%s\n' "$cache"
