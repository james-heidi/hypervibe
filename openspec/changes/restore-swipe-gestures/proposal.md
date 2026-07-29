# Proposal: Restore trackpad swipe gestures (lost in the dictation rework)

## Why

Commit `48cc325` ("Make remote dictation durable and pluggable", 2026-07-27) deleted the trackpad swipe-gesture system while reworking dictation: TouchHandler's flick detection, the `SwipeAction` slash-command set, the 「滑动手势」 menu, and the default mappings (上=/usage, 下=/compact, 左=/model, 右=模式切换). AGENTS.md still documents its trailing-space invariant, but no code implements it. The user relied on these gestures daily on the A2540. Long-press key repeat (`holdCapableButtons`) survived and is not part of this change.

## What Changes

- **Restore flick detection** in TouchHandler (velocity-gated single-finger swipe, same thresholds as the deleted implementation) with the `onSwipe` callback.
- **Restore `SwipeAction`** (arrows, 模式切换 Shift+Tab, ultrathink, slash commands /btw /compact /config /context /effort /init /model /remote-control /schedule /tasks /usage, None) and its dispatch, including the trailing-space policy: argument-taking slash commands get a trailing space, standalone/picker commands don't, gestures never send Enter.
- **Integrate with today's structure instead of UserDefaults**: swipe mappings become part of `MappingProfile` (alongside mappings/trackpad/scroll), so they ride profiles, import/export, and migration. Old `swipeMappings` UserDefaults, if present, migrate once into the active profile.
- **Per-remote profile isolation**: each remote model (A2540 / A2854) keeps its own active profile. Switching remotes switches the effective layout without the two configs bleeding into each other.
- **Per-model defaults**: the A2854 default profile is exactly today's behavior (no swipe mappings pre-set — directions default to None but are configurable). The A2540 default profile ships the restored gesture-era configuration: 上=/usage, 下=/compact, 左=/model, 右=模式切换.
- 「滑动手势」 submenu restored, editing the profile active for the connected remote.

## Capabilities

### New Capabilities
- `trackpad-swipe-gestures`: single-finger flick gestures triggering configurable editor commands, persisted per mapping profile, with the gesture typing policy.
- `per-remote-profiles`: each remote model has its own active mapping profile and model-specific default seed.

### Modified Capabilities

(none — mapping profiles were never spec'd; both behaviors are specified in the new capabilities)

## Impact

- `TouchHandler.swift` (flick detection + `onSwipe`), `MenuBarManager.swift` (SwipeAction enum, 滑动手势 submenu, executeSwipe dispatch), `MappingProfileStore.swift` (`swipeMappings` field, tolerant decode for old profiles, one-time UserDefaults migration), `SiriRemoteApp.swift` (wiring), AGENTS.md (invariant already documented — code catches up).
- No new files, no engine/dictation-path changes.
- Reference implementation exists in git history (`48cc325^`); this is a restore-and-rehome, not a redesign.
