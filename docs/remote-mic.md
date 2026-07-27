# A2854 remote dictation (internal prototype)

## Product status (2026-07-27)

The internal build packages a locally installed Apple PacketLogger and turns the Siri Remote microphone into push-to-talk dictation with **pluggable transcription engines**:

1. Choose a transcription engine in the menu bar submenu.
2. Approve the one-time administrator prompt for the HCI helper.
3. Hold Siri, speak, release. HyperVibe types the final transcript into the focused app.

There is no BlackHole install, temporary Bluetooth profile, sudoers edit, or system audio-input selection.

## Transcription engines

| Engine | When used | Notes |
|--------|-----------|-------|
| **OpenAI** | High-quality cloud | Uploads a temp WAV to `/v1/audio/transcriptions`. API key in Keychain. Default model `gpt-4o-mini-transcribe`. |
| **Parakeet 本地** | Default / offline Apple Silicon | FluidAudio + NVIDIA Parakeet CoreML. **Models download only when the user selects this engine** — never during DMG packaging. |

### Menu UX

- The engine submenu lists OpenAI / Parakeet.
- OpenAI shows `（需 Key）` until a key is saved; **设置 OpenAI API Key…** writes to Keychain.
- Parakeet shows `（下载…）` until cached; selecting it starts a progress download (`下载中 N%`). Cancelable.
- Status line includes the active engine, e.g. `采集中 · OpenAI · 识别中`.

## Paid cloud ASR benchmark (research)

Approximate 2026 batch pricing for short push-to-talk clips. Independent WER numbers vary by dataset — treat as directional.

| Provider | Model | Approx batch price | Fit for HyperVibe |
|----------|-------|--------------------|-------------------|
| OpenAI | `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` | ~$0.18–$0.36/hr | **Shipped in v1** — simple upload API, strong multilingual |
| OpenAI | `whisper-1` | ~$0.36/hr | Selectable fallback model id |
| Deepgram | Nova-3 | ~$0.26/hr batch, ~$0.46/hr stream | Best second cloud candidate (English / low latency) |
| AssemblyAI | Universal-2 / 3 | ~$0.15–$0.21/hr | Cheap + feature-rich; good third candidate |
| Google Chirp 3 | Speech-to-Text v2 | ~$0.18/hr dynamic batch; real-time higher | Broad multilingual enterprise option |
| Azure Speech | Standard | ~$1.00/hr list | Enterprise lock-in; lower priority |
| Amazon Transcribe | Standard | ~$1.44/hr list | Same |
| Groq / Fireworks | Whisper large-v3 hosts | often ~$0.02–$0.10/hr | Cheap Whisper hosting; quality ≈ Whisper, not GPT-4o |
| ElevenLabs | Scribe | ~$0.22/hr | Interesting quality competitor; API maturity TBD |

**v1 ships OpenAI only** among paid engines. Deepgram / AssemblyAI / Google / Groq remain candidates for a later engine slot.

## One-shot HCI helper

Capture no longer prompts for an administrator password on every Siri press.

1. Menu → **安装麦克风组件（一次性）…** (also offered the first time you enable the remote mic).
2. Enter the Mac password once. HyperVibe installs `com.hypervibe.hcihelper` as a LaunchDaemon.
3. Later captures talk to `/var/run/com.hypervibe.hci.sock` and start PacketLogger without another password prompt.

Uninstall is available from the same menu item after install.

## Build

Install PacketLogger at `/Applications/PacketLogger.app`, then:

```bash
./build.sh
./create_app_bundle.sh
./HyperVibe.app/Contents/MacOS/HyperVibe --mic-check
```

`./build.sh` compiles FluidAudio from `Vendor/FluidAudioDeps` (library only). It does **not** download Parakeet model weights. Models appear under FluidAudio’s Application Support cache after the user selects Parakeet in the menu.

Set `PACKETLOGGER_APP=/another/path/PacketLogger.app` when packaging from another location. PacketLogger is copied only into the ignored generated app bundle; it is not committed to git.

## Runtime pipeline

1. A LaunchDaemon helper (installed once) backs up `com.apple.MobileBluetooth.debug`.
2. On each capture it temporarily enables live HCI traces and `HCISkipAuth`, reloads `bluetoothd`, and starts bundled PacketLogger.
3. HyperVibe tails PacketLogger's nhdr stream, reassembles A2854 reports, and decodes Opus to 48 kHz mono PCM.
4. PCM is fed to the selected `TranscriptionEngine` (Apple buffer / OpenAI WAV upload / Parakeet file transcribe).
5. On Siri release, the final transcript is posted as Unicode keyboard input.
6. Disabling the feature or quitting removes a liveness token; the privileged shell stops PacketLogger and restores the previous Bluetooth preferences.

The historical durable-capture spike remains documented in [spike-durable-capture.md](spike-durable-capture.md).

## Protocol notes

| Offset | Field |
|--------|-------|
| 0..1 | unused |
| 2..3 | sequence (u16 LE) |
| 4 | Opus length L |
| 5..5+L | Opus frame |
