#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${SOUNDLANE_OUTPUT_DIR:-$HOME/Library/Developer/SoundLane}"
build_dir="${SOUNDLANE_BUILD_DIR:-$output_dir/Build}"
mkdir -p "$output_dir"
export SOUNDLANE_OUTPUT_DIR="$output_dir"
python3 scripts/build-driver.py
swift build --scratch-path "$build_dir" -c release --arch arm64
binary_dir="$(swift build --scratch-path "$build_dir" -c release --arch arm64 --show-bin-path)"
staging="$(mktemp -d "$output_dir/.stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/SoundLane.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$app/Contents/Library/Audio/Plug-Ins/HAL"
cp "$binary_dir/SoundLane" "$app/Contents/MacOS/SoundLane"
python3 scripts/release.py plist "$app/Contents/Info.plist"
ditto "$output_dir/SoundLane.driver" "$app/Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver"
framework="$(python3 - "$build_dir" <<'PY'
import pathlib,sys
matches=list(pathlib.Path(sys.argv[1], 'artifacts').glob('**/macos-*/Sparkle.framework'))
if len(matches)!=1: raise SystemExit('Expected one pinned Sparkle framework')
print(matches[0])
PY
)"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
# This app is not sandboxed; no optional downloader/installer XPC services are used.
python3 - "$sparkle/Versions/B/XPCServices" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1])
if p.exists():shutil.rmtree(p)
PY
for executable in "$sparkle/Versions/B/Sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    if [[ "$(lipo -archs "$executable")" != arm64 ]]; then
        lipo "$executable" -thin arm64 -output "$executable.arm64"
        mv "$executable.arm64" "$executable"
    fi
done
python3 scripts/licenses.py install --app "$app" --sparkle-license "$build_dir/checkouts/Sparkle/LICENSE"
python3 scripts/signing.py sign-driver --driver "$app/Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver"
python3 scripts/package.py driver "$app/Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver" "$app/Contents/Resources/SoundLane Audio Component.pkg"
cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
swift scripts/make-icon.swift "$staging/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$staging/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$staging/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
python3 scripts/signing.py sign --app "$app"
if [ -e "$output_dir/SoundLane.app" ]; then mv "$output_dir/SoundLane.app" "$staging/previous.app"; fi
mv "$app" "$output_dir/SoundLane.app"
printf 'Built: %s\n' "$output_dir/SoundLane.app"
