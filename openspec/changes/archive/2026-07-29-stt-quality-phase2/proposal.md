# Proposal: Dictation quality — front-end, vocabulary, Cohere eval (Phase 2)

## Why

Latency is fixed (Phase 1); quality limiters remain, in measured order: (1) remote-mic audio is quiet, CELT-wideband, PLC-patched, and gets only peak normalization — no ASR model fixes bad input; (2) no vocabulary conditioning — the corpus already shows "Heidi" → "Haiti", and slash commands / code terms have no bias; (3) FluidAudio 0.15.5 ships a native Cohere Transcribe engine (~8% relative WER better than Parakeet v3 on Open ASR Leaderboard) that we have never measured on our audio. All three need zero new dependencies.

## What Changes

- **Audio front-end**: replace peak-only `boostForASR` with high-pass filter + RMS-based AGC + soft noise gate on the 48 kHz PCM before the engine. Gated: ships only if corpus replay shows no WER regression and improves the quiet-clip subset.
- **Custom vocabulary boosting** (local Parakeet path): FluidAudio CTC keyword spotting with a user-editable term list (defaults include product/code terms like "Heidi", "Claude Code", slash commands). Opt-in — requires a one-time ~130 MB CTC encoder download via menu, like the Parakeet model.
- **Corpus records raw audio too**: each utterance saves the pre-front-end WAV alongside the processed one, so front-end experiments can be replayed offline (Phase 0 design anticipated this).
- **Cohere offline evaluation**: extend the eval CLI with an engine flag (`--engine parakeet|cohere`) so Cohere Transcribe runs on the same corpus. Eval only — no in-app Cohere engine until the numbers justify it.

## Capabilities

### New Capabilities
- `dictation-audio-frontend`: conditioning applied to captured audio before ASR (gain, filtering, gating) and the parity constraints on it.
- `dictation-vocabulary-boosting`: user-controlled term list biasing local recognition, including aliases, opt-in model download, and failure behavior.

### Modified Capabilities
- `stt-corpus-recording`: per-utterance capture gains the raw (pre-processing) audio in addition to the processed audio the engine decoded.

## Impact

- `TranscriptionEngine.swift` (front-end DSP replacing/extending `PCMWaveWriter.boostForASR`), `ParakeetTranscriptionEngine.swift` (vocabulary context on transcribe, CTC model lifecycle), `OpenAITranscriptionEngine.swift` (front-end shared), `CorpusRecorder.swift` (raw WAV), `MenuBarManager.swift` (vocabulary menu: download CTC models, edit terms; front-end toggle for A/B), new `VocabularyStore.swift` (term list JSON + defaults).
- Eval: `tools/stt-eval/ParakeetEvalCLI` gains `--engine cohere` and `--frontend on|off`.
- Disk: +~130 MB optional CTC models; corpus doubles per-utterance audio (~2 MB).
- Adoption gates run on the Phase 0 corpus per `tools/stt-eval/README.md`.
