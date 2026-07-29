# Design: stt-latency-fast-path

## Context

See proposal.md — Why. Key code today:
- `RemoteMicController.commitUtteranceLocked` (`RemoteMicController.swift:500`): decode completion → `polisher.polish` → `onTranscribedText` (serial; polish blocks typing). Second path in `stopSession` (`:628`).
- Drain: fixed `postReleaseDrain = 0.35` (`:36`), `coldStartGrace = 3.0` (`:39`), chosen at release time (`:464`).
- Typing: `MenuBarManager.typeDictationText` (`:1383`) posts CGEvents with UTF-16 payloads; `onTranscribedText` wired in `SiriRemoteApp.swift:156`.
- Parakeet decode: temp WAV write → `manager.transcribe(url:)` → delete. FluidAudio 0.15.5 also exposes `transcribe(_ buffer: AVAudioPCMBuffer, decoderState:)` which resamples internally (verified in 0.15.5 source).
- Corpus recorder (Phase 0) copies that temp WAV — its tap must survive the WAV's removal.

Constraints: AGENTS.md fragile invariants (stuck-key safety, dual delivery, no Enter from gestures). No new dependencies.

## Goals / Non-Goals

**Goals**
- Text on screen ≈ decode completion (raw), not polish completion.
- Capture ends when frames stop, not on a fixed timer.
- No behavior change for the OpenAI engine beyond typing order (shared controller path).

**Non-Goals**
- Streaming decode during hold (rejected by Phase 0 measurement, see proposal).
- Polish quality/prompt changes; `TranscriptPolisher` internals untouched.
- Correction across app/focus switches — we guard by dictation state, not by tracking the focused element.

## Decisions

**D1 — Typing order: raw immediately, correction as delete+retype.**
`commitUtteranceLocked` types raw via `onTranscribedText` right after decode, then launches polish. On a differing polish result: send N delete-backward key events (N = raw string's typed unit count, matching `typeDictationText`'s UTF-16-chunk semantics) followed by typing the polished string. Owned by `MenuBarManager` (new `replaceDictationText(oldLength:with:)`) so the typing and deleting share one CGEvent implementation. Alternatives: (a) keep blocking polish — rejected, it is the latency; (b) type only polished when it arrives fast (<300 ms race) — rejected, two timing regimes for little gain; (c) never correct — kept available via toggle (D3).

**D2 — Correction guards.**
Correction fires only if: same `pressGeneration` (no new hold started), dictation not cancelled, and correction enabled. `polisher.cancel()` on new press already exists (`RemoteMicController.swift:370`) — the generation check makes the race harmless even if a polish completion slips through. Recovery history records the final string (polished when correction fired, else raw).

**D3 — Correction toggle.**
UserDefaults `dictationCorrectionEnabled`, default **on**; sticky menu item next to the polish menu. Off = raw-only typing; polish result is discarded (mode `off` in the polish menu remains the way to skip polish work entirely).

**D4 — Adaptive drain via last-frame timestamp.**
Capture path stamps `lastVoiceFrameAt` on every decoded Opus frame. On release, instead of one fixed 0.35 s timer, schedule a short repeating check (50 ms) that commits when `now - lastVoiceFrameAt ≥ 120 ms`, with the old values as hard caps (0.35 s warm / cold grace unchanged). 120 ms > one HCI batch gap (frames are 20 ms; observed batching ≲ 60 ms) — tune constant during verification. Alternative: commit on A2854 end-of-stream sentinel — rejected for now, sentinel detection is adapter-specific and the timestamp approach covers all remotes.

**D5 — In-memory decode.**
Build a 48 kHz mono `AVAudioPCMBuffer` from the captured `[Int16]` (Float conversion), call `transcribe(buffer, decoderState:)`; FluidAudio resamples internally (same `audioConverter` the URL path uses, so parity is expected — verified against the corpus in tasks). Corpus tap changes from "copy temp WAV" to `CorpusRecorder` writing the WAV itself from the same boosted samples (it already does this for dropped clips). OpenAI engine keeps its WAV (it uploads a file anyway).

## Risks / Trade-offs

- [Correction deletes user-typed characters if the user types manually between raw and correction] → polish budgets bound the window (≤2.5 s); guards kill it on any new dictation; toggle exists; remote-driven workflow rarely mixes manual typing inside that window. Documented in the toggle tooltip.
- [Target app treats rapid backspaces oddly (autocomplete, IME)] → correction is plain delete-backward events, same source as typing; toggle off is the escape hatch.
- [120 ms quiet window clips a trailing soft syllable] → frames still count as "voice frames" while arriving; cap keeps worst case identical to today; tune with real remote before merging.
- [AVAudioPCMBuffer path resamples differently than WAV path] → same FluidAudio `audioConverter` under both; task verifies transcript parity on the recorded corpus via the Phase 0 harness.
- [Corpus WAV no longer byte-copied from the engine's temp file] → recorder writes from the identical boosted sample array; content equality holds.

## Migration Plan

Additive + behavioral. Ship with correction default-on. Rollback: toggle off restores raw-only; reverting the commit restores blocking polish. No data migration.

## Open Questions

- Final quiet-window constant (120 ms starting point) — settle during manual verification with the paired remote.
- Whether `stopSession`'s disconnect path should also type raw-first (yes in implementation, but worth confirming no HUD regression during review).

## Measured Results (2026-07-29, paired A2854)

- Adaptive drain: n=23, mean 0.183 s, range 0.154–0.258 s, all quiet-commits (was fixed 0.35 s) — ~170 ms saved per utterance.
- Release→typed: ~0.16–0.26 s for short clips (log second-resolution; longer clips ~1.2 s including decode) vs 1–3 s before (0.35 s drain + blocking polish).
- In-memory decode parity: 26/26 corpus WAVs identical transcripts app vs CLI.
- Correction observed working (filler removal, delete+retype clean); polisher occasionally hallucinated continuations — growth cap added to `sanitizeResult` (fail open to raw when output > raw + max(16, 25%)).
