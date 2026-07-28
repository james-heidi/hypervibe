# Durable capture spike (A2854 remote mic)

**Date:** 2026-07-25  
**Host:** macOS with Bluetooth logging profile installed, PacketLogger available  

## Verdict

**GATE: FAIL** — park consumer remote-mic. Keep HID Core (buttons/trackpad). Do **not** build a signed helper / HyperVibe Mic installer that still depends on PacketLogger + the temporary profile. Revisit only with extra hardware or a future Apple API.

> **Update (2026-07-27):** verdict revisited. The `durable-capture-spike` branch ships
> the helper + PacketLogger path after hardening: the LaunchDaemon authenticates peers
> via `LOCAL_PEERCRED`, allow-lists the PacketLogger binary, owns its session paths, and
> restores Bluetooth prefs on teardown. Dictation degrades gracefully (Siri falls through
> to HID mapping) when prerequisites are missing. The original spike findings below are
> kept for the record. The obsolete spike implementation and CLI commands were removed
> after the production helper path shipped.

## Spike A — private IOBluetooth receive

| Metric | Result |
|--------|--------|
| `IOBluetoothHostControllerDelegate` HCI events (live window) | 0 |
| A2854 Opus candidates inside those events | 0 |
| PacketLogger control frames (`/tmp/hypervibe-hci-siri.nhdr`) | **1146** |
| IOBluetooth receives voice | **false** |

Conclusion: PacketLogger can see continuous A2854 Opus on the wire; the private IOBluetooth event tap does not. Profile ON/OFF does not change that — there is no usable ACL receive API on this path.

## Spike B — BTDebug / CoreCapture

| Metric | Result |
|--------|--------|
| `BTDebug` IOService | present |
| `IOServiceOpen(BTDebug)` | `0xe00002c2` (`kIOReturnBadArgument`) for types 0–3, 0x100 |
| `CCDataPipe` / `CCLogPipe` open | `0xe00002c7` (`kIOReturnUnsupported`) |
| HCI/ACL-capable CoreCapture pipe | **false** |
| BT-owned pipes observed | `StateDump` `CCDataPipe` size **64** only |

Conclusion: BTDebug exposes a tiny StateDump CoreCapture pipe, not a live HCI ACL stream. Opens fail without Apple’s private PacketLogger channel. No durable zero-hardware capture without PacketLogger + logging profile.

## Current outcome

The private IOBluetooth and BTDebug channels remain unsuitable. HyperVibe instead uses
the hardened helper + PacketLogger path described in [remote-mic.md](remote-mic.md).
