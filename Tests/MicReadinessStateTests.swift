import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MicReadinessStateTests {
    static func main() {
        testBackgroundChurnKeepsWave()
        testPressScopedStatesChangeChrome()
        testMenuLabels()
        print("MicReadinessStateTests: PASS")
    }

    /// Regression: during onboarding the helper is not installed yet, so capture
    /// warm-up cycles starting → missingTools → retry. The menu-bar icon used to
    /// flip between spinner and wave on every cycle.
    private static func testBackgroundChurnKeepsWave() {
        let background: [MicReadinessPresentationState] = [
            .warming(showHUD: false),
            .unavailable,
            .error("麦克风组件"),
            .releasedBeforeReady,
            .ready,
        ]
        for state in background {
            expect(state.statusItemChrome == .wave, "\(state) must keep the wave icon")
        }
    }

    private static func testPressScopedStatesChangeChrome() {
        expect(
            MicReadinessPresentationState.warming(showHUD: true).statusItemChrome == .spinner,
            "warm-up during a held press spins"
        )
        expect(
            MicReadinessPresentationState.recognizing.statusItemChrome == .spinner,
            "transcription spins"
        )
        expect(
            MicReadinessPresentationState.readyToSpeak.statusItemChrome == .microphone,
            "ready-to-speak shows the mic"
        )
        expect(
            MicReadinessPresentationState.listening.statusItemChrome == .waveform,
            "listening shows the waveform"
        )
    }

    private static func testMenuLabels() {
        expect(
            MicReadinessPresentationState.error("boom").menuLabel == "麦克风：boom",
            "error labels carry the detail"
        )
        expect(
            MicReadinessPresentationState.unavailable.menuLabel == "麦克风：不可用",
            "unavailable label"
        )
    }
}
