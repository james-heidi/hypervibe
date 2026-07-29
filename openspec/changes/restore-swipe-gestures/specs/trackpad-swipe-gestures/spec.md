# trackpad-swipe-gestures

## Purpose

Single-finger flick gestures on the remote's touch surface trigger configurable editor commands (slash commands, mode switch, arrows), so frequent Claude Code actions need no button dedication.

## ADDED Requirements

### Requirement: Flick detection

A fast single-finger swipe on the touch surface SHALL be detected as a directional gesture (up/down/left/right) when it exceeds a distance threshold within a short duration and is clearly axis-dominant. A detected swipe SHALL NOT also register as a tap, and multi-finger gestures (e.g. two-finger scroll) SHALL NOT trigger swipe actions. Swipe detection SHALL work whether or not trackpad-mouse mode is enabled.

#### Scenario: Flick fires once
- **WHEN** the user flicks one finger upward quickly across the touch surface
- **THEN** exactly one up-swipe action executes and no tap or click is synthesized

#### Scenario: Slow drag is not a swipe
- **WHEN** the user moves a finger the same distance slowly
- **THEN** no swipe action executes

#### Scenario: Two-finger scroll unaffected
- **WHEN** the user performs a two-finger scroll
- **THEN** scrolling behaves as before and no swipe action executes

### Requirement: Configurable per-direction actions

Each swipe direction SHALL map to a user-configurable action from a fixed set including: arrow keys, mode switch (Shift+Tab), the keyword "ultrathink", the supported slash commands, and None. Mappings SHALL be editable from the menu and take effect immediately.

#### Scenario: Remap a direction
- **WHEN** the user changes the left-swipe action in the menu
- **THEN** the next left swipe executes the new action without restart

### Requirement: Gesture typing policy

Slash commands that take an argument SHALL be typed with a trailing space; standalone/picker commands SHALL be typed without one. Gestures SHALL never send Enter.

#### Scenario: Argument command
- **WHEN** a swipe mapped to an argument-taking slash command fires
- **THEN** the command text plus one trailing space is typed and Enter is not sent

#### Scenario: Picker command
- **WHEN** a swipe mapped to a standalone/picker slash command fires
- **THEN** the command text is typed without trailing space and Enter is not sent

### Requirement: Profile persistence and defaults

Swipe mappings SHALL be stored in the mapping profile (with button mappings, trackpad, and scroll settings) so they follow profile switching and import/export. Profiles without swipe mappings SHALL resolve to the model default of the remote they are bound to: the gesture-era set (up=/usage, down=/compact, left=/model, right=mode switch) for A2540, no actions for A2854. Legacy swipe mappings stored in UserDefaults, if present, SHALL migrate once into the bound profile.

#### Scenario: Defaults on old profile
- **WHEN** a profile saved before this capability is loaded
- **THEN** swipes use the bound model's default set and the profile is otherwise unchanged

#### Scenario: Profile switch
- **WHEN** the user switches to a profile with different swipe mappings
- **THEN** subsequent swipes use that profile's mappings

#### Scenario: Legacy migration
- **WHEN** the app launches with old UserDefaults `swipeMappings` present and no profile-level swipe mappings
- **THEN** the values migrate into the active profile once and behave as before
