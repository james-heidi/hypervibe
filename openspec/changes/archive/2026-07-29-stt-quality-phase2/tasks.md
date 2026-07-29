# Tasks: stt-quality-phase2

## 1. Audio front-end + raw corpus capture

- [x] 1.1 Create `AudioFrontEnd.swift`: biquad HPF (~80 Hz) → speech-RMS gain (loudest-quartile estimate, target ≈ −20 dBFS) → soft limiter → downward gate; `process(_ samples: [Int16], mode:) -> [Int16]`; deterministic; mode enum backed by UserDefaults `audioFrontEndMode` (default `legacy` = existing `boostForASR`). Add to BOTH `build.sh` and `Package.swift`.
- [x] 1.2 Engines: replace `PCMWaveWriter.boostForASR` call sites (Parakeet + OpenAI) with `AudioFrontEnd.process`, keeping the raw snapshot alongside for corpus.
- [x] 1.3 `CorpusRecorder`: add `rawPCM` parameter → writes `<id>.raw.wav`; sidecar gains `frontEndMode`; short-clip path records raw only.
- [x] 1.4 Menu: sticky toggle 「音频前端（实验）」 switching `legacy`/`conditioned`, tooltip states legacy is default until corpus gate passes.
- [x] 1.5 Build clean; dictate 2 utterances in each mode; verify corpus has raw+processed WAVs and correct `frontEndMode`.

## 2. Vocabulary boosting

- [x] 2.1 Create `VocabularyStore.swift`: JSON load/save at `Application Support/HyperVibe/vocabulary.json`, tolerant decode (skip malformed entries, log), default seed terms (Heidi, Claude Code, HyperVibe, Parakeet, common slash-command words), mtime-checked reload. Add to BOTH build files.
- [x] 2.2 Parakeet engine: CTC model lifecycle — menu-triggered `CtcModels.downloadAndLoad()` with `ModelPrepProgress` reporting; retain spotter; UserDefaults `vocabularyBoostingEnabled` (default off).
- [x] 2.3 Decode integration: when enabled + models cached + list non-empty, transcribe with `CustomVocabularyContext`; on throw, retry once unboosted (fail-open); log applied terms (`result.ctcAppliedTerms`).
- [x] 2.4 Menu: 「词表增强」 submenu — enable toggle, 「下载增强模型…」 (with progress like Parakeet), 「编辑词表…」 via NSWorkspace.
- [x] 2.5 Build; manual test: say "Heidi" 3 times with boosting off then on (after download); verify canonical form appears when boosted and log shows applied terms; kill the CTC model dir and confirm fail-open.

## 3. Eval CLI extensions

- [x] 3.1 `--engine parakeet|cohere`: Cohere via FluidAudio `CoherePipeline`, CLI-side model download on first use; same hypotheses.json shape. If Cohere model access fails, record the failure as the result and stop.
- [x] 3.2 `--frontend legacy|conditioned` for replaying `*.raw.wav` corpora: copy `AudioFrontEnd.swift` into the CLI package with keep-in-sync header; add parity check (app-processed WAV vs CLI-processed raw WAV byte-identical for same mode).
- [x] 3.3 `--vocabulary path.json` flag so boosting can be A/B'd offline on the corpus too.

## 4. Gates + docs

- [x] 4.1 Corpus replay matrix on all recorded raw WAVs: {legacy, conditioned} × {no-vocab, vocab} × {parakeet} + cohere baseline; score each with `score.py`; record numbers in design.md Measured Results.
- [x] 4.2 Apply gates: flip front-end default only if aggregate WER ≤ legacy AND quiet-clip subset improves; enable-by-default decision for vocabulary only if command exact-match improves; write the decision and numbers down.
- [x] 4.3 Update `tools/stt-eval/README.md` (new flags, raw-WAV replay workflow) and AGENTS.md file table (`AudioFrontEnd.swift`, `VocabularyStore.swift`).
