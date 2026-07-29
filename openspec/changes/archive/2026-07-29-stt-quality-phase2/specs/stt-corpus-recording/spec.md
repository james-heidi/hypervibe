# stt-corpus-recording (delta)

## MODIFIED Requirements

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
