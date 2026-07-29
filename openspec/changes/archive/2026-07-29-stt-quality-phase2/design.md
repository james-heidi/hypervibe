# Design: stt-quality-phase2

## Context

See proposal.md — Why. Relevant state:
- Gain today: `PCMWaveWriter.boostForASR` (`TranscriptionEngine.swift:137`) — pure peak normalization to 20k, called in both engines at finish.
- Raw pre-boost PCM already flows through `RemoteMicController.handlePayload` and engine `append`; engines buffer it unmodified until finish, so the "raw" signal is available at the same place the front-end will run.
- FluidAudio 0.15.5 vocabulary stack (verified in vendored source/docs): `CtcModels.downloadAndLoad()` (~130 MB extra CTC encoder for TDT v3), `CtcKeywordSpotter`, `CustomVocabularyContext(terms: [CustomVocabularyTerm(text:aliases:)])`, `asrManager.transcribe(samples, customVocabulary:)`; streaming mode has documented limitations — we use file/batch decode, unaffected.
- FluidAudio also ships `CoherePipeline` (`Sources/FluidAudio/ASR/Cohere/`) with its own model download.
- Eval CLI (`tools/stt-eval/ParakeetEvalCLI`) is a separate SPM package; scorer is engine-agnostic via `hypotheses.json`.

Constraints: no new dependencies; corpus gates from `tools/stt-eval/README.md`; AGENTS.md invariants; new .swift files go in both `build.sh` and `Package.swift`.

## Goals / Non-Goals

**Goals**
- Front-end that provably (corpus-gated) helps quiet clips and never regresses aggregate WER.
- Vocabulary boosting on by explicit opt-in, failing open in every path.
- Cohere numbers on our audio, offline only.

**Non-Goals**
- No in-app Cohere engine this change (numbers first; separate change if they win).
- No streaming vocabulary boosting (FluidAudio documents limitations; our decode is batch).
- No VAD (push-to-talk is the gate); no polisher changes beyond what Phase 1 already did.

## Decisions

