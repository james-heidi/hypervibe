# dictation-visual-feedback

## Purpose

Define what the global dictation HUD must show while push-to-talk is held, so the on-screen wave is a truthful, prompt indicator of whether the remote microphone is capturing and how loud the speaker is.

## Requirements

### Requirement: HUD appears within the press callback

On Siri-button down, the dictation HUD SHALL be visible with an animating wave before any blocking microphone-arming or capture-start work runs, and its first frame SHALL be committed to the window server during that same press callback.

#### Scenario: Cold capture stack on press
- **WHEN** the user presses the Siri button while the capture stack is idle and must be started
- **THEN** the HUD is already visible and animating before capture start begins

#### Scenario: Warm capture stack on press
- **WHEN** the user presses the Siri button while capture is already streaming
- **THEN** the HUD is visible and animating from the same press callback, with no intermediate blank or frozen pose

### Requirement: Wave animation never freezes while held

The wave SHALL keep animating continuously for the whole hold. No press-path work on the main thread — microphone arming, capture start, or utterance bookkeeping — SHALL produce a visible pause in the animation longer than 100 ms.

#### Scenario: Blocking arm work on the press path
- **WHEN** microphone arming or capture start occupies the main thread during a press
- **THEN** the wave continues to animate through that period

#### Scenario: Repeated presses
- **WHEN** the user presses and releases the Siri button several times in quick succession
- **THEN** each reveal shows a mid-animation wave, never a frozen phase-zero pose

### Requirement: Voice amplitude reacts as soon as audio arrives

The wave SHALL be armed for voice amplitude from the moment of Siri-down, so the first available audio level modulates the bars with no intervening state transition. At zero amplitude the armed wave SHALL render identically to the idle breathing baseline.

#### Scenario: First audio after press
- **WHEN** the first decoded audio level of an utterance becomes available
- **THEN** the wave amplitude responds to it without waiting for any further capture-state change

#### Scenario: Silence during hold
- **WHEN** the button is held and the speaker is silent
- **THEN** the wave shows the breathing baseline and does not collapse to flat bars

### Requirement: Amplitude reflects speech onset promptly

Measured from the moment the speaker's voice reaches the remote microphone, the wave SHALL begin visibly responding within 150 ms under a warm capture stack. Amplitude freshness SHALL be limited by audio transport, not by polling, buffering, or update-rate policy in the app or its privileged helper.

#### Scenario: Speaking immediately on press
- **WHEN** the user starts speaking at the instant of pressing the Siri button with capture already warm
- **THEN** the wave is visibly reacting to voice within 150 ms of speech onset

#### Scenario: Attributable delay
- **WHEN** dictation timing is inspected in the diagnostic log for a press
- **THEN** the log records HUD reveal, first capture bytes read, first decoded frame, and first published level, so any residual delay can be attributed to a specific stage

### Requirement: Amplitude represents all captured audio

Every decoded audio frame of the utterance SHALL contribute to the published amplitude. When frames arrive faster than the HUD update rate, the published level SHALL reflect the loudest energy in the elapsed window rather than a single arbitrarily selected frame.

#### Scenario: Burst arrival
- **WHEN** several audio frames are decoded together within one HUD update window
- **THEN** the published level reflects the loudest of those frames

#### Scenario: Loud transient
- **WHEN** a short loud syllable falls between two HUD update instants
- **THEN** the wave still shows a peak for it

### Requirement: Amplitude decay is continuous between updates

Between amplitude updates the wave SHALL decay smoothly and SHALL NOT visibly collapse toward the baseline while continuous speech is still arriving. Attack SHALL be at least as fast as decay.

#### Scenario: Continuous speech
- **WHEN** the user speaks continuously through a hold
- **THEN** the bars stay elevated and modulate, without a per-update stutter between elevated and baseline

#### Scenario: Speech stops mid-hold
- **WHEN** the user stops speaking while still holding the button
- **THEN** the bars settle back to the breathing baseline smoothly
