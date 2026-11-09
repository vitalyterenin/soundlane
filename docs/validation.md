# Validation scope

## Development checks

Local environment: Apple Silicon MacBook Pro, macOS 27.2, Swift 6.4.2 Command Line Tools. The declared minimum is macOS 14.2; the current hardware observations do not establish behavior on every supported OS/device.

C++ checks with ASan/UBSan cover format, roundtrip, independent readers, wraparound, stale data, concurrent access, finite values, and silence after stop/restart. The real AVAudioEngine manual realtime path is checked with a −6 dB EQ, bypass, mute, and synthetic duplex channel mapping. Real HAL topology tests validate separate outputs and physical input availability.

Fourteen lifecycle, component, and settings scenarios check the production AppModel with fake HAL/clock dependencies. Coverage includes sleep and wake, cancellation, delayed return, changed IDs and formats, recovery timeout, missing virtual destination, late permission replies, stalled callbacks, and component compatibility. Settings tests use temporary files to verify byte-for-byte preservation after a failed decode and normal saving on first launch and after a successful restore. Publication checks use isolated fake GitHub/network clients and verify artifact identity, state monotonicity, bounded retries, cleanup ordering, signature requirements and notices.

## Hardware observations before first public release

Development builds 0.1–0.2 were installed locally with ad hoc signatures:

- Both routes ran together at 48 kHz. Zoom 7.2.5 selected SoundLane Microphone; the user recorded and heard their voice with **Test microphone**. No remote call was conducted.
- An independent Core Audio client received the virtual microphone stream. SoundLane Mute produced exactly zero peak for three consecutive seconds; unmuting restored signal. The meter stored numeric levels only, not audio recordings.
- A short system sleep/wake cycle stopped/destroyed and recreated both aggregates in the same process. Both chains resumed, including an active Waves RVox (s). System audio passed Zoom's speaker test afterwards.
- Switching the available Continuity microphone from Mac to iPhone and back preserved virtual output and left the system route active. The final input was restored to the built-in Mac microphone.
- Native UI checks covered both destinations, effect search/selection/cancel, editors and returning focus. User effect order/state and per-effect bypass survived app replacement.

These are observations of local development builds, not a claim that all plug-ins, long sessions, Bluetooth/USB hotplug or deep sleep are validated.

## Release and permission-continuity checks

The public 0.3.0/build 4 DMG and feed passed anonymous download, signature, metadata, architecture and complete license-notice verification. The verified app was launched from a user-writable test location on macOS 27.2. Its own status reported microphone access, both routes processing, increasing callback counters and a compatible HAL requiring no setup. The microphone meter showed signal; Zoom's speaker test produced system-chain output. Saved Apple/Waves effects were preserved.

The initial system-chain start blocked inside Core Audio while the settings pane still displayed an enabled legacy grant. Adding the new signed app through the system-audio privacy pane resolved the block. Both chains then ran together at 48 kHz.

On macOS 27.2, Sparkle installed 0.3.1/build 5 over the user-owned copy of 0.3.0/build 4 in Applications. The running app retained microphone access and both routes processed audio after relaunch. No repeat privacy or administrator prompt appeared. The compatible HAL stayed installed and Zoom retained the virtual microphone selection. The [0.3.1 verification record](https://github.com/vitalyterenin/soundlane/pull/2) documents that specific update.

Routine release validation checks the Actions result and anonymously downloaded DMG and feed. A live permission continuity check also verifies the running app's own permission and audio state after Sparkle replaces the executable. Inspecting the certificate alone cannot establish permission continuity.

## Remaining hardware coverage

- Physical USB/Bluetooth disconnection and reconnection, and long/deep sleep.
- Long remote calls, feedback/echo behavior with speakers, and measured end-to-end latency/load.
- Individual third-party AU compatibility and behavior across the supported macOS range.

Full isolation from third-party AUv2 crashes and built-in echo cancellation are not implemented. See [usage](usage.md).
