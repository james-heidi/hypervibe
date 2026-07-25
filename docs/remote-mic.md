# A2854 remote microphone (developer / parked)

## Product status (2026-07-25)

**Consumer remote-mic is parked.** A durable capture spike found no zero-hardware path that avoids Apple’s PacketLogger + temporary Bluetooth logging profile.

See [spike-durable-capture.md](spike-durable-capture.md).

| Audience | What to expect |
|----------|----------------|
| **Customers** | Buttons / trackpad work. Menu **遥控器麦克风** stays off or shows a short “not ready” message. |
| **Developers** | Lab path below still works on a machine with PacketLogger, profile, BlackHole, and root. |

Do **not** invest in customer installers, sudoers packaging, or Lab wizards until capture no longer depends on PacketLogger/profile.

## Lab path (developers only)

macOS does not expose the Siri Remote mic as a CoreAudio input. The Lab pipeline is:

1. Arm host activation (`0xAF` Feature writes + `PushToTalk`) on Siri hold  
2. Sniff BLE HCI with Apple **PacketLogger** (`convert -s -f nhdr`)  
3. Parse A2854 Opus frames (99-byte payload, TOC often `0xB8`)  
4. Decode to 48 kHz mono PCM  
5. Play into **BlackHole 2ch**

```bash
./scripts/setup_remote_mic.sh
./build.sh
./HyperVibe --mic-check
./HyperVibe --capture-mic 15
```

Limits: ~3-day Bluetooth logging profile, PacketLogger root, BlackHole install, manual input selection in dictation apps.

## Durable spike CLI

```bash
./HyperVibe --spike-a 12
./HyperVibe --spike-b
./HyperVibe --spike-durable 12
```

## Protocol notes

| Offset | Field |
|--------|--------|
| 0..1 | unused |
| 2..3 | sequence (u16 LE) |
| 4 | Opus length L |
| 5..5+L | Opus frame |