**D1 — Front-end: whole-utterance offline chain in a new `AudioFrontEnd.swift`.**
Applied once at finish (not per-frame): biquad high-pass (~80 Hz) → speech-RMS gain (target ≈ −20 dBFS computed over the loudest quartile of 20 ms frames, so silence doesn't drag the estimate) → soft limiter instead of hard clip → gentle downward gate on frames far below the speech floor. Deterministic by construction (no state across utterances). vDSP/Accelerate (already linked) where convenient. Mode via UserDefaults `audioFrontEndMode` (`legacy` | `conditioned`), sticky menu toggle; **legacy stays default until the gate passes** (spec requirement). Engines call `AudioFrontEnd.process(samples, mode:)` where they call `boostForASR` today; `boostForASR` becomes the legacy branch. Alternative — real-time per-frame chain during capture: rejected, non-deterministic tuning surface and no latency need (decode is batch).

**D2 — Corpus raw WAV.**
`CorpusRecorder.record` gains `rawPCM` and writes `<id>.raw.wav` next to `<id>.wav` (processed); sidecar gains `frontEndMode`. Raw comes from the engine's pre-front-end buffer at the same snapshot. Short-clip path records raw only (nothing was processed).

**D3 — Vocabulary: `VocabularyStore.swift` + CTC lifecycle inside the Parakeet engine.**
- Store: JSON at `Application Support/HyperVibe/vocabulary.json` — `[{"text": "Heidi", "aliases": ["Haiti", "Heidy"]}, ...]`; seeded with defaults (Heidi, Claude Code, HyperVibe, Parakeet, slash-command words) on first enable; mtime-checked reload per utterance so edits apply without restart. Menu: 「编辑词表…」opens the file via `NSWorkspace` (no in-app editor — a text file beats UI here).
- CTC models: menu item triggers `CtcModels.downloadAndLoad()` with the existing `ModelPrepProgress` plumbing; spotter retained alongside `asrManager`.
- Decode: when enabled + models present + list non-empty, call the `customVocabulary` transcribe overload; on any throw, retry once without vocabulary (fail-open requirement). If the overload's parameter shape differs from docs in 0.15.5, adapt at the call site — the store/menu/fail-open structure is unaffected.

**D4 — Cohere + front-end flags in eval CLI.**
`parakeet-eval` gains `--engine parakeet|cohere` (Cohere via `CoherePipeline`, models downloaded CLI-side on first use) and `--frontend legacy|conditioned` for raw-WAV replays. DSP reuse across app and CLI: copy `AudioFrontEnd.swift` into the CLI package with a keep-in-sync header comment (SPM cannot reference sources outside the package root; a ~100-line DSP file is cheaper duplicated than restructuring the build). Rename binary concern: keep `parakeet-eval` name; engine flag is enough.

**D5 — Gates (from specs + README).**
Front-end default flips to `conditioned` only when: corpus aggregate WER (new vs legacy replay of the same raw WAVs) is equal-or-better AND the quiet-clip subset improves. Vocabulary ships enabled-capable but off until the corpus command exact-match rate improves with it on. Cohere: numbers recorded in the change notes; adoption decision deferred to a future change.

## Risks / Trade-offs

- [Front-end hurts loud/clean clips] → gate on aggregate + quiet subset; legacy default until proven; toggle stays for A/B.
- [CTC spotting adds per-utterance latency] → measure on corpus replay (~130 MB encoder, doc claims 26x real-time for approach 2 — ≈40 ms per second of audio); if it pushes warm latency past Phase 1 numbers, keep boosting off by default and note it.
- [Cohere HF repo may be gated] → FluidAudio's download path uses its own mirrors; if access fails, record that as the Cohere result and stop — eval-only scope means no product impact.
- [Duplicated DSP file drifts] → header comment in both copies + parity assertion in eval (process same WAV in app-recorded corpus vs CLI: byte-identical).
- [`transcribe(customVocabulary:)` signature drift vs docs] → adapt call site; fail-open retry isolates any breakage to the boosting stage.
- [Vocabulary JSON hand-editing errors] → tolerant decode (skip malformed entries, log), never block dictation.

## Migration Plan

Additive. Defaults: front-end `legacy`, boosting off. Corpus gains extra files (old sidecars remain readable — new fields optional). Rollback: toggles; no data migration. Eval CLI changes are dev-only.

## Open Questions

- Final DSP constants (HPF corner, target RMS, gate depth) — tuned against the corpus during apply; spec only fixes determinism + gates, not constants.
- Whether CTC download should also fetch on first *enable* vs explicit menu item — start with explicit menu item (matches Parakeet pattern); revisit if users get confused.

## Measured Results (2026-07-29, 32-clip corpus, M-series)

**Vocabulary boosting** (CTC 110m spotter + rescorer, rescue pass OFF, minSimilarity 0.75):
- 3/32 clips changed, all correct: "Haiti"→"Heidi", "hyperwipe"→"HyperVibe" ×2. **0 false positives.**
- Journey: bare terms spot nothing (need `loadWithCtcTokens` ctcTokenIds); default thresholds + rescue pass replaced common words ("payment"→"Parakeet", 10+ false hits); thresholds must be passed to `ctcTokenRescore` explicitly.
- Cost: decode 106→247 ms mean (+~140 ms). Verdict: **enable-capable, default off**; corpus command-set still too small for a default-on decision.
- Defaults seeded with strict thresholds; no common English words in the term list.

**Audio front-end** (directional A/B, legacy-normalized clips replayed through conditioned chain):
- 15/32 transcripts changed; churn is punctuation/casing, one slight regression ("autocrat"→"autoc"), no clear win.
- Expected: corpus clips were already peak-normalized; true test needs raw quiet clips (now recorded going forward).
- **Gate result: legacy stays default.** Conditioned mode available via menu for future raw-corpus A/B.

**Cohere Transcribe** (FluidAudio CoherePipeline, q8 CoreML, ~2 GB):
- Clearly better on hard clips: "menu driving"→"manual driving", "FST"→"FSD", proper digits/punctuation. 26/32 differ.
- Hallucinates on silence clips ("you", "Thank you.") — would need silence gating in-app.
- Warm decode ~400–730 ms (p95 732) vs Parakeet 106 ms; first-run compile skews mean. Usable for PTT; 4–7× slower.
- Verdict: **strongest quality candidate for a future opt-in engine change**; needs ground-truth refs + silence gate before adoption.

**DSP parity**: app vs CLI `condition()` code identical (comments-only diff); constants match.

**Live verification (2026-07-29)**: both front-end modes dictate correctly with raw+processed WAVs and frontEndMode recorded; boost corrects live ("Hyper Vibe."→"HyperVibe") at 109–164 ms decode after the prewarm fix (first-load CTC compile moved off the dictation path — was a 12 s in-utterance stall). Observed: isolated words occasionally drift to Cyrillic ("Хайпер вайб") — v3 multilingual behavior, tracked via corpus.
