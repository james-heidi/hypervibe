# stt-corpus-recording

## Purpose

Capture every push-to-talk utterance as it was heard by the ASR engine — audio, transcripts, and timing — so engine and pipeline changes can be evaluated offline against real remote-mic conditions.

## Requirements

### Requirement: Opt-in recording toggle

Corpus recording SHALL be off by default and controllable via a menu toggle. The setting SHALL persist across app restarts. No audio SHALL be persisted while the toggle is off.

#### Scenario: Toggle off by default
- **WHEN** the app launches on a machine that has never enabled corpus recording
- **THEN** no corpus files are written for any utterance

#### Scenario: Toggle persists
- **WHEN** the user enables corpus recording and relaunches the app
- **THEN** recording remains enabled without re-toggling

### Requirement: Per-utterance capture

While recording is enabled, each completed push-to-talk utterance that reaches the ASR engine SHALL persist to a local corpus directory: (a) the exact mono PCM audio submitted to the engine (post conditioning), as a WAV file; (b) the raw captured audio before any conditioning, as a second WAV file, so front-end changes can be replayed offline; (c) the raw ASR transcript; (d) the polished transcript actually typed (when polish ran); (e) metadata including timestamp, engine id, sample rate, sample count, decode wall-clock time, and the front-end mode in effect.

#### Scenario: Utterance recorded
- **WHEN** recording is enabled and the user completes a dictation that produces text
- **THEN** a processed WAV, a raw WAV, and a metadata record for that utterance exist in the corpus directory, and the metadata's raw transcript matches what the engine returned

#### Scenario: Short clip still recorded
- **WHEN** recording is enabled and the utterance is dropped by the engine's short-clip gate
- **THEN** the audio and a metadata record (with empty transcript) are still persisted, so silence/false-start cases are represented in the corpus

#### Scenario: Front-end replay possible
- **WHEN** an utterance was recorded under any front-end mode
- **THEN** its raw WAV can be re-conditioned offline with a different front-end and produce the audio that mode would have fed the engine

### Requirement: Recording must not affect dictation

Persisting corpus data SHALL NOT add user-perceivable latency to the dictation path and SHALL NOT change transcription results. A failure to write corpus files SHALL be logged and otherwise ignored.

#### Scenario: Disk write failure
- **WHEN** the corpus directory is unwritable
- **THEN** dictation completes normally and the failure is only visible in the diagnostic log

### Requirement: Local-only storage

Corpus data SHALL be stored only on the local machine under the user's Application Support directory and SHALL never be uploaded by the app.

#### Scenario: No network use
- **WHEN** corpus recording is enabled with the local Parakeet engine selected
- **THEN** no network request contains corpus audio or transcripts
