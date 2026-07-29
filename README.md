<img src="banner.png" alt="HyperVibe — a walkie-talkie for Claude Code">

# HyperVibe V0.1

One-handed vibe coding using Apple TV remote, customizable buttons and gestures.

Grab a remote, push to talk, and vibe-code with Claude Code without breaking flow.

<img src="demo.gif" alt="HyperVibe demo" width="70%">

Tested with the 1st-gen Siri Remote (Model A1513). Support for Xbox Adaptive Joystick coming soon.

> **Experimental release.** For now, HyperVibe ships as an experiment — there is no pre-built binary. You'll have to build the app bundle yourself (see [Building](#building)). Your mileage may vary.

---

## Features

### Buttons

Each physical Siri Remote button is independently assignable via the menu bar.

<img src="siri-remote-button-mapping-default.png" alt="Default Siri Remote button mapping" width="50%">

<img src="screenshot-button-mapping.png" alt="Button Mappings menu screenshot" width="70%">

**Default Button Mapping (Customizable):**
- Play/Pause → Esc
- Menu (返回) → Command + Backspace
- Trackpad click → Enter
- Direction ring → Arrow keys
- Volume Up / Down → System volume
- Mute → System mute
- TV → Ctrl + C
- Siri → Hold for remote dictation (not remapped)

| Action | Behavior |
|---|---|
| Play/pause button | Esc |
| Menu button | Command + Backspace (delete line) |
| Trackpad click | Enter (submit prompt) |
| Direction ring | Arrow keys |
| Volume up / down | System volume |
| Mute | System mute |
| TV button | Recover last dictation |
| Siri/mic button | Hold to dictate via OpenAI / Parakeet |

