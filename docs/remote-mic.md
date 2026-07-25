# A2854 remote microphone (zero extra hardware)

HyperVibe can use the **physical microphone** on a 3rd-gen Siri Remote (A2854, product `0x0315`) without a USB Bluetooth dongle.

macOS does not expose the remote as a CoreAudio input. HyperVibe therefore:

1. Arms host activation (`0xAF` Feature writes + `PushToTalk` property probe) on Siri hold
2. Sniffs BLE HCI with Apple **PacketLogger** (Additional Tools for Xcode)
3. Parses A2854 Opus frames (99-byte payload, TOC often `0xB8`)
4. Decodes to 48 kHz mono PCM
5. Plays into **BlackHole 2ch**, which apps select as their microphone

## One-time setup

```bash
./scripts/setup_remote_mic.sh
```

You must be signed into [Apple Developer](https://developer.apple.com):

1. Install **Bluetooth_macOS.mobileconfig**, finish in **System Settings → Privacy & Security → Profiles**, reboot
2. Download **Additional Tools for Xcode**, copy `Hardware/PacketLogger.app` to `/Applications`
3. Install **BlackHole 2ch** (the setup script uses Homebrew) and reboot if the device is not listed
4. Optional passwordless PacketLogger:

```text
%admin ALL=(root) NOPASSWD: /Applications/PacketLogger.app/Contents/Resources/packetlogger
```

## Build / run

```bash
./build.sh
./create_app_bundle.sh
open HyperVibe.app
```

Menu bar:

- **远程麦克风 (A2854 → BlackHole)** toggle
- Status line shows PacketLogger / streaming / BlackHole state

Hold **Siri**, speak, release. In VoiceInk / Voice Memos / Claude dictation, set input to **BlackHole 2ch**.

## Diagnostics

```bash
./HyperVibe --mic-check
./HyperVibe --activate-mic
./HyperVibe --test-opus /tmp/a2854_frame.hex
./HyperVibe --test-blackhole
./HyperVibe --replay-hci /tmp/fake-hci-siri.nhdr
./HyperVibe --capture-mic 15
./scripts/capture_hci_siri.sh
```

Logs: `/tmp/hypervibe.log`  
Last utterance dump: `/tmp/hypervibe-remote-mic.wav`

## Protocol notes

A2854 mic report (Linux `0xFA` / ATT notify ~100 bytes):

| Offset | Field |
|--------|--------|
| 0..1 | unused |
| 2..3 | sequence (u16 LE) |
| 4 | Opus length L |
| 5..5+L | Opus frame |

Activation on Linux is GATT write `0xAF` plus CCCD subscribe. macOS rewrites report IDs and hides HOGP GATT from CoreBluetooth; PacketLogger is required to observe (and eventually drive) the wire path.

## Limits

- Requires temporary Apple Bluetooth logging profile (typically ~3 days)
- PacketLogger needs root for live HCI
- If the remote never emits Opus frames after activation probes, capture will stay on “等待语音帧” — that is an activation problem, not a decoder problem
