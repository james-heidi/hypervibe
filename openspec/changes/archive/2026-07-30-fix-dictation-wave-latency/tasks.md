## 1. Instrument and attribute (design D1)

- [x] 1.1 Add press-scoped timing logs: HUD reveal instant in `MicReadinessHUD.revealNow`, first non-empty tail read after press in `MicCapturePipeline.readPrivilegedOutput` (with chunk byte count), first published level in `RemoteMicController.handlePayload` — all relative to `utteranceBeganAt`, alongside the existing "first frame latency" line.
- [x] 1.2 Log the wave timer tick interval when it exceeds 100 ms, so a main-thread stall during press is visible in `/tmp/hypervibe.log`.
- [x] 1.3 Build, install, and capture 3 warm presses + 1 cold press with speech starting at the instant of press; paste the log lines into the change as the measured baseline.
      Deviation from D1: groups 2 and 3 are app-side, cheap, and need no helper reinstall, so they ship in the same build as the instrumentation — one manual measurement round instead of two. The logged stages still attribute any residual delay, which is what gates groups 4 and 5.
- [x] 1.4 Attribute the stall: mark which of D2 (helper buffering), D3 (poll), D4 (throttle), D6 (envelope), D7 (main stall) the numbers actually indict, and drop the tasks below that the measurement clears.

## 2. Amplitude freshness in the app (design D3, D4)

- [x] 2.1 Drop the privileged tail poll from 100 ms to 20 ms in `MicCapturePipeline` (both the initial deadline and the repeat); confirm the rotation guard and offset bookkeeping still behave over a multi-minute warm session.
- [x] 2.2 Replace the 30 Hz throttle-and-drop level publish with a peak held across the publish window (`max` of per-frame RMS, reset on publish) and tighten the RMS stride from every 8th to every 4th sample.
- [x] 2.3 Verify from the log that first-level latency dropped and that per-frame decode-to-engine timing did not regress.

## 3. HUD reactivity and envelope (design D5, D6)

- [x] 3.1 Arm the wave for voice from press. Implemented by deleting the `reactive` flag from `AudioWaveformView` outright rather than passing `true`: the amplitude term vanishes at level 0, so the flag only ever delayed metering. `showWaveform()` now takes no argument and `.readyToSpeak`/`.listening` share one HUD visual.
- [x] 3.2 Hoist the envelope constants (attack lerp, target decay) out of `AudioWaveformView.tick` into named static constants, then set attack ≈0.5 and decay ≈0.94.
- [x] 3.3 Eyeball-tune on real speech: bars must stay elevated through continuous speech without stutter, and a full silent hold must still show only the breathing baseline.

## 4. Helper output buffering — DROPPED (design D8)

Cleared by measurement: first capture bytes land +0.014 s after press, so PacketLogger is not block-buffering and the helper needs no pty. Tasks 4.1–4.4 are not implemented.

## 5. Unblock the main thread during press (design D8, supersedes D7)

- [x] 5.1 Give `MicActivator` a private serial queue and hop every public entry point (`arm`, `rearmOnSiriDown`, `disarm`, `useSharedDevices`) onto it, so the press callback no longer waits out ~1.2 s of `IOHIDDeviceSetReport` round trips. All mutable state (`openDevices`, `provenTargets`, `ownsDevices`) is touched only on that queue.
- [x] 5.2 Add a blocking teardown variant and use it from `shutdown()` so the app cannot exit before `PushToTalk(false)` lands; leave the per-utterance disarm asynchronous.
- [x] 5.3 Verify from the log that `wave tick gap` lines are gone, that `rearm total` still appears (now off-main) within a press, and that a fast press-release still captures audio and produces a transcript.
- [x] 5.4 Note in `AGENTS.md` that arm ordering is now guaranteed by the activator's serial queue rather than by running on the press callback, so the invariant is not "cleaned up" back into a main-thread call.
- [ ] 5.5 Follow-up, not this change: prune the 20 replayed SetReport targets to the one that actually arms the microphone (`provenTargets` keeps all 20 because every Feature write returns success). 1.2 s of per-press SetReport traffic is also what the "storms cut the stream after ~1 s" warning is about.

## 6. Verify against the spec

- [x] 6.1 Walked with a paired A2854, warm: reveal in the press callback (`hud-reveal +0.000s`), no freeze while held (zero `wave tick gap` lines across ~8 presses), reaction 42–46 ms after press, smooth motion under continuous speech, breathing baseline only during a silent hold — both confirmed visually by the user. **Not covered: a cold-capture press** (every measured press reported `coldStart=false`).
- [x] 6.2 Fast press-release still captures from the start (0.30–0.54 s holds gave `frames=166/186/213`, so the asynchronous arm drops no audio) and a normal hold transcribes from the first syllable (`text=Today I'm going to go to city…`, `typed raw transcript len=62`). **Not re-tested: stuck-key release on remote disconnect, 200 ms dual-path debounce, guarded polish correction** — untouched by this change but unverified this round.
- [x] 6.3 Measured (2026-07-30, warm, speech at press instant):

| Stage | Before | After |
|---|---|---|
| `wave tick gap` | 1.264 s | none |
| `hud-reveal` | +0.000 s | +0.000 s |
| `first-capture-read` | +0.014 s | +0.001–0.005 s |
| `first-level` | +0.055 s | +0.042–0.046 s |
| `rearm total` | 1208 ms (on main) | 613–641 ms (off main) |

The `rearm total` halving is a side effect of quitting a duplicate app instance from another worktree that was contending for the same HID interfaces; the latency fix is that the number no longer sits on the main thread at all.
