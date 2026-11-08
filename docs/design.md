# Native macOS interface

The main window uses NavigationSplitView with a system sidebar. System Audio and
Microphone are separate destinations. Both statuses remain visible in the sidebar;
changing the selection does not affect audio processing.

The detail pane is a grouped SwiftUI Form: processing switch, routing, ordered Audio
Unit effects, and output controls. Device selection uses Picker; effect enablement,
Bypass All, and Mute use native checkboxes. Each effect offers its editor and a menu
for reordering or removal. Gain includes an explicit reset to 0 dB.

The Audio Unit picker is a native searchable List with selection, Cancel, and a
default Add Effect action. Escape cancels and Return adds the selected effect.

Use semantic system colors, system fonts and native toolbar/sidebar surfaces. The
window follows system appearance and accent color. No custom glass, gradients,
fixed light backgrounds, or marketing header are used in the window. The level
meter remains custom because it displays a logarithmic audio signal.

All app-owned interface text is English: main window, picker, fallback parameter
editor, menu bar, accessibility labels, errors, and privacy usage descriptions.
The bundle declares English as its development and supported language. External
Audio Unit editors retain the UI supplied by their manufacturers.

References: [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
and [Apple Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars).

Validation: restored the existing Apple/Waves chains; enabled both chains; switched
sidebar destinations while processing continued; searched and selected an Audio
Unit and cancelled the sheet; opened and closed the native Dynamics Processor
editor. Existing 11 lifecycle scenarios and DSP smoke test pass.

Software update controls use a native Settings form and standard Sparkle windows.
The virtual microphone setup appears only when the component is missing or outdated;
an installed compatible component waiting to load shows restart instructions.

Screenshot: [Microphone](SoundLane-0.2-Microphone.png). This image demonstrates the
main audio controls; update settings are described in [usage](usage.md).
