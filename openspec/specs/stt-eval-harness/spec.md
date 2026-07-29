# stt-eval-harness

## Purpose

Replay a recorded utterance corpus through an ASR engine offline and report accuracy and latency metrics, so competing engines and pipeline changes can be compared on identical real-world audio before any of them ship.

## Requirements

### Requirement: Reference transcript workflow

The harness SHALL generate an editable reference-transcript file from a corpus, pre-filled with each utterance's recorded raw transcript, which the user corrects by hand to establish ground truth. Utterances without a corrected reference SHALL be excluded from accuracy metrics and reported as unverified.

#### Scenario: Stub generation
- **WHEN** the harness is pointed at a corpus directory without a reference file
- **THEN** it writes a reference stub listing every utterance id with its recorded raw transcript

#### Scenario: Unverified exclusion
- **WHEN** metrics are computed and some utterances have no corrected reference
- **THEN** those utterances are excluded from WER/CER and counted separately as unverified

### Requirement: Engine replay

The harness SHALL run every corpus WAV through a selected ASR engine and record, per utterance, the hypothesis transcript and decode wall-clock time. The first supported engine SHALL be the app's current local Parakeet configuration; the engine interface SHALL accept alternative engines by name so later candidates can be compared on the same corpus.

#### Scenario: Full-corpus replay
- **WHEN** the harness runs against a corpus of N utterances with a supported engine
- **THEN** it produces N hypothesis records, each with transcript text and decode time in milliseconds

### Requirement: Metrics report

For a replayed corpus with references, the harness SHALL report: normalized WER and CER (case-, punctuation-, and whitespace-insensitive), exact-match rate for utterances marked as commands, hallucination rate on utterances whose reference is empty, and latency aggregates (mean and p95 decode time). Results SHALL be emitted both human-readable and machine-readable (JSON) so runs can be diffed.

#### Scenario: Aggregate report
- **WHEN** a replay completes over a referenced corpus
- **THEN** the report contains corpus-level WER, CER, command exact-match rate, hallucination-on-silence rate, and mean/p95 decode latency, plus a JSON file with per-utterance rows

#### Scenario: Comparing two runs
- **WHEN** two replay JSON outputs for the same corpus are diffed
- **THEN** per-utterance rows align by utterance id so regressions are attributable to specific clips
