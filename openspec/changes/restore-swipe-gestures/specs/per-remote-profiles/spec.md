# per-remote-profiles

## Purpose

Each remote model keeps its own active mapping profile and model-specific defaults, so an A2540 and an A2854 configuration never bleed into each other when remotes are switched.

## ADDED Requirements

### Requirement: Per-model active profile

The effective mapping profile SHALL be resolved from the connected remote's model. Changing the active profile while one model is connected SHALL NOT change the profile bound to another model.

#### Scenario: Switching remotes switches layout
- **WHEN** an A2540 with profile X is disconnected and an A2854 bound to profile Y connects
- **THEN** buttons, trackpad, scroll, and swipe behavior follow profile Y

#### Scenario: Isolation of edits
- **WHEN** the user edits mappings while the A2540 is connected
- **THEN** the A2854's bound profile is unchanged

### Requirement: Model-specific default seeding

The first time a remote model connects with no bound profile, it SHALL be bound to a model default: the A2854 default SHALL preserve current behavior (existing profile binding is kept if one is already active; no swipe actions pre-set), and the A2540 default SHALL ship the gesture-era configuration including swipe defaults (up=/usage, down=/compact, left=/model, right=mode switch).

#### Scenario: Existing user unaffected on A2854
- **WHEN** a user with an existing active profile connects their A2854 after upgrading
- **THEN** that profile remains in effect unchanged

#### Scenario: A2540 first connect
- **WHEN** an A2540 connects for the first time with no bound profile
- **THEN** a model default profile with the gesture-era swipe configuration becomes active for it

### Requirement: Backward-compatible catalog

Profile catalogs written before per-model binding SHALL load without data loss; the legacy single active-profile pointer SHALL be honored as the initial binding for the currently connected model.

#### Scenario: Old catalog upgrade
- **WHEN** the app loads a catalog with only the legacy active-profile pointer
- **THEN** all profiles load and the legacy pointer seeds the binding for the connected model
