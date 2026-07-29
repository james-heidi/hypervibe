# stt-eval — HyperVibe dictation evaluation harness

Offline measuring stick for STT engine/pipeline changes. Nothing here ships in the app.

## Workflow

1. **Collect a corpus** (app side)
   - Menu → engine submenu → enable 「录制听写语料（评测用）」.
   - Dictate normally. Each utterance saves `<id>.wav` + `<id>.json` to
     `~/Library/Application Support/HyperVibe/corpus/`.
   - Target 100–200 utterances covering: slash commands, code vocabulary,
     names/acronyms, quiet + far-field speech, every language you actually use,
     false starts, and pure silence presses. p95 latency needs ≥20 clips.

2. **Make ground truth**
   ```bash
   python3 tools/stt-eval/score.py gen-refs \
     --corpus ~/Library/Application\ Support/HyperVibe/corpus --refs refs.tsv
   ```
   Hand-correct the `reference` column (pre-filled with the recorded raw
   transcript). Set `kind` to `command` for clips that must match exactly,
   `silence` for no-speech clips. Re-running only appends new ids.

3. **Replay through an engine**
   ```bash
   cd tools/stt-eval/ParakeetEvalCLI
   swift build -c release
   "$(swift build -c release --show-bin-path)/parakeet-eval" \
     --corpus ~/Library/Application\ Support/HyperVibe/corpus --out hypotheses.json
   ```
   Requires Parakeet v3 models already downloaded once via the HyperVibe menu.
   The CLI pins the same FluidAudio version and ASRConfig as the app.

   Any other engine (transcribe.cpp, MLX, …) joins the bakeoff by
   emitting the same `hypotheses.json` shape: `[{"id", "text", "decodeMs"}]`.

   Built-in variants (Phase 2):
   ```bash
   # Cohere Transcribe (downloads ~2 GB CoreML q8 on first run)
   parakeet-eval --engine cohere --corpus <dir> --out hyp-cohere.json

   # Replay *.raw.wav through a front-end chain (A/B vs legacy)
   parakeet-eval --frontend conditioned --corpus <dir> --out hyp-fe.json

   # Vocabulary boosting A/B (uses the app's vocabulary.json; downloads CTC models)
   parakeet-eval --vocabulary ~/Library/Application\ Support/HyperVibe/vocabulary.json \
     --corpus <dir> --out hyp-vocab.json
   ```
   `vocabulary.json` is FluidAudio's config shape: `{"terms": [{"text", "aliases"}], "minSimilarity": 0.75, ...}`.
   Keep thresholds strict — loose values make the spotter replace common words.
   The CLI's `AudioFrontEnd.swift` is a copy of the app's; keep the DSP in sync.

4. **Score**
   ```bash
   python3 tools/stt-eval/score.py score \
     --refs refs.tsv --hypotheses hypotheses.json --out report.json
   ```
   Reports normalized WER/CER (speech+command), command exact-match rate,
   hallucination-on-silence rate, unverified count, decode mean/p95 ms.
   `report.json` has per-utterance rows keyed by id — diff two runs to
   attribute regressions to specific clips.

   Sanity check the scorer itself: `python3 tools/stt-eval/score.py self-test`.

## Adoption gate (from the STT plan)

An engine/pipeline change ships only if, on this corpus: command exact-match
visibly improves (not a sub-0.1 pp WER wobble), warm decode latency does not
regress, and memory/download stay inside budget. FluidAudio Parakeet stays the
default fallback regardless.

## Notes

- Corpus WAVs are **post-boost** (what the engine actually decoded). Front-end
  (AGC) experiments need raw audio — add a second WAV per utterance if Phase 2
  requires it.
- Corpus is local-only, opt-in, ~1 MB/utterance. Delete the folder to reset.
