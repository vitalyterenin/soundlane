# Build and test

Use an Apple Silicon Mac with Swift 6+, Python 3, and Xcode or Command Line Tools providing a macOS 14.2+ SDK. Dependencies are pinned in Package.resolved and Vendor/libASPL. Sparkle 2.10.1 is fetched by SwiftPM; libASPL is vendored at revision `633e0f70203edd87d320fc5a3cae901e1363aac5`.

From the repository root:

```sh
bash scripts/test.sh
bash scripts/test-stability.sh
python3 -m unittest discover -s Tests/Release -v
bash scripts/build-app.sh
```

Local build output defaults to `~/Library/Developer/SoundLane/SoundLane.app`, outside Documents to avoid file-provider changes invalidating a signed bundle. Override `SOUNDLANE_OUTPUT_DIR` and `SOUNDLANE_BUILD_DIR` when needed. Builds do not install the app/component or change audio defaults.

Local builds use ad hoc signatures and cannot pass release packaging. Do not replace an installed release app with one when testing permission continuity. Release artifacts are built only by GitHub Actions; [release operations](releases.md) describes the signing gates.

## Checks

- `test.sh`: C++ ring/driver checks with AddressSanitizer and UndefinedBehaviorSanitizer, then the actual realtime manual AU graph, EQ, bypass, mute, and channel mapping. No microphone recording or live audio I/O.
- `test-stability.sh`: the actual AppModel with fake device/pipeline snapshots and a test clock. Tests duplicate sleep/wake, cancellation, missing/changed devices, recovery deadlines, virtual-device restart, late permissions, stalled callbacks, and error/device-loss ordering. It uses a standalone assertion runner because Command Line Tools may not include XCTest.
- `Tests/Release`: isolated fake-network publication checks, certificate requirements, license inclusion, dependency notices, and first-release bootstrap rules. They do not publish live files.
- `test-hal-topology.sh`: optional real HAL topology test. Requires an installed SoundLane component and built-in Mac input/output devices. It creates/destroys private aggregates without starting I/O or capturing audio.

CLI commands in an existing built app:

```sh
"$HOME/Library/Developer/SoundLane/SoundLane.app/Contents/MacOS/SoundLane" --self-test
"$HOME/Library/Developer/SoundLane/SoundLane.app/Contents/MacOS/SoundLane" --list-devices
"/Applications/SoundLane.app/Contents/MacOS/SoundLane" --status
```

`--status` queries an already running installed app. A CLI process that directly checks permission can inherit a development tool's access, so permission continuity must be observed in the running app's own context. Live audio, sleep and Zoom checks require the user's selected devices and permissions; see [validation](validation.md).
