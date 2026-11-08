# Privacy

SoundLane processes microphone and system audio locally. It does not record audio to disk or upload audio. It does not collect analytics, advertising identifiers, crash reports, or telemetry.

macOS controls microphone and system audio permission. SoundLane requests access only when the corresponding chain is enabled. The virtual microphone exposes processed samples to apps the user selects; choose that device only in apps intended to receive your voice.

Configuration is saved locally as described in [usage](usage.md#saved-settings-and-removal). Third-party Audio Units run their vendors' code and can have their own licensing, networking and data policies. They are not included with SoundLane.

Sparkle contacts the app's signed feed at `https://vitalyterenin.github.io/soundlane/appcast.xml` and downloads updates from GitHub Releases. GitHub receives the ordinary connection metadata needed to serve those requests. System profiling and delta archives are disabled. Automatic checks and installation can be disabled in **SoundLane → Settings…**; manual checks remain available.

The `--status` developer command makes a read-only local notification request to the running app. It reports its version, permission state, component versions and numeric audio callback counters. It does not record audio, start processing or contact a server.
