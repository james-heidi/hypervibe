# Proposal: STT evaluation corpus + replay harness (Phase 0)

## Why

We are considering STT engine and pipeline changes (streaming decode, audio front-end, alternate engines like Cohere / transcribe.cpp / Qwen3-ASR via MLX), but today there is no way to measure whether any change helps: no saved utterances, no ground truth, no replay tooling. All published WER numbers come from clean benchmark audio, not the quiet, CELT-wideband, PLC-patched A2854 remote-mic audio HyperVibe actually consumes. Phase 0 builds the measuring stick; every later engine decision is gated on it.

## What Changes

- Add an opt-in **dictation corpus recorder**: when enabled, each push-to-talk utterance persists its exact pre-ASR WAV (post-boost, what the engine saw) plus the raw and polished transcripts and timing metadata to `~/Library/Application Support/HyperVibe/corpus/`.
- Add a menu toggle (debug submenu) to enable/disable corpus recording; off by default, persisted in UserDefaults.
- Add a standalone **replay harness script** (`tools/stt-eval/`) that runs a corpus through an engine (FluidAudio Parakeet CLI baseline first) and reports per-utterance and aggregate metrics: normalized WER/CER, exact-command success, hallucination-on-silence, wall-clock decode latency.
- Add a reference-transcript workflow: harness emits a `refs.tsv` stub from recorded raw transcripts that the user hand-corrects to become ground truth.
- No changes to transcription behavior itself. No engine changes.

## Capabilities

### New Capabilities
- `stt-corpus-recording`: capture per-utterance WAV + transcripts + timing metadata for offline evaluation, behind an opt-in toggle.
- `stt-eval-harness`: offline replay of a recorded corpus through an ASR engine with WER/CER, command-success, and latency reporting.

### Modified Capabilities

(none — existing dictation behavior is unchanged; recording is a passive tap)

## Impact

- New Swift file `CorpusRecorder.swift` (added to BOTH `build.sh` and `Package.swift` per repo rule).
- Small hooks in `RemoteMicController.swift` (utterance finish path) and `MenuBarManager.swift` (toggle menu item).
- New non-shipping tooling under `tools/stt-eval/` (Python or Swift script; not part of the app bundle).
- Disk: ~1 MB per recorded utterance (48 kHz mono WAV); user-controlled, opt-in.
- Privacy: recordings stay local; toggle is explicit; no telemetry.
