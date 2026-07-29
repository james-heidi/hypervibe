# Design: restore-swipe-gestures

## Context

See proposal.md — Why. Reference implementation at `48cc325^` (verified in history):
- `TouchHandler.swift`: flick thresholds `swipeMinDistance=0.35` (fraction of pad), `swipeMaxDuration=0.35s`, `swipeAxisRatio=2.0`; `onSwipe: ((SwipeDirection) -> Void)?`; tap suppression after swipe.
- `MenuBarManager.swift` (pre-rework): `SwipeDirection`, `SwipeAction` enums (raw values are the typed text), `defaultSwipeMappings` (up=/usage, down=/compact, left=/model, right=modeSwitch), 「滑动手势」 submenu, `executeSwipe` with the trailing-space table.
- Old persistence: UserDefaults `swipeMappings` — superseded today by `MappingProfileStore` (JSON profiles: mappings + trackpad + scroll; tolerant decode; `schema: 1`).

Current structure to preserve: profiles own user layout (`MappingProfileStore.swift:27` `MappingProfile`), adapters own HID identity, `MenuBarManager` owns menu + dispatch, typing goes through the same CGEvent helpers as dictation.

## Goals / Non-Goals

**Goals**
- Behavior-identical restore of detection, action set, defaults, and typing policy.
- Persistence rehomed into `MappingProfile` — no parallel UserDefaults store.

**Non-Goals**
- No iPhone PWA external-action restore (also deleted in `48cc325`; separate decision).
- No new gestures (multi-finger, corners) and no changes to hold-repeat.
- No per-adapter detection differences (same touch surface); only defaults and active-profile binding differ per model.

## Decisions

**D1 — Copy the old detection verbatim into today's TouchHandler.**
Same three constants, same axis-dominance rule, same "swipe suppresses tap" ordering. It worked; do not retune. Swipe detection stays active when trackpad-mouse mode is off (matching the old `Keep the touch device running so swipe commands continue to work` behavior).

**D2 — `SwipeAction` returns as a top-level enum in `MenuBarManager.swift`** (where it lived), including raw-value stability for persistence. Drop `remoteAction(for:)` (PWA-only). Typing goes through `typeDictationText`-adjacent helpers; the trailing-space table is a `SwipeAction` property so the policy is in one place.

**D3 — Persistence: `swipeMappings: [String: String]?` on `MappingProfile`.**
Optional field → old profile JSON decodes untouched (tolerant decode requirement). nil resolves per model: A2540-bound profiles fall back to the gesture-era defaults, A2854-bound (and unknown) to None-per-direction. Migration: on load, if UserDefaults `swipeMappings` exists and the bound profile has none, copy in once and remove the defaults key. Alternative — separate swipe store: rejected, profiles exist precisely to bundle layout state.

**D4b — Per-remote profile binding.**
`ProfileCatalog` gains `activeProfileByModel: [String: UUID]?` (keyed by `RemoteModel.rawValue`); legacy `activeProfileID` stays as fallback so old catalogs decode and old builds still read something sensible. Resolution: connected adapter's model → bound profile id → profile; unbound model binds on first connect to a freshly seeded model default profile ("A2540 默认" with gesture-era swipe defaults; "A2854 默认" cloned from today's default behavior — the user's existing profile stays the A2854 binding if one is already active). Profile CRUD is unchanged — profiles remain one shared pool; only the *active* pointer is per-model. Alternative — partition profiles per model: rejected, breaks existing import/export and duplicates identical layouts.

**D4 — Menu: 「滑动手势」 submenu mirroring the old one** (four directions, sticky choices from `SwipeAction.allCases`, direction-matched arrow filtered per submenu as before), writing through `MappingProfileStore` so edits land on the active profile.

## Risks / Trade-offs

- [Swipe fires during trackpad-mouse dragging] → old implementation already gated tap-vs-swipe and multi-finger; restore its ordering untouched; manual matrix re-checks drag + two-finger scroll (the `1ab51e5` regression class).
- [Slash-command set drifts from Claude Code] → raw values are just typed text; stale commands are harmless and editable; not spec'd as a live list.
- [Profile schema change breaks import of new exports into old builds] → optional field is ignored by tolerant decoders; schema stays 1.

## Migration Plan

Additive field + one-time UserDefaults migration. Rollback: revert commit; profiles with the extra field still decode in older code (tolerant decode). No data loss either way.

## Open Questions (updated)

- Whether 长按 refers to anything beyond the surviving hold-repeat (e.g. long-press-Siri variants). If something else is missed, it's a separate restore change — this one is scoped to swipes.
