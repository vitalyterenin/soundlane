# SoundLane maintenance

Write interface text, code comments, docs, commits and GitHub content in English.
Preserve bundle ID `in.teren.SoundLane`, virtual device UID, pinned release certificate,
and Sparkle identity. SoundLane's original code is proprietary; all rights are reserved
by the owner. Do not replace LICENSE with an open-source license. Preserve complete
libASPL, Apple and Sparkle notices in app, driver and DMG.

Use the refreshed app-release skill and [release operations](docs/releases.md).
Build distributions only in GitHub Actions and publish only through this repo's
Releases and Pages. Do not publish local builds, move tags or weaken signing gates.
Review all maintained documentation before every tag. Keep caches outside Documents.

The app is installed from a DMG. Ordinary updates replace only the app. A PKG is
allowed only for the separately versioned system HAL component, with explicit user
installation and a restart. Do not restart coreaudiod or silently reinstall a driver.
Do not overwrite an installed persistent-identity app with an ad hoc build.

Read [architecture](docs/architecture.md) before changing routing. Keep callbacks
free of Swift, allocation, blocking synchronization, logging and file I/O. Use normal
aggregates (stacked=0), clear all outputs and write only destination channels. Keep
taps private, exclude this process and use mutedWhenTapped. Never silently substitute
a disconnected microphone. Verify real HAL topology as well as synthetic callbacks.

Keep the native English sidebar/form UI focused on System Audio and Microphone.
Preserve independent chain state and existing user AU settings. Do not claim Zoom,
permission continuity or hardware tests passed from offline tests alone.

Checks: scripts/test.sh, scripts/test-stability.sh, and Python Tests/Release.
The optional scripts/test-hal-topology.sh requires installed HAL and built-in Mac I/O.
