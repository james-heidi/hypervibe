# HyperVibe — Agent Guide

macOS menu-bar app (Swift, AppKit) that turns a Siri Remote (1st-gen A1513) into an input device for Claude Code: buttons map to keys, Siri button is push-to-talk. Fork of Remotastic.

## Build & Run

No Xcode project, no SwiftPM build (Package.swift exists but lacks the private framework — don't use it). All Swift files live flat in the repo root.

```bash
./build.sh              # single swiftc invocation → ./HyperVibe binary
./create_app_bundle.sh  # wraps binary into HyperVibe.app, ad-hoc codesigns with entitlements
open HyperVibe.app
```

- Adding a new .swift file: add it to BOTH `build.sh` (SWIFT_FILES) and `Package.swift` (sources).
- Requires macOS 14+ (FluidAudio/Parakeet dependency; enforced by `build.sh`), Xcode CLT. Links private `MultitouchSupport.framework` via `SiriRemote-Bridging-Header.h`.
- Needs Accessibility + Input Monitoring + Bluetooth TCC grants. Ad-hoc signing ties grants to binary hash — rebuilds may need re-approval.
- No tests. Verification is manual with a paired remote. Diagnostic log: `/tmp/hypervibe.log` (use `rmDebug()`, not NSLog — NSLog is redacted under hardened runtime).

## Architecture (one file per concern)

| File | Role |
|---|---|
| `main.swift` | Entry point, spins up AppDelegate |
| `SiriRemoteApp.swift` | AppDelegate, wiring, `RCDControl` (disables macOS's rcd media-key daemon) |
| `MenuBarManager.swift` | Menu bar UI, `ButtonAction` enum, mapping persistence (UserDefaults keys `buttonMappings`, schema key `buttonMappingsSchema`) |
| `RemoteDetector.swift` | IOKit HID detection/seizure of the remote (product ID `0x266`) |
| `RemoteInputHandler.swift` | Raw HID button events → mapped actions; 200 ms debounce shared with MediaKeyInterceptor |
| `MediaKeyInterceptor.swift` | CGEvent tap catching AVRCP media keys (NX_SYSDEFINED path) |
| `MediaController.swift` | Synthesizes NX_SYSDEFINED media-key events |
| `TouchHandler.swift` | Trackpad via private MultitouchSupport: cursor, scroll, tap, swipe gestures |
| `CursorController.swift` | Posts mouse events |
| `SystemVolume.swift` | Volume get/set + `VolumeRevertGuard` |
| `RemoteMicController.swift` | A2854 push-to-talk orchestration: activate + capture + decode + selected engine |
| `RemoteMicLab.swift` | Minimal bundled-tool / paired-remote readiness |
| `TranscriptionEngine.swift` | Pluggable engine protocol + factory (OpenAI / Parakeet) |
| `OpenAITranscriptionEngine.swift` | WAV upload to OpenAI `/v1/audio/transcriptions` |
| `ParakeetTranscriptionEngine.swift` | FluidAudio Parakeet with menu-triggered lazy model download |
| `TranscriptionKeychain.swift` | OpenAI API key in Keychain |
| `CorpusRecorder.swift` | Opt-in dictation corpus capture (raw+processed WAV+JSON) for offline STT eval |
| `AudioFrontEnd.swift` | Pre-ASR audio conditioning (legacy peak-norm default; HPF+AGC experimental) — copy in tools/stt-eval must stay in sync |
| `VocabularyStore.swift` | User-editable CTC vocabulary boosting terms (vocabulary.json) |
| `tools/stt-eval/` | Non-shipping eval harness: Parakeet replay CLI + WER/latency scorer |
| `HCICaptureBootstrap.swift` | Bundled PacketLogger lookup + shell quoting |
| `MicCapturePipeline.swift` | Privileged PacketLogger HCI nhdr stream / offline replay |
| `OpusVoiceDecoder.swift` | A2854 Opus → 48 kHz PCM |
| `Vendor/FluidAudioDeps` | SPM wrapper to build/link FluidAudio (no model weights) |
| `MicActivator.swift` | Host-side `0xAF` / PushToTalk activation probes |

## Fragile invariants — do not "clean up"

- **Dual delivery paths.** Same physical press can arrive via HID (RemoteInputHandler) AND via AVRCP NX_SYSDEFINED (MediaKeyInterceptor). Both funnel through a 200 ms static debounce on `RemoteInputHandler` so the action fires once. Changing either path requires keeping the debounce.
- **NX_SYSDEFINED magic values.** Subtype 8, `data1 = (nxKeyCode << 16) | (keyState << 8)` (0xA down / 0xB up), modifierFlags `0xa00`/`0xb00`, and the `usleep(50_000)` between down/up in MediaController. All undocumented; consumers (Music.app) reject events without them.
- **Event tap placement.** MediaKeyInterceptor must be `.cghidEventTap` at `.headInsertEventTap` — session-level is too late. Tap re-enables on timeout/user-input disable and on wake.
- **HID seize** on connect prevents macOS double-dispatch (Music launching, system funk sound). Don't remove.
- **Stuck-key safety.** Push-to-talk holds must release on remote disconnect and self-heal on missed release events.
- **Mic arming is serialized, not synchronous.** `MicActivator` hops every entry point onto its own serial queue; `rearmOnSiriDown()` returns immediately. Ordering (a press's enable before its release's disable) is guaranteed by that queue — not by running on the press callback, which used to hold the main runloop for ~1.2 s and froze the dictation wave. Don't add a `pressGeneration` guard around the press-path rearm: that guard, not the async hop, is what once let a fast release drop the arm and capture no audio. `shutdown()` uses `disarmAndWait()` so quitting can't leave the mic armed.
- **Gesture trailing-space policy.** Slash commands that take an argument get a trailing space; standalone/picker commands don't. Gestures never send Enter.
- **Polish correction is generation-guarded.** Raw transcript types immediately; the async polish correction (backspace+retype in `MenuBarManager.replaceDictationText`) must only fire when `pressGeneration` is unchanged, no hold is active, and the toggle is on — otherwise it can delete user-typed characters. Don't reorder typing back behind polish.

## Conventions

- Remote HID identity lives in `RemoteAdapter` / `RemoteAdapterRegistry` (not a switch inside `RemoteInputHandler`). Add model-specific usages on the concrete adapter.
- User layouts are `MappingProfileStore` JSON profiles (mappings + trackpad + scroll + swipe gestures), not live UserDefaults `buttonMappings` after migration. Active profile is bound **per remote model** (`activeProfileByModel`) — A2540 and A2854 configs are isolated; selection in the menu binds only the connected model.
- Long-term direction: migrate primary input to Xbox Adaptive Joystick (public GameController.framework) — keep Siri Remote path best-effort.
