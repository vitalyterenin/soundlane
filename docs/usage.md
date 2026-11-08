# Using SoundLane

## Routing

System Audio processes a private stereo tap of other apps and sends it to the selected stereo output. SoundLane excludes its own output from capture. Microphone processes the first channel of the selected physical microphone, duplicates it to stereo, and sends it to SoundLane Microphone at 48 kHz.

The virtual device is an input for calling apps. Its internal output exists to receive processed samples; do not choose it as the speakers in Zoom or another app. SoundLane never changes your system default device.

A changed, disconnected, or restarted device stops its affected route. SoundLane waits up to 20 seconds for that same selected device and retries. It does not substitute a different microphone. You can cancel recovery with the processing switch. After the deadline, reconnect and enable the chain again. Sleep stops audio I/O; wake restores only previously requested chains. A fresh app launch starts both off.

## Effects and levels

SoundLane hosts stereo Audio Unit effects, including compatible AUv2 and AUv3 effects. Instruments, MIDI and arbitrary multichannel routing are not supported. Some mono-only effects cannot join a stereo chain. A native effect editor is used when supplied; otherwise a parameter form is shown. Missing plug-ins retain their saved settings and are skipped with a message.

Adding, removing, or reordering effects rebuilds only that chain, with a brief audio pause. Plug-ins can add their own lookahead/processing delay. Bypass may change latency; it is not latency compensated. Some AUv2 plug-ins load inside SoundLane, so a faulty third-party plug-in can still crash the app.

Gain ranges from −24 to +6 dB. The reset button returns it to 0 dB. Mute and gain changes are smoothed. The final output clamps to full scale and replaces non-finite samples with silence; this protection is not a musical limiter. SoundLane has no echo canceller. Use headphones or the calling app's echo cancellation with speakers.

## Installation and permissions

Drag the app from the DMG into Applications. The virtual microphone component is a separate one-time privileged installation, included inside the app and started with **Set Up…**. Restart after component installation; SoundLane does not kill or restart coreaudiod during a call. When a compatible component is already installed, app updates do not reinstall it.

Microphone access is requested when enabling Microphone; system audio access is requested when enabling System Audio. If denied, allow SoundLane under **System Settings → Privacy & Security** and try again. No TCC database modification or trusted-root installation is part of setup.

Versions 0.2 and earlier were local development builds with ad hoc signatures and PKG-based app installation. Moving to the release certificate can require one permission regrant. Replace the old copy once, preserving the same bundle ID. An app that remains owned by root can require authorization for replacement; a normal user-owned drag installation avoids that cause of repeated update prompts. Signed app updates retain the pinned identity; see the tested scope in [validation](validation.md).

During this one-time signature migration, an old enabled system-audio permission can still refer to the development identity. On macOS 27.2 this blocked the first System Audio start. If that occurs, use **Force Quit** for SoundLane, then add the new installed app under **Privacy & Security → Screen & System Audio Recording → System Audio Recording Only → +** and relaunch it. macOS can request administrator authorization for that settings change. Do not reinstall the HAL component to repair an app privacy grant.

## Saved settings and removal

Configuration is local JSON at `~/Library/Application Support/SoundLane/Configuration.json`. It stores selected device UIDs, effect identifiers/order/fullState, effect bypass, and gain. It does not persist chain on/off, Mute, or Bypass All across a fresh launch. Updates use Sparkle preferences stored by macOS; Settings changes are respected.

To remove SoundLane, quit it and move its installed app to Trash. To remove the virtual device too, delete only `/Library/Audio/Plug-Ins/HAL/SoundLane.driver` with administrator authorization, then restart. Optional preferences are in SoundLane's Application Support folder and its `in.teren.SoundLane` preference domain. Do not remove other audio drivers.
