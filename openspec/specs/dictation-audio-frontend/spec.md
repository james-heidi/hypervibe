# dictation-audio-frontend

## Purpose

Condition the quiet, compressed remote-mic audio (gain, filtering, gating) before ASR so the engine receives usable signal, without ever making transcription worse than the raw path.

## Requirements

### Requirement: Audio conditioning before ASR

Captured PCM SHALL pass through a conditioning chain before reaching any ASR engine: a high-pass filter removing sub-speech rumble, automatic gain normalization based on speech-level (RMS) rather than instantaneous peak, and a soft gate attenuating non-speech noise floors. The chain SHALL be deterministic: identical input produces identical output.

#### Scenario: Quiet clip amplified
- **WHEN** an utterance's speech level is far below full scale (typical remote HCI capture)
- **THEN** the conditioned audio reaches a usable speech level without clipping

#### Scenario: Deterministic
- **WHEN** the same raw PCM is conditioned twice
- **THEN** the outputs are sample-identical

### Requirement: Front-end toggle for A/B

The conditioning chain SHALL be switchable at runtime (menu or defaults key) between the new chain and the previous peak-normalization behavior, so on-device A/B comparison is possible during evaluation.

#### Scenario: Fallback to legacy path
- **WHEN** the front-end is switched to legacy mode
- **THEN** the engine receives peak-normalized audio identical to the pre-Phase-2 behavior

### Requirement: Quality gate before default-on

The new chain SHALL become the default only after corpus replay shows aggregate WER no worse than the legacy path and improvement on the quiet-clip subset. Until then it SHALL remain selectable but not default.

#### Scenario: Regression blocks default
- **WHEN** corpus replay with the new chain shows aggregate WER worse than legacy
- **THEN** the legacy path remains the default

### Requirement: Applies to all engines

The same conditioned audio SHALL feed every ASR engine (local and cloud), so engine comparisons are not confounded by different front-ends.

#### Scenario: Engine parity of input
- **WHEN** the same utterance is dictated with the local engine and the cloud engine under the same front-end setting
- **THEN** both engines receive identically conditioned audio