**Hold-Capable Buttons:** Push-to-talk actions require buttons that emit both press and release HID events. Only Play/Pause, Volume Up, Volume Down, and Siri buttons allow for both events. Also this button can trigger right command or option key for other dictation apps like [VoiceInk](https://github.com/Beingpax/VoiceInk).

**Recover last dictation:** Press the TV button by default, or map another button to “恢复上次语音”. Retypes the last polished text when available; otherwise resumes interrupted audio (~30s in memory, cleared on quit).


### Trackpad Inputs

- **Cursor movement** via single-finger drag
- **Two-finger scroll** (natural-scroll direction, configurable scale)
- **Tap-to-click** on the trackpad surface
- **Drag** by holding the trackpad click and moving

### Persistence

Named **配置档** (profiles) store button mappings, trackpad-mouse enablement, and scroll speed as JSON under `~/Library/Application Support/HyperVibe/profiles.json`. Existing UserDefaults mappings migrate once into a profile named **默认**. Use the menu-bar **配置档** submenu to create, rename, duplicate, delete, import, and export profiles (single profile or full catalog JSON).

### Remote adapters

HID page/usage decoding is per remote model (`RemoteAdapter`: A2540, A2854, legacy/unknown). Product IDs and identify tables live in the adapter registry; shared code only sees logical buttons (`menu`, `tv`, `ringUp`, …).

When a remote is connected, the top row of the menu-bar dropdown shows the active model directly (e.g. `✅ A2854`), so you can tell which adapter — and therefore which button layout and defaults — is in effect. It reads `未连接` when no remote is paired.

### Safety

- **Stale-hold self-heal.** If a release HID event is ever missed, the next press closes the stale hold before opening a new one.
- **HID seize.** On connect, HyperVibe seizes the remote at the HID level so macOS no longer also sees media key events from it — no double-dispatch (e.g., to iTunes/Music), no system funk sound on unhandled keys.

---

## Building

### Prerequisites

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools: `xcode-select --install`

### Build

```bash
./build.sh
```

This runs a single `swiftc` invocation over all the project's Swift files, linking IOKit, CoreGraphics, AudioToolbox, Carbon, AppKit, and the private MultitouchSupport framework via a bridging header. No Xcode project is required.

---

## Installing and Running

1. Build and bundle: `./build.sh && ./create_app_bundle.sh`
2. Move `HyperVibe.app` to `/Applications` (recommended so TCC grants stick across rebuilds; prefer signing with **HyperViabe Dev**)
3. Launch it (`open /Applications/HyperVibe.app`)
4. Complete the **3-step install wizard** (or menu bar → **安装**):
   - **Accessibility** — post keyboard/mouse events
   - **Input Monitoring** — read HID / media-key events
   - **Voice helper** — privileged HCI capture component (admin password once)
5. Pair the Siri Remote via **System Settings → Bluetooth** if it isn't already paired
6. Use the menu-bar icon for Button Mappings, dictation engine, and the optional Hugging Face mirror
7. **Internal remote dictation:** build packaging copies `/Applications/PacketLogger.app` into HyperVibe. Pick an engine (OpenAI / Parakeet), then hold Siri to speak and release to type into the focused app. Parakeet download shows real phase progress (bytes → compile → ready) and can pause/resume; mirrors are opt-in only. See [docs/remote-mic.md](docs/remote-mic.md).

> ⚠️ **Important:** Prefer launching the signed app from `/Applications/HyperVibe.app`. Re-signing with a different identity invalidates Accessibility / Input Monitoring grants and looks like “dictation finished but no text typed.”

A diagnostic log is written to `/tmp/hypervibe.log` (NSLog is redacted under hardened runtime, so HyperVibe uses file-based logging).

---

### Why two paths for the same button?

A physical Siri Remote press can arrive two ways:

1. **HID (seized)** — `RemoteInputHandler` reads raw HID input.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media-key events `MediaKeyInterceptor` catches via an event tap.

Both paths converge on the same button mapping through a 200 ms debounce (static `lastProcessedButton`/`lastProcessedTime` on `RemoteInputHandler`), so a press fires the mapped action exactly once regardless of which path delivers it first.

### The NX_SYSDEFINED hack (media keys)

macOS has no public API for synthesizing or intercepting media keys (Play/Pause, Next, Previous, Volume, Mute). Both `MediaKeyInterceptor` and `MediaController` rely on the same undocumented `NSSystemDefined` event format used internally by the Human Interface Device stack:

- **Event type** `NX_SYSDEFINED` (raw value `14`) with **subtype `8`**.
- **Key code and state packed into `data1`** as a bitfield: `(nxKeyCode << 16) | (keyState << 8)`, where `0xA` = key down and `0xB` = key up.
- **Magic `modifierFlags`** (`0xa00` for down, `0xb00` for up) mirror the state nibble — real media key events arrive with these flags, and some consumers (e.g. Music.app) won't accept posted events without them.

`MediaKeyInterceptor` installs a **`.cghidEventTap`** at `.headInsertEventTap` so it sees `NX_SYSDEFINED` events *before* the system dispatcher routes them to Music/iTunes/etc. — a session-level tap would arrive too late. It then manually unpacks `data1` to recover the key code and down/up state. The tap is automatically re-enabled on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification`, because macOS silently disables event taps across sleep/wake and input stalls.

`MediaController` goes the other way: it **fabricates** matching `NSSystemDefined` events via `NSEvent.otherEvent(...)` with the same magic flags, subtype, and `data1` packing, then posts the underlying `CGEvent` to the session tap. A **`usleep(50_000)`** gap between the down and up events is required — without the 50 ms pause, macOS coalesces or drops the pair and the media key is ignored.

This is the standard reverse-engineered technique (originally surfaced in projects like SPMediaKeyTap and Noteify), but it is entirely undocumented and can change without notice in any macOS release.

---

## Caveats

- Uses Apple's **private `MultitouchSupport` framework** — not App Store compatible; Apple may change or remove this API in future macOS releases.
- **NX_SYSDEFINED media-key synthesis and interception is undocumented** — relies on magic modifier-flag values (`0xa00`/`0xb00`), subtype `8`, and a manual `data1` bitfield layout. Apple could break this in any release.

### Long-term direction: Xbox Adaptive Joystick

Between the private `MultitouchSupport` framework and the undocumented `NX_SYSDEFINED` plumbing, the Siri Remote path is built on two proprietary, reverse-engineered interfaces that Apple can break at any time. HyperVibe may migrate its primary input to the **Xbox Adaptive Joystick**, which speaks standard USB HID / GameController.framework and avoids every proprietary hazard above. That gives a more permanent, App Store–viable foundation — and, as a bonus, a genuinely accessible input device — while the Siri Remote support remains as a best-effort path for users who already own one.
- Tested on **Siri Remote 1st-gen (A1513, product ID `0x266`)** and **2nd-gen (A2540, `0x0314`) / USB-C (A2854, `0x0315`)**. Per-model adapters share a HID table today; diverge in `RemoteAdapter` when a usage differs.
- Ad-hoc signing ties TCC permission grants to the exact binary hash — rebuilds may require re-approval in System Settings.

---

## Credits

 **Fork & improvements.** HyperVibe is built on top of [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue), which provided the foundational Siri-Remote HID handling, MultitouchSupport integration, and menu-bar scaffolding. HyperVibe extends it with configurable Claude Code workflows, keyboard shortcuts, and push-to-talk dictation.
- Icons from [The Noun Project](https://thenounproject.com/):
  - [Arrow Up by Dayeong Kim](https://thenounproject.com/icon/arrow-up-6066125/)
  - [Microphone by Alvida](https://thenounproject.com/icon/microphone-8162320/)
  - [Radio by Kiran Shastry](https://thenounproject.com/icon/radio-2338991/)
