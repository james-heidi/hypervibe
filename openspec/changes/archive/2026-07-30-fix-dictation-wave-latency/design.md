## Context

See proposal.md — Why. What matters for the approach is the shape of today's amplitude path from microphone to bars:

```
A2854 mic → BT/HCI → PacketLogger `convert -s -f nhdr` (stdout = plain file)   HCIHelperServer.swift:295-301
          → helper session file /var/tmp/.../capture.nhdr
          → MicCapturePipeline tail poll, every 100 ms                          MicCapturePipeline.swift:271-277
          → line split → A2854 payload → onPayload                              MicCapturePipeline.swift:399-452
          → RemoteMicController.handlePayload on `queue`: Opus decode            RemoteMicController.swift:631-668
          → first frame publishes `.listening`                                   RemoteMicController.swift:645
          → level published at most 30 Hz, RMS of every 8th sample of
            whichever frame won the throttle                                     RemoteMicController.swift:647-661
          → main hop → MicReadinessHUD.updateAudioLevel                          MenuBarManager.swift:1349-1357
          → AudioWaveformView: reactive only in `.listening`;
            60 Hz main-runloop Timer; attack lerp 0.34, target decay 0.88/tick    MenuBarManager.swift:166-216, 1324-1327
```

Four independent delays stack in there, each of a different nature:

1. **Block buffering in a process we don't own.** PacketLogger's stdout is a regular file, so libc uses full buffering. nhdr ACL lines are long; voice runs roughly 10 KB/s of text, so a 4 KB block boundary is ~400 ms of speech held in PacketLogger's buffer. This is invisible to any amount of polling on our side.
2. **Poll granularity.** Even unbuffered, the 100 ms tail poll clumps frames.
3. **Throttle-and-drop.** One level per 33 ms window, taken from a single frame; when frames arrive in clumps the rest of the energy is discarded, so onset can be represented by a quiet frame.
4. **Envelope + reactivity gate.** `targetLevel *= 0.88` per tick loses ~46 % over 100 ms, so clumped updates read as stutter; and `reactive` only turns on when `.listening` is published from the first decoded frame.

Constraints: the helper is privileged and separately installed (rebuild + reinstall to take effect); the press path carries the AGENTS.md invariants (synchronous `activator.rearmOnSiriDown()` must stay on the press callback, HUD frame committed before it, stuck-key safety); there are no tests, so every claim here has to be readable off `/tmp/hypervibe.log` with a paired remote.

## Goals / Non-Goals

**Goals:**
- Attribute the observed stall to specific stages with logged timestamps before changing behaviour, so we don't tune the wrong knob.
- Amplitude freshness bounded by transport, not by our polling/buffering/update-rate policy.
- Envelope and reactivity arming that make the arrival of real audio the only thing the eye waits for.

**Non-Goals:**
- Faking amplitude before real audio (a lying indicator is worse than a late one).
- Reworking the HCI capture architecture, the decode path, or anything that changes what audio reaches the ASR engine.
- Sub-frame precision. Opus frames are 20 ms; anything below that is invisible.

## Decisions

### D1: Measure first, in one instrumented build

Add press-scoped `rmDebug` timestamps at four points — HUD reveal, first non-empty tail read after press, first decoded frame (already logged as "first frame latency"), first published level — then hold the button and speak immediately, three times warm and once cold.

The measurement decides which levers ship: gaps concentrated before "first tail read" indict PacketLogger buffering (D2); a ~100 ms quantum in read arrivals indicts the poll (D3); a gap between first decoded frame and visible motion indicts the UI envelope (D5/D6).

Rationale: three of the four suspected causes are in different processes and two require a privileged helper reinstall to test. Guessing costs a helper reinstall cycle per guess. Alternative — ship all levers blind — was rejected: it makes the helper change unfalsifiable and hides which one mattered.

### D2: Give PacketLogger a pty instead of a file, only if measurement indicts it

If the log shows first-byte arrival lagging speech onset by much more than the poll interval, replace the helper's `FileHandle(forWritingTo:)` stdout with a pty master/slave pair (`posix_openpt`/`grantpt`/`unlockpt`), hand the slave to the process, and have the helper pump the master into the session file. libc line-buffers when stdout is a terminal, so lines land as produced.

