# Audio architecture

## Components

- `Sources/SoundLane`: native SwiftUI interface, independent chain state, AU discovery/editors, recovery, local configuration, Sparkle and read-only runtime status.
- `Sources/AudioBridge`: Objective-C++ Core Audio I/O callbacks and AVAudioEngine graphs. No Swift runs in audio callbacks.
- `Driver/Driver.cpp`: an Audio Server Plug-in using statically linked libASPL. SoundLane Microphone has UID `in.teren.soundlane.microphone`, stereo float32 at 48 kHz. Its input is available to calling apps; its output receives processed samples. It cannot be the system default output.
- `Common/TimelineBuffer.hpp`: one writer and independent readers, atomic stereo values and absolute sample-time tags. Missing/expired/overwritten frames are silence; restart invalidates prior data.

`SoundLaneApp` hosts the two SwiftUI routes and starts the updater and local status responder. `AppModel` owns route intent, device polling, sleep notifications, effect editors, and settings persistence on the main actor. Audio setup and teardown currently call the bridge synchronously from that actor. The realtime callbacks run separately and read the lane's atomic controls.

## System audio

A private global stereo process tap excludes SoundLane and uses `CATapMutedWhenTapped`. A private aggregate combines it with the selected physical output, which supplies the clock; the tap has drift correction. Stopping/terminating SoundLane releases the tap and returns normal playback. System default devices are not changed.

## Microphone

A normal aggregate (`stacked=0`) lists the virtual output first and physical microphone second. The virtual device supplies 48 kHz timing; the physical input uses drift correction. The first physical input channel is duplicated to stereo. The callback clears every output and writes only the first two destination channels, avoiding unrelated hardware output.

Real HAL tests on macOS 27.2 found that `stacked=1` provided no input channels. The topology regression checks 3 input / 2 output channels, and 3 input / 4 independent output channels when physical speakers are added.

## Rendering and recovery

Each chain owns an AVAudioEngine in manual realtime mode:

`preallocated stereo input → source node → AU effects → mixer → stereo output`

Buffers hold up to 8192 frames. Callbacks contain no Swift, allocations, blocking locks, file I/O or logging. The render block is cached. Third-party effects must also meet realtime constraints. Float32 formats are checked. Non-finite samples become silence; the output is clamped to [−1, 1]. Gain/mute are ramped over approximately 5 ms. Graph edits pause and rebuild only the affected chain.

User intent and actual running I/O are separate. A generation token cancels stale starts across manual off, device selection, sleep and shutdown. Duplicate power notifications are idempotent. Recovery waits up to 20 seconds for the same UID, including changed HAL IDs, formats and virtual destinations. It never substitutes another microphone. A lack of callbacks for over 3 seconds stops processing with an error. Silence with continuing callbacks is valid. Repeated consecutive AU failures stop the chain; isolated lifetime errors do not accumulate to that threshold.

The main actor polls devices and callback health every 1.5 seconds and samples active meters every 50 ms. It saves the two lanes to one atomic JSON file at window close, quit, and other checkpoints, including a 30-second timer. The file stores device UIDs, effect order, opaque AU state, bypass, and gain. An error reading or decoding the file disables all save checkpoints for the session. Route intent starts off on launch. See the [refactoring audit](refactoring-review.md) for known limits of route timing.

## Distribution

The app is drag-installed from a DMG and updated as an app bundle by Sparkle. The bundled HAL component has its own version and one-time PKG installer. A compatible installed component is left in place across app updates. An installed component that is not loaded requires a restart, not another installation.

Release app, driver and updater helpers are signed by the certificate pinned in Resources/ReleaseSigning.cer. Ed25519 update signing uses a separate key. Full project and dependency notices are embedded in both app and driver, as well as the DMG root. See [release operations](releases.md) and [privacy](privacy.md).
