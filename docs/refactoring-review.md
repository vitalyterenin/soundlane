# SoundLane refactoring audit

Reviewed on 9 November 2026 against `33b4bc3a83e24323b4160ec0dd3eef8910fccea1` (0.3.1, build 5). This was an audit: implementation and permanent tests were left unchanged. Tracked files were clean at the start. Existing untracked files under `Vendor/libASPL` were retained. Runtime control, persistence, audio callbacks and build entry points were traced in detail. The vendored driver was sampled at the handler boundaries; release tooling and prior live-update evidence were reviewed without publishing or installing anything.

SoundLane has two independently controlled Audio Unit chains. A private Core Audio tap supplies system audio to a physical output; a physical microphone feeds a private aggregate whose output reaches a fixed 48 kHz stereo HAL device. SwiftUI and `AppModel` own control state and configuration; the Objective-C++ bridge owns realtime I/O and AU graphs. The HAL driver transports samples between the app and clients such as Zoom using a time-tagged ring. [Architecture](architecture.md) describes these boundaries, [development](development.md) covers the local CLI and tests, and [release operations](releases.md) covers GitHub distribution and Sparkle. Preserve the English UI, the two independent routes, explicit device choice, existing JSON and AU records, virtual microphone identity, app signing identity, and updater URLs.

## Findings and proposed stages

### 1. Protect settings that failed to load

**Fixed in 0.3.2.** In 0.3.1, a decode error left default lanes in memory and allowed the next checkpoint to replace the original file. A temporary fixture with an unsupported JSON shape was overwritten with empty chains on normal shutdown.

The model distinguishes a missing file from a failed read or decode. A failure pauses saving for the session and shows a warning. The regression test checks the original bytes at a save checkpoint and at shutdown with malformed and unsupported JSON. A second test verifies saving on first launch and restoring settings across relaunches. See [`AppModel.save()`](../Sources/SoundLane/Models.swift#L371).

### 2. Make the driver build's input set deterministic

**High confidence; reproduced in the working checkout.** [`build-driver.py`](../scripts/build-driver.py#L18) compiles every `*.cpp` under the vendored source directory. Existing untracked copies named `… 2.cpp` produced 259 duplicate symbols at link time. The same revision built successfully from a clean archive. The cache also keys reuse on source/header timestamps, without an explicit compiler, SDK, or flags fingerprint; stale cache reuse after toolchain changes was not reproduced.

Declare the translation units for the pinned vendor revision, or have one build manifest own them. Prefer the smallest manifest that supports both a checkout and an exported source tree. Decide whether to retain object caching based on measured local build cost; if retained, include toolchain and flag identity. **Small change, low runtime risk.** Require a clean archive build and a build with a stray copy in a temporary checkout. Leave existing untracked files alone.

### 3. Keep controls responsive while a route starts or stops

**High impact; main-thread blocking observed previously.** [`AppModel.start`](../Sources/SoundLane/Models.swift#L271) calls synchronous bridge setup on the main actor; [`SLPipeline`](../Sources/AudioBridge/AudioBridge.mm#L321) calls into HAL before returning. A retained 0.3.0 sample on macOS 27.2 showed `AudioDeviceCreateIOProcID` blocking the main thread during the legacy permission migration. Re-adding the signed app resolved that incident. The same synchronous calls remain in 0.3.1; the incident does not establish how often HAL can stall with a valid grant. [`stop`](../Sources/AudioBridge/AudioBridge.mm#L325) also discards HAL teardown statuses before clearing the render context. Resource ownership after a failed teardown needs a targeted fault test; no use-after-free was observed.

First make requested state, in-flight operations, running state and cancellation explicit. Route expiry and the callback watchdog use wall-clock `Date` ([recovery](../Sources/SoundLane/Models.swift#L204), [watchdog](../Sources/SoundLane/Models.swift#L247)); a simulated forward wall-clock adjustment ended recovery early. Use an injectable monotonic clock. Then prototype a serial owner for blocking HAL calls, keeping AppKit editor work on the main actor and the two lanes independently controllable. Retain resources until callbacks are detached and discard or clean up late completions by generation. A timeout can bound the UI's wait; it cannot be assumed to cancel a blocked Core Audio call.

**Medium to large change, higher regression risk.** Compare a narrow HAL ownership change with retaining synchronous setup; a whole audio-engine rewrite would add risk without addressing the observed call boundary. Keep audio callback and driver protocols unchanged at first. Acceptance: an injected stalled operation leaves the UI responsive; disable, sleep and quit cannot revive a canceled route; partial setup or teardown failure retains safe ownership; real permission, sleep and hardware reconnection tests preserve both lanes and never switch microphones implicitly.

### 4. Measure before tuning audio or removing dependencies

**Deferred; hypotheses only.** Device enumeration and two component plist reads occur on the main actor every 1.5 seconds. Checkpoint saves serialize both chains, including vendor AU state, every 30 seconds even when there is no known edit. Measure idle versus two active chains with representative plug-ins: UI stalls, configuration bytes/writes, callback interval/errors, and CPU. A dirty flag needs to account for edits made inside third-party AU windows; keep periodic checkpointing until capture of those changes is proven. The bridge also computes `inputPeak` per sample without a current app consumer; verify that it is not a needed diagnostic before removing it, and measure the change. No speedup is claimed.

Retain libASPL and Sparkle: they implement the virtual device and signed updater, respectively, with proven live behavior. Retain the validated normal aggregate and output clearing. The current routing check relies on channel counts, stream order and packed float samples ([bridge](../Sources/AudioBridge/AudioBridge.mm#L311)); actual input/output layout across USB and Bluetooth is still unverified. Validate layouts with representative hardware before generalizing the mapper or optimizing its callback loops.

## Verification at the audited revision

| Check | Result |
| --- | --- |
| `bash scripts/test.sh` in the working checkout | Failed at driver link due to duplicate vendored translation units (finding 2). |
| `bash scripts/test.sh` from `git archive HEAD`, with an isolated `SOUNDLANE_OUTPUT_DIR` | Passed: driver/ring ASan/UBSan checks, manual realtime AU EQ, bypass, mute and callback mapping. |
| `bash scripts/test-stability.sh` | 12 scenarios passed with fake device and pipeline dependencies. |
| `python3 -m unittest discover -s Tests/Release` | 36 tests passed; no live publication. |
| `bash scripts/test-hal-topology.sh` | Passed on the installed HAL: three input channels and two/four output channels; no I/O or audio capture. |
| `bash scripts/build-app.sh` and built app `--self-test` | Passed in isolation on Apple Silicon, macOS 27.2, Swift 6.4.2 CLT. Local ad hoc build only; the compiler emitted AU API deprecation warnings. |
| Temporary probes using production `AppModel` | Confirmed config overwrite after failed decode and early recovery expiry with a simulated clock jump (findings 1 and 3). Synthetic settings and clock only. |

Probes were kept outside the repository. Reproduce finding 1 by constructing the production model with a temporary settings URL and fake pipelines, waiting for `restoring` to clear on invalid JSON, calling `shutdown()`, and comparing the source bytes. Reproduce the timing case by starting both fake routes, disconnecting the selected microphone, jumping the injected `Date` forward and refreshing devices without waiting 20 seconds. Live permission continuity and Zoom observations are recorded in [validation](validation.md) and [release verification](https://github.com/vitalyterenin/soundlane/pull/2); they were not repeated for this audit. Deep sleep, physical hotplug, broad third-party AU coverage, and performance measurements remain pending.
