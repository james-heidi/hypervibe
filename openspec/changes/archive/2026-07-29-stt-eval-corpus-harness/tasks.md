# Tasks: stt-eval-corpus-harness

## 1. Corpus recorder (app side)

- [x] 1.1 Create `CorpusRecorder.swift`: enabled flag backed by UserDefaults `corpusRecordingEnabled`, corpus dir creation under Application Support, async `record(id:wavSourceURL:metadata:)` on a utility queue that copies the WAV and writes the JSON sidecar; all failures `rmDebug` only. Add file to BOTH `build.sh` SWIFT_FILES and `Package.swift` sources.
- [x] 1.2 Tap `ParakeetTranscriptionEngine.finishUtterance`: when recording enabled, copy the boosted temp WAV into the corpus (instead of only deleting it) and, in the completion, write metadata (id, timestamp, engineID, sampleRate, sampleCount, decodeMs, rawTranscript). Include the short-clip-gate path (record audio with empty transcript).
- [x] 1.3 Same tap in `OpenAITranscriptionEngine.finishUtterance`.
- [x] 1.4 Record `polishedTranscript`: after `polisher.polish` returns in `RemoteMicController` (both finish paths), update the utterance's JSON sidecar.
- [x] 1.5 Menu toggle in `MenuBarManager` dictation/debug submenu: "录制听写语料 (评测用)", checkmark state, persists; tooltip names the corpus folder.
- [x] 1.6 Build via `./build.sh`; manual smoke test with paired remote: toggle on → 3 utterances (normal speech, very short press, silence) → verify 3 WAV+JSON pairs; toggle off → verify nothing new written.

## 2. Eval CLI (decode)

- [x] 2.1 Scaffold `tools/stt-eval/ParakeetEvalCLI/` SPM executable pinning FluidAudio 0.15.5 exact; copy ASRConfig literals from `ParakeetTranscriptionEngine.swift` with cross-reference comments in both files.
- [x] 2.2 Implement: enumerate `<corpus>/*.wav`, load models from the same default cache dir the app uses, transcribe each, emit `hypotheses.json` rows `{id, text, decodeMs}`; `--corpus` and `--out` args.
- [x] 2.3 Run against the smoke-test corpus from 1.6; verify transcripts match app-recorded rawTranscript for identical audio.

## 3. Scoring (metrics)

- [x] 3.1 `tools/stt-eval/score.py` (stdlib only): `gen-refs` subcommand writes `refs.tsv` stub (id, rawTranscript from sidecars, kind=speech) skipping ids already present; `score` subcommand joins refs + hypotheses.
- [x] 3.2 Implement normalization (lowercase, strip punctuation, collapse whitespace, NFKC) and Levenshtein word/char distance; per-utterance WER/CER.
- [x] 3.3 Aggregate report: corpus WER/CER over `kind=speech`+`command`, exact-match rate over `kind=command`, hallucination rate over `kind=silence` (non-empty hypothesis = hallucination), unverified count, mean/p95 decodeMs; print table + write `report.json` with per-utterance rows keyed by id.
- [x] 3.4 Self-check in `__main__`-adjacent `test_score.py` or inline asserts: known WER fixtures (identical=0, one substitution over 4 words=0.25, empty-ref hallucination case).
- [x] 3.5 End-to-end dry run: gen-refs → hand-correct 3 rows → CLI replay → score; confirm report numbers move when a ref is deliberately corrupted.

## 4. Docs + wrap-up

- [x] 4.1 `tools/stt-eval/README.md`: collection protocol (target 100–200 utterances: slash commands, code vocab, names, quiet/far-field, each supported language, false starts, silence), commands for replay + scoring, and the adoption-gate metrics this corpus feeds.
- [x] 4.2 Note corpus recorder + harness in AGENTS.md file table.
