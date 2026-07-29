# dictation-vocabulary-boosting

## Purpose

Bias local recognition toward the user's real vocabulary — product names, code terms, slash commands — so domain words stop transcribing as sound-alikes ("Heidi" → "Haiti"), without retraining or new dependencies.

## Requirements

### Requirement: User-editable vocabulary

The vocabulary SHALL be a user-editable term list persisted on disk, where each term has a canonical form and optional aliases (recognized variants that output the canonical form). A default list SHALL ship with product and coding terms. Edits SHALL take effect without rebuilding the app.

#### Scenario: Term corrected to canonical form
- **WHEN** the user says a vocabulary term that the base model would transcribe as a sound-alike
- **THEN** the transcript contains the canonical form when the acoustic match clears the boosting threshold

#### Scenario: User adds a term
- **WHEN** the user adds a term to the list and dictates again
- **THEN** the new term participates in boosting on the next utterance without app restart

### Requirement: Opt-in boosting model download

Vocabulary boosting SHALL require an explicit one-time download of the CTC boosting model via the menu (never during packaging or app launch). While the model is absent or the feature is disabled, local recognition SHALL behave exactly as without this capability.

#### Scenario: Not downloaded
- **WHEN** boosting is enabled in the menu but the CTC model has not been downloaded
- **THEN** the menu offers the download, and dictation continues unboosted meanwhile

#### Scenario: Disabled
- **WHEN** the user disables boosting
- **THEN** transcription runs identically to the pre-boosting behavior

### Requirement: Boosting must fail open

Any failure in vocabulary boosting (model load error, spotting failure, timeout) SHALL fall back to the unboosted transcript for that utterance and log the failure; the user still gets their dictation.

#### Scenario: Boost failure
- **WHEN** the boosting stage throws during an utterance
- **THEN** the unboosted transcript is typed and the failure appears only in the diagnostic log

### Requirement: Local engine scope

Boosting SHALL apply to the local Parakeet path. Cloud engines are out of scope for this capability.

#### Scenario: Cloud engine unaffected
- **WHEN** the OpenAI engine is selected with boosting enabled
- **THEN** cloud transcription behavior is unchanged
