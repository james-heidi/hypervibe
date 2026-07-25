# Durable capture spike (A2854 remote mic)

**Date:** 2026-07-25  
**Host:** macOS with Bluetooth logging profile installed, PacketLogger available  
**Command:** `./HyperVibe --spike-durable`

## Verdict

**GATE: FAIL** — park consumer remote-mic. Keep HID Core (buttons/trackpad). Do **not** build a signed helper / HyperVibe Mic installer that still depends on PacketLogger + the temporary profile. Revisit only with extra hardware or a future Apple API.

## Spike A — private IOBluetooth receive

| Metric | Result |
|--------|--------|
| `IOBluetoothHostControllerDelegate` HCI events (live window) | 0 |
| A2854 Opus candidates inside those events | 0 |
| PacketLogger control frames (`/tmp/hypervibe-hci-siri.nhdr`) | **1146** |
| IOBluetooth receives voice | **false** |

Conclusion: PacketLogger can see continuous A2854 Opus on the wire; the private IOBluetooth event tap does not. Profile ON/OFF does not change that — there is no usable ACL receive API on this path.

Re-run:

```bash
./HyperVibe --spike-a 12
```

## Spike B — BTDebug / CoreCapture

| Metric | Result |
|--------|--------|
| `BTDebug` IOService | present |
| `IOServiceOpen(BTDebug)` | `0xe00002c2` (`kIOReturnBadArgument`) for types 0–3, 0x100 |
| `CCDataPipe` / `CCLogPipe` open | `0xe00002c7` (`kIOReturnUnsupported`) |
| HCI/ACL-capable CoreCapture pipe | **false** |
| BT-owned pipes observed | `StateDump` `CCDataPipe` size **64** only |

Conclusion: BTDebug exposes a tiny StateDump CoreCapture pipe, not a live HCI ACL stream. Opens fail without Apple’s private PacketLogger channel. No durable zero-hardware capture without PacketLogger + logging profile.

Re-run:

```bash
./HyperVibe --spike-b
```

## Product implications

1. **Consumer DMG:** remote mic stays a single disabled/gated toggle with a short “not ready” message — no wizard, no sudoers, no profile checklist.
2. **Developer Lab:** PacketLogger + temporary profile + BlackHole remains the only working path; keep under `docs/remote-mic.md` / scripts, not customer setup.
3. **Do not build next:** privileged helper that only wraps PacketLogger; branded AudioServerPlugIn alone (does not fix capture).
4. **Future unlocks:** companion BLE/USB hardware that owns the remote link, or an Apple-supported mic API.

## Code

- [`DurableCaptureSpike.swift`](../DurableCaptureSpike.swift) — probes
- [`HCIEventTap.swift`](../HCIEventTap.swift) — event tap + byte dump for Opus scan
- CLI: `--spike-a`, `--spike-b`, `--spike-durable`