Alternatives considered: `stdbuf -o0` (GNU coreutils, not present on stock macOS, and DYLD injection is blocked for a signed binary); a `Pipe()` (does not change PacketLogger's own buffering — it stays fully buffered because a pipe is not a tty); asking PacketLogger for a flush flag (no documented option). The pty costs a pump loop in the helper and one more fd; it is the only mechanism that changes the child's buffering decision without changing the child.

### D3: Tail poll 100 ms → 20 ms

One constant (`MicCapturePipeline.swift:272`). Each tick opens the file, seeks to the saved offset, reads to end — at 50 Hz on a file that grows ~10 KB/s this is negligible, and the existing rotation guard still applies. Alternative — a `DispatchSource` vnode watch — is more code for the same result and fires unreliably for appends by another process, so it stays on the shelf unless 20 ms proves insufficient.

### D4: Publish a held peak instead of a sampled frame

Keep the 30 Hz publish cadence (that is a display-rate concern, not a data concern) but accumulate `max` of per-frame RMS across the throttle window and publish that, then reset. Also compute RMS over every 4th sample rather than every 8th — the decode already touched the whole buffer, so the extra arithmetic is free relative to the Opus decode.

Alternative — publish on every frame (50 Hz) — was rejected: it doubles main-thread hops to beat a 60 Hz display, and the peak-hold gives the same visual truth for one variable.

### D5: Arm `reactive` at press, not at `.listening`

`showWaveform(reactive: true)` for `.readyToSpeak` (`MenuBarManager.swift:1324`). Safe because the view already renders breath + `displayedLevel * …` with `displayedLevel == 0` identical to the non-reactive pose — the comment at `MenuBarManager.swift:231-233` documents exactly that property. This removes one state hop from the visual path and leaves `.listening` meaningful only for the status-item chrome and the menu label.

### D6: Asymmetric envelope

Attack lerp 0.34 → ~0.5, and target decay 0.88 → ~0.94 per tick (≈70 % retained over 100 ms instead of ≈46 %). Fast attack, slow release is the standard meter envelope; it makes clumped updates read as sustained loudness rather than stutter. Values are display tuning, expected to need one round of eyeball adjustment on real speech — keep them named constants, not inline literals.

### D8: Measured — the stall is the activator, so serialize it instead of rewriting the view

Measurement (2026-07-30, warm press, speech at press instant):

```
🎤 timing hud-reveal          +0.000s
🎤 timing first-capture-read  +0.014s bytes=924
🎤 utterance first frame       0.054s cold=no
🎤 timing first-level         +0.055s level=1.00
🎤 MicActivator enable replay targets=20 in 1207ms
🎤 MicActivator rearm total   1208ms
🌊 wave tick gap 1.264s (main runloop stalled)
```

Attribution: **D2 is cleared** — the first capture bytes land 14 ms after press, so PacketLogger is not block-buffering and the helper needs no pty. Amplitude data is ready at 55 ms. The entire visible stall is one thing: `activator.rearmOnSiriDown()` on the press callback replays 20 `IOHIDDeviceSetReport` round trips at ~60 ms each and holds the main runloop for 1.2 s.

`provenTargets` does not prune anything here: 4 remote HID interfaces × 5 report IDs all return `kIOReturnSuccess` from `kIOHIDReportTypeFeature`, so "proven" keeps all 20 and only one of them plausibly reaches the microphone.

Fix: give `MicActivator` its own serial queue and hop every public entry point onto it, so the press callback returns immediately and the arm still happens. This supersedes D7 (see below) — the wave does not need render-server animation once the main thread is free, and the fix also removes 1.2 s of latency from typing, the menu, and every other main-thread consumer during a press.

Why this is safe where the earlier deferral was not: the failure recorded at `RemoteMicController.swift:459-464` was the `pressGeneration == armID` guard dropping a queued arm when a fast release bumped the generation first — not the hop itself. Serializing inside the activator carries no generation guard, and because release's `disarm()` goes through the same serial queue, enable-then-disable ordering is preserved and the microphone cannot be left armed after release. Teardown paths (`shutdown`) use a blocking variant so the app cannot exit before `PushToTalk(false)` lands.

Alternatives considered: pruning the 20 targets to the one that actually arms the mic (the right end state — 1.2 s of SetReport traffic per press is also what the "SetReport storms cut the stream after ~1 s" comment warns about — but it changes mic-arming behaviour on the fragile path, so it needs its own verification round and does not belong in a latency fix); issuing the 20 writes concurrently (same storm risk, and the transport likely serializes them anyway).

### D7 (superseded by D8): Main-thread stall mitigation stays conditional

If D1 shows the animation frozen at press (a tick gap > 100 ms in the timer), the fix is to drive the seven bars as `CAShapeLayer`s with a repeating `CABasicAnimation`, so the render server animates them while the main thread is inside the IOHID `SetReport`. That is a real rewrite of `AudioWaveformView.draw`, so it does not ship on suspicion. Moving the rearm off-main is explicitly not an option: the comment at `RemoteMicController.swift:459-464` records that deferring it let a fast release bump `pressGeneration` first and captured no audio at all.

## Risks / Trade-offs

- **Helper pty pump introduces a new failure mode in privileged code** (dropped output, pump thread wedged, fd leak on session teardown) → keep the file-sink code path intact and selectable, verify a full session start/stop/rotate cycle, and confirm `capture.nhdr` still contains complete lines after teardown.
- **PacketLogger might not use stdio buffering at all**, making D2 wasted work → D1 gates it; if first-byte arrival already tracks the poll interval, D2 is dropped.
- **20 ms poll raises syscall rate ~5×** → measured against a file that only grows ~10 KB/s; the rotation guard at `MicCapturePipeline.swift:359-378` already bounds file size.
- **Faster/heavier level path runs on the decode queue** (`RemoteMicController.queue`), which also feeds the ASR engine → peak-hold is O(n) over samples already in cache; if the log shows added frame-to-engine latency, back off the RMS stride rather than the cadence.
- **Envelope retuning can overshoot** into a wave that looks loud during silence → the silence scenario in the spec is the acceptance check; verify a full hold with no speech still shows the breathing baseline.
- **Ad-hoc signing means rebuilds can drop TCC grants** → expect to re-approve Accessibility/Input Monitoring, and re-install the helper, between measurement and verification builds.
