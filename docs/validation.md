# Validation scope

## Development checks, 8 November 2026

Local environment: Apple Silicon MacBook Pro, macOS 27.2, Swift 6.4.2 Command Line Tools. The declared minimum is macOS 14.2; the current hardware observations do not establish behavior on every supported OS/device.

C++ checks with ASan/UBSan cover format, roundtrip, independent readers, wraparound, stale data, concurrent access, finite values, and silence after stop/restart. The real AVAudioEngine manual realtime path is checked with a −6 dB EQ, bypass, mute, and synthetic duplex channel mapping. Real HAL topology tests validate separate outputs and physical input availability.

Twelve lifecycle/component scenarios check the production AppModel with fake HAL/clock dependencies, including duplicate sleep/wake, cancellation, delayed return, changed IDs/formats, recovery timeout, missing virtual destination, late permission replies, stalled callbacks, and compatible component versions that must not request reinstallation. Publication checks use isolated fake GitHub/network clients and verify artifact identity, state monotonicity, bounded retries, cleanup ordering, signature requirements and notices.

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

The initial system-chain start blocked inside Core Audio while the settings pane still displayed an enabled legacy grant. Adding the new signed app through the system-audio privacy pane resolved the block; both chains then ran together at 48 kHz without restarting coreaudiod. This observation covers the one-time ad hoc identity migration, not update continuity. Applications replacement and a real Sparkle update remain separate checks.

Release validation includes the Actions build/publish result and anonymous downloaded DMG/feed verification. The initial permanent-identity migration and subsequent real Sparkle update are separate checks: query `--status` in the installed running app, grant permissions once for the permanent identity, update to a different executable through Sparkle, and verify the grant and live routes without regranting. Record observed results in the release work summary; do not infer continuity from direct CLI permission checks or certificate inspection alone.

## Remaining hardware coverage

- Physical USB/Bluetooth disconnection and reconnection, and long/deep sleep.
- Long remote calls, feedback/echo behavior with speakers, and measured end-to-end latency/load.
- Individual third-party AU compatibility and behavior across the supported macOS range.

Full isolation from third-party AUv2 crashes and built-in echo cancellation are not implemented. See [usage](usage.md).
