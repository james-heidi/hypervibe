# Fix dictation wave feedback latency

## Why

Holding the Siri button captures audio from the first syllable — the transcript proves it — but the desktop wave HUD stays in its breathing baseline for a noticeable beat and then jumps into motion. The user reads that stall as "dictation hasn't started yet", which is the one thing push-to-talk feedback exists to answer. The delay is not audio latency; it is the HUD's level path being gated behind a 100 ms file poll, PacketLogger's stdout block buffering, and a 30 Hz level throttle that discards most of each burst.

## What Changes

- **Measure before tuning.** Add press-scoped timing to `/tmp/hypervibe.log`: HUD reveal, first nhdr byte read, first decoded frame, first level publish. Attribution decides which of the levers below actually ship.
- **Faster capture reads.** Drop `MicCapturePipeline`'s privileged tail poll from 100 ms to ~20 ms so decoded frames stop arriving in 100 ms clumps.
- **Unbuffer PacketLogger.** The helper points PacketLogger's stdout at a plain file, so libc block-buffers nhdr lines (~4 KB ≈ hundreds of ms of voice). Give it a pty or an equivalent line-flushed sink so frames reach disk as they are produced.
- **Publish burst peak, not one sampled frame.** Replace the 30 Hz throttle-and-drop with a peak held across the throttle window, so a burst of five Opus frames reports its loudest energy instead of whichever frame won the timer.
- **Arm reactivity at press, not at first frame.** The wave becomes reactive on Siri-down; level 0 renders identically to the breathing baseline, so nothing changes visually except that the first level has no state transition to wait for.
- **Retune the amplitude envelope.** Fast attack, slower release so bars do not collapse ~46 % between bursts.
- **Keep breathing alive across main-thread stalls** (only if measurement shows one): the 60 Hz `Timer` shares the main runloop with the synchronous IOHID rearm on the press path.

Not in scope: synthesizing fake amplitude before real audio arrives, and any change to what audio reaches the ASR engine.

## Capabilities

### New Capabilities

- `dictation-visual-feedback`: When and how the global dictation HUD reflects capture state and voice amplitude — reveal timing, reactivity arming, level freshness, and animation continuity under main-thread load.

### Modified Capabilities

None. Audio capture, decode, and typing behaviour are unchanged; `dictation-responsiveness` requirements still hold as written.

## Impact

- `MicCapturePipeline.swift` — tail poll interval, first-read timing log.
- `HCIHelperServer.swift` — PacketLogger stdout sink (privileged helper; needs helper rebuild + reinstall to take effect).
- `RemoteMicController.swift` — level computation/publish policy, press-time reactivity, timing logs.
- `MenuBarManager.swift` — `AudioWaveformView` envelope, `MicReadinessHUD` reactive arming.
- Risk surface: the helper path is privileged and hard to roll back mid-session; the press path carries the stuck-key and HID-rearm invariants in AGENTS.md. Verification is manual with a paired A2854 remote.
