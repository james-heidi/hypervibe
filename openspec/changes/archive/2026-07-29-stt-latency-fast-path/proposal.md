# Proposal: Dictation fast path — cut post-release latency (Phase 1)

## Why

Phase 0 measurements show decode is not the bottleneck: warm Parakeet decode is 72–162 ms, while the user waits up to 0.35 s of fixed post-release drain (3.0 s cold) plus a serial polish pass budgeted at 2.5 s (local) / 1.0 s (cloud) before anything is typed. The perceived slowness of push-to-talk is almost entirely drain + polish. This change removes both from the critical path with zero new dependencies.

## What Changes

- **Type raw transcript immediately** after decode; polish no longer blocks typing. When polish returns a different string, apply it as a guarded backspace-and-retype correction; a toggle can disable the correction pass (raw-only).
- **Adaptive post-release drain**: end capture as soon as voice frames stop arriving (~short quiet window) instead of a fixed 0.35 s; keep current values as upper bounds (cold-start grace unchanged).
- **Drop the WAV temp-file round-trip** in the Parakeet engine: feed PCM via `AVAudioPCMBuffer` directly to FluidAudio instead of write-WAV → re-read. (Corpus recording keeps producing identical WAVs.)
- **Explicitly rejected — streaming decode during hold**: Phase 0 measured warm decode at ≤162 ms; `StreamingAsrManager` complexity is not justified by a ≤162 ms ceiling. Revisit only if corpus p95 decode says otherwise.

## Capabilities

### New Capabilities
- `dictation-responsiveness`: latency behavior of the push-to-talk path — when text appears, how capture ends, and how polish corrections are applied.

### Modified Capabilities

(none — `stt-corpus-recording` and `stt-eval-harness` requirements unchanged; corpus WAVs must remain byte-identical in content to what the engine decodes)

## Impact

- `RemoteMicController.swift`: typing order (raw first, async polish correction), adaptive drain scheduling.
- `ParakeetTranscriptionEngine.swift`: `AVAudioPCMBuffer` decode path replacing temp WAV; corpus recorder tap adjusted to write the WAV itself.
- `MenuBarManager.swift`: correction toggle menu item.
- `TranscriptPolisher.swift`: untouched (still runs; only its consumer changes).
- Risk surface: typing/correction interacts with the stuck-key and dual-delivery invariants in AGENTS.md — correction must be cancellable and never fire after a new utterance starts.
- Verification: manual remote testing + Phase 0 harness (decode parity on corpus replays).
