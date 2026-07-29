# dictation-responsiveness

## Purpose

Define when dictated text appears and how capture ends, so push-to-talk feels immediate: raw transcript types as soon as decode finishes, capture ends when speech ends, and polish improves text without delaying it.

## Requirements

### Requirement: Raw transcript types immediately

The raw ASR transcript SHALL be typed as soon as decoding completes, without waiting for any polish pass. Polish SHALL run concurrently and SHALL NOT delay the initial typing.

#### Scenario: Polish slower than decode
- **WHEN** a dictation decodes successfully and the polish pass takes longer than decode
- **THEN** the raw transcript is typed before polish completes

#### Scenario: Polish unavailable
- **WHEN** polish is off or its backend is unavailable
- **THEN** the raw transcript is typed with no added delay relative to decode completion

### Requirement: Guarded polish correction

When polish produces a string different from the raw transcript, the correction SHALL be applied by deleting exactly the previously typed raw text and typing the polished text. The correction SHALL be skipped when a new utterance has started, when dictation was cancelled, or when the correction toggle is disabled. When polish output equals the raw transcript, no correction events SHALL be sent.

#### Scenario: Polished text differs
- **WHEN** polish returns a different string while no new utterance has started and correction is enabled
- **THEN** exactly the raw text length is deleted and the polished text is typed in its place

#### Scenario: New utterance supersedes correction
- **WHEN** the user starts a new push-to-talk hold before a pending correction fires
- **THEN** the correction is discarded and no delete or retype events are sent

#### Scenario: Correction disabled
- **WHEN** the correction toggle is off and polish returns a different string
- **THEN** the raw text stays as typed and no correction events are sent

#### Scenario: Identical polish output
- **WHEN** polish returns the same string as the raw transcript
- **THEN** no delete or retype events are sent

### Requirement: Adaptive capture end

After push-to-talk release, capture SHALL end as soon as no new voice frame has arrived for a short quiet window, bounded above by the previous fixed drain (0.35 s warm; cold-start grace unchanged). Audio arriving within the quiet window SHALL still be included in the utterance.

#### Scenario: Frames stop promptly
- **WHEN** the user releases the button and voice frames stop arriving
- **THEN** recognition starts within the quiet window rather than after the full fixed drain

#### Scenario: Late frames still captured
- **WHEN** voice frames continue arriving briefly after release
- **THEN** those frames are included and capture ends one quiet window after the last frame, never exceeding the previous fixed bounds

### Requirement: Decode without temp-file round-trip

The local engine SHALL decode the captured PCM directly from memory without writing and re-reading an intermediate audio file. Transcription output SHALL be unchanged relative to the file-based path for identical audio, and corpus recording SHALL still persist a WAV whose content equals what was decoded.

#### Scenario: Decode parity
- **WHEN** the same utterance audio is decoded via the in-memory path and via a WAV file
- **THEN** the transcripts are identical

#### Scenario: Corpus recording still works
- **WHEN** corpus recording is enabled and an utterance is decoded via the in-memory path
- **THEN** a WAV with the decoded audio content and its metadata sidecar are still persisted
