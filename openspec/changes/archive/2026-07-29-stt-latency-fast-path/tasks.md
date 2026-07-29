# Tasks: stt-latency-fast-path

## 1. In-memory decode (isolated, verifiable first)

- [x] 1.1 `ParakeetTranscriptionEngine.finishUtterance`: build 48 kHz mono `AVAudioPCMBuffer` from boosted `[Int16]`, call `manager.transcribe(buffer, decoderState:)`; remove temp-WAV write/delete.
- [x] 1.2 Corpus tap: `CorpusRecorder.record` variant that writes the WAV from the boosted sample array (reuse dropped-clip writer); keep metadata fields identical.
- [x] 1.3 Parity check: replay the existing recorded corpus with the Phase 0 harness; new in-app path on the same audio must produce identical transcripts (manual dictation + sidecar comparison, and CLI replay of the new corpus WAVs).

## 2. Adaptive drain

- [x] 2.1 Stamp `lastVoiceFrameAt` where decoded PCM is appended in `RemoteMicController` (capture callback).
- [x] 2.2 Replace fixed drain scheduling (`RemoteMicController.swift:460-470`): 50 ms repeating check, commit when quiet ≥ 120 ms, hard caps = old 0.35 s / cold grace unchanged; keep `finishWorkItem` cancellation semantics.
- [x] 2.3 Log measured release→commit time (`rmDebug`) for tuning; verify with paired remote that trailing words are not clipped (say a sentence ending in a soft syllable ×5).

## 3. Raw-first typing + guarded correction

- [x] 3.1 `MenuBarManager.replaceDictationText(oldLength:with:)`: N delete-backward CGEvents + retype, same event source/pacing as `typeDictationText`; unit of N = the same UTF-16 chunk semantics `typeDictationText` uses.
- [x] 3.2 `RemoteMicController.commitUtteranceLocked`: type raw immediately via `onTranscribedText`, then run polish concurrently; on differing result and passing guards (same `pressGeneration`, not cancelled, correction enabled), invoke correction callback; recovery records final string.
- [x] 3.3 Same reorder in `stopSession` finish path.
- [x] 3.4 Correction toggle: UserDefaults `dictationCorrectionEnabled` (default on), sticky menu item near polish menu with tooltip explaining the manual-typing caveat.
- [x] 3.5 HUD: keep recognizing HUD until raw typed; drop the polish-hold behavior (`RemoteMicController.swift:512` comment) — HUD ends at raw typing.

## 4. Verification + wrap-up

- [x] 4.1 `./build.sh` clean; bundle + relaunch.
- [x] 4.2 Manual matrix with paired remote: normal sentence (raw appears fast, correction may land), filler-heavy sentence (correction fires, text replaced cleanly), correction toggle off (raw stays), rapid re-press during polish (no correction fires), silence press, disconnect mid-hold (stuck-key invariant intact).
- [x] 4.3 Measure: 10 utterances, log release→typed latency before/after values from `rmDebug` lines; record numbers in change notes.
- [x] 4.4 Update AGENTS.md if typing/correction adds a new invariant (correction must be generation-guarded).
