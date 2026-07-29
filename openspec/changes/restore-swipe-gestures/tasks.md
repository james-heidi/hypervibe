# Tasks: restore-swipe-gestures

## 1. Detection (TouchHandler)

- [x] 1.1 Restore flick detection from `48cc325^:TouchHandler.swift`: constants (0.35 distance fraction, 0.35 s, 2.0 axis ratio), `SwipeDirection` handling, `onSwipe` callback, swipe-suppresses-tap ordering, active regardless of trackpad-mouse mode.
- [x] 1.2 Verify two-finger scroll and tap paths untouched (code review against `1ab51e5` regression: trackpad swipes must not fire while trackpad-mouse dragging).

## 2. Actions + dispatch (MenuBarManager)

- [x] 2.1 Restore `SwipeDirection`/`SwipeAction` enums (minus PWA-only `remoteAction(for:)`), with `typedText`/`trailingSpace` policy as enum properties (argument commands get trailing space; never Enter).
- [x] 2.2 Restore `executeSwipe(_:)` dispatch: arrows → `sendKey`, modeSwitch → Shift+Tab, text actions → typing helper.
- [x] 2.3 Restore 「滑动手势」 submenu (four directions, direction-matched arrow filtered per submenu), reading/writing the active profile.

## 3. Profile persistence + per-model binding (MappingProfileStore)

- [x] 3.1 Add optional `swipeMappings: [String: String]?` to `MappingProfile`; nil resolves per bound model (A2540 → gesture-era defaults; A2854/unknown → none); old JSON decodes unchanged.
- [x] 3.2 Add `activeProfileByModel: [String: UUID]?` to `ProfileCatalog`; resolution order model-binding → legacy `activeProfileID`; legacy pointer seeds the binding for the connected model on first load.
- [x] 3.3 Model default seeding on first connect without binding: "A2540 默认" (gesture-era swipe config) / "A2854 默认" (current behavior); existing active profile keeps the A2854 binding.
- [x] 3.4 Profile CRUD/menu: selection writes the binding for the CONNECTED model only; show which model a binding belongs to where ambiguous.
- [x] 3.5 One-time migration: UserDefaults `swipeMappings` → bound profile when it has none; remove the key after.
- [x] 3.6 Confirm import/export round-trips new fields and old-build exports still import.

## 4. Wiring + verification

- [x] 4.1 `SiriRemoteApp`: `touchInputHandler.onSwipe = { menuBarManager.executeSwipe($0) }`.
- [x] 4.2 `./build.sh` clean; update AGENTS.md file-table note if needed (invariant already documented).
- [ ] 4.3 Manual matrix with A2540: four default swipes fire correct commands with correct trailing-space behavior; slow drag no-op; two-finger scroll unaffected; tap unaffected; remap a direction via menu and re-test; trackpad-mouse on → swipes still work, drags don't misfire.
- [ ] 4.4 Isolation matrix: connect A2854 → current profile unchanged, no swipe actions; edit A2540 profile → reconnect A2854 → unaffected; switch back to A2540 → gesture config intact.
