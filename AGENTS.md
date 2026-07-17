# HyperVibe — Agent Guide

macOS menu-bar app (Swift, AppKit) that turns a Siri Remote (1st-gen A1513) into an input device for Claude Code: buttons map to keys, trackpad swipes type slash commands, Siri button is push-to-talk. Fork of Remotastic.

## Build & Run

No Xcode project, no SwiftPM build (Package.swift exists but lacks the private framework — don't use it). All Swift files live flat in the repo root.

```bash
./build.sh              # single swiftc invocation → ./HyperVibe binary
./create_app_bundle.sh  # wraps binary into HyperVibe.app, ad-hoc codesigns with entitlements
open HyperVibe.app
```

- Adding a new .swift file: add it to BOTH `build.sh` (SWIFT_FILES) and `Package.swift` (sources).
- Requires macOS 11+, Xcode CLT. Links private `MultitouchSupport.framework` via `SiriRemote-Bridging-Header.h`.
- Needs Accessibility + Input Monitoring + Bluetooth TCC grants. Ad-hoc signing ties grants to binary hash — rebuilds may need re-approval.
- No tests. Verification is manual with a paired remote. Diagnostic log: `/tmp/hypervibe.log` (use `rmDebug()`, not NSLog — NSLog is redacted under hardened runtime).

## Architecture (one file per concern)

| File | Role |
|---|---|
| `main.swift` | Entry point, spins up AppDelegate |
| `SiriRemoteApp.swift` | AppDelegate, wiring, `RCDControl` (disables macOS's rcd media-key daemon) |
| `MenuBarManager.swift` | Menu bar UI, `ButtonAction`/`SwipeAction`/`SwipeDirection` enums, mapping persistence (UserDefaults keys `buttonMappings`, `swipeMappings`, schema key `buttonMappingsSchema`) |
| `RemoteDetector.swift` | IOKit HID detection/seizure of the remote (product ID `0x266`) |
| `RemoteInputHandler.swift` | Raw HID button events → mapped actions; 200 ms debounce shared with MediaKeyInterceptor |
| `MediaKeyInterceptor.swift` | CGEvent tap catching AVRCP media keys (NX_SYSDEFINED path) |
| `MediaController.swift` | Synthesizes NX_SYSDEFINED media-key events |
| `TouchHandler.swift` | Trackpad via private MultitouchSupport: cursor, scroll, tap, swipe detection |
| `CursorController.swift` | Posts mouse events |
| `SystemVolume.swift` | Volume get/set + `VolumeRevertGuard` |

## Fragile invariants — do not "clean up"

- **Dual delivery paths.** Same physical press can arrive via HID (RemoteInputHandler) AND via AVRCP NX_SYSDEFINED (MediaKeyInterceptor). Both funnel through a 200 ms static debounce on `RemoteInputHandler` so the action fires once. Changing either path requires keeping the debounce.
- **NX_SYSDEFINED magic values.** Subtype 8, `data1 = (nxKeyCode << 16) | (keyState << 8)` (0xA down / 0xB up), modifierFlags `0xa00`/`0xb00`, and the `usleep(50_000)` between down/up in MediaController. All undocumented; consumers (Music.app) reject events without them.
- **Event tap placement.** MediaKeyInterceptor must be `.cghidEventTap` at `.headInsertEventTap` — session-level is too late. Tap re-enables on timeout/user-input disable and on wake.
- **HID seize** on connect prevents macOS double-dispatch (Music launching, system funk sound). Don't remove.
- **Stuck-key safety.** Push-to-talk holds must release on remote disconnect and self-heal on missed release events.
- **Gesture trailing-space policy.** Slash commands that take an argument get a trailing space; standalone/picker commands don't. Gestures never send Enter.

## Conventions

- 2nd-gen remote (A2540) click-ring/Mute not yet mapped in `identifyButton` — superset HID codes probably cover the rest.
- Long-term direction: migrate primary input to Xbox Adaptive Joystick (public GameController.framework) — keep Siri Remote path best-effort.
