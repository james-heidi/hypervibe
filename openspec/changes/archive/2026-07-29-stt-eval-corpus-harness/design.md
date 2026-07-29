# Design: stt-eval-corpus-harness

## Context

See proposal.md — Why. Current dictation path: `RemoteMicController.finishRecognition` → `engine.finishUtterance` → `polisher.polish` → typed text. The Parakeet engine already materializes the exact engine input as a WAV (`ParakeetTranscriptionEngine.finishUtterance` writes a boosted temp WAV, then deletes it). FluidAudio is only reachable from Swift (SPM package in `Vendor/FluidAudioDeps`); the production app build is a flat `swiftc` invocation (`build.sh`). No test infrastructure exists.

Constraints: dictation latency must not regress; fragile invariants in AGENTS.md (debounce, stuck-key safety) must be untouched — this change only taps the completion path.

## Goals / Non-Goals

**Goals**
- Zero-risk passive tap: recording failures never surface to the user.
- One corpus format both the app (writer) and harness (reader) agree on.
- Harness reproduces the app's exact Parakeet configuration (v3, int8, `melChunkContext=false`, `dualDecodeArbitration=true`) so baseline numbers are honest.

**Non-Goals**
- No streaming, engine, or front-end changes (later phases).
- No in-app metrics UI; harness is developer tooling.
- No corpus management UI (delete/browse) — Finder is enough.
- Harness does not ship in the app bundle.

## Decisions

**D1 — Corpus format: flat directory, one WAV + one JSON per utterance.**
`~/Library/Application Support/HyperVibe/corpus/<utteranceId>.wav` + `<utteranceId>.json` where `utteranceId = <ISO8601-compact>-<shortUUID>`. JSON fields: `id, timestamp, engineID, sampleRate, sampleCount, decodeMs, rawTranscript, polishedTranscript, appVersion`. References live in a single hand-edited `refs.tsv` (`id \t reference \t kind`), `kind ∈ {speech, command, silence}`. Alternative considered: SQLite — rejected, adds schema management for a few hundred files; flat files diff and inspect trivially.

**D2 — Capture point: inside `ParakeetTranscriptionEngine.finishUtterance` (and the OpenAI equivalent) right where the boosted WAV already exists.**
The engine already writes exactly the bytes we want; recording = copy instead of delete, plus a completion-side JSON write. Alternative: tap in `RemoteMicController` — rejected, it only sees pre-boost PCM and would duplicate WAV encoding. A tiny `CorpusRecorder` (enabled flag + async write on a utility queue) keeps engine diffs to a few lines.

**D3 — Harness split: Swift CLI decodes, Python scores.**
- `tools/stt-eval/ParakeetEvalCLI/` — minimal SPM executable that depends on the same FluidAudio 0.15.5 pin, loads the same ASRConfig, transcribes each WAV, emits `hypotheses.json` (`id, text, decodeMs`). FluidAudio is Swift-only, so decode must be Swift; SPM is fine here because this target never ships.
- `tools/stt-eval/score.py` — stdlib-only Python: normalizes (lowercase, strip punctuation/whitespace), Levenshtein WER/CER, command exact-match, hallucination-on-silence, mean/p95 latency; writes `report.json` + prints a table. Alternative: everything in Swift — rejected, text normalization and quick iteration are cheaper in Python; no third-party deps either way.

**D4 — Engine pluggability = "hypotheses.json in, report out".**
Any future engine (transcribe.cpp CLI, MLX, Cohere) just needs to produce `hypotheses.json` for the same corpus; `score.py` never knows about engines. This keeps Phase 3 bakeoffs trivial.

**D5 — Toggle in the existing debug/dictation submenu, UserDefaults key `corpusRecordingEnabled`.**
Follows `MenuBarManager` conventions for persisted toggles.

## Risks / Trade-offs

- [Recording adds I/O on the recognition thread] → all corpus writes happen on a detached utility queue after the completion fires; failures only `rmDebug`.
- [Corpus WAV is post-boost, so front-end (AGC) experiments can't be replayed from it] → acceptable for Phase 0 (engine comparisons); if Phase 2 needs pre-boost audio, add a second raw WAV per utterance then — format has room.
- [SPM eval CLI drifts from app's flat swiftc build] → CLI pins the identical FluidAudio version and copies the ASRConfig literals; a comment in both files cross-references them.
- [refs.tsv hand-editing is tedious] → stub is pre-filled with raw transcripts; most rows need no edits, only corrections.
- [Disk growth ~1 MB/utterance] → opt-in toggle, user-visible folder, documented in menu item tooltip.

## Migration Plan

Additive only. Ship: new files + menu toggle default-off. Rollback: remove toggle; corpus directory is inert data. Harness lives outside the app bundle; no packaging changes beyond `build.sh`/`Package.swift` source-list additions for `CorpusRecorder.swift`.

## Open Questions

- Whether OpenAI-engine utterances should also be recorded from day one (cheap, same tap) — default yes unless privacy concerns arise.
- p95 latency needs ≥20 clips to be meaningful; corpus size target (100–200) is a collection-discipline question, not a design one.
