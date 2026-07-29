import Foundation
import FluidAudio

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ModelPreparationTests {
    static func main() {
        testBytesOccupyTheFirstBand()
        testDownloadPhaseWeightIsNormalized()
        testETAEstimateNeedsRealProgress()
        testCompileOccupiesTheTailBand()
        testFractionNeverExceedsOne()
        testDownloadLabelCarriesRateAndETA()
        testNonDownloadLabels()
        testETAFormatting()
        testMirrorRawValuesAreRegistryHosts()
        testMirrorRoundTripsThroughDefaults()
        testThrottleSuppressesChatter()
        testThrottleHeartbeatRefreshesStuckPercent()
        print("ModelPreparationTests: PASS")
    }

    // MARK: - Progress mapping

    private static func testBytesOccupyTheFirstBand() {
        expect(ModelPrepProgress.fromDownloadFraction(0).fraction == 0, "no bytes means no progress")
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(0.5).fraction - 0.425) < 1e-9,
            "half the bytes is half of the 0…0.85 band"
        )
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(1.0).fraction - 0.85) < 1e-9,
            "all bytes downloaded stops at 0.85 so compiling still has room"
        )
        // Callers forward whatever FluidAudio reports, including out-of-range values.
        expect(ModelPrepProgress.fromDownloadFraction(-0.5).fraction == 0, "negative fractions clamp to 0")
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(4.2).fraction - 0.85) < 1e-9,
            "overshooting fractions clamp to the band ceiling"
        )

        let progress = ModelPrepProgress.fromDownloadFraction(0.2, filesCompleted: 2, filesTotal: 7)
        expect(progress.phase == .downloading(files: 2, total: 7), "file counters ride along with the phase")
    }

    /// Regression: `ModelHub.download` only reports the download half of its own
    /// operation, so its handler tops out at 0.5. Forwarding that fraction raw
    /// squeezed the whole download into 0…42% and the menu read "下载中 0%" for
    /// the first tens of megabytes.
    private static func testDownloadPhaseWeightIsNormalized() {
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(0.5, phaseWeight: 0.5).fraction - 0.85) < 1e-9,
            "a finished ModelHub download fills the whole byte band"
        )
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(0.25, phaseWeight: 0.5).fraction - 0.425) < 1e-9,
            "half a ModelHub download is half the byte band"
        )
        expect(
            ModelPrepProgress.fromDownloadFraction(0.05, phaseWeight: 0.5).menuLabel.contains("8%"),
            "early bytes report a moving percent instead of sticking at 0%"
        )
        expect(
            abs(ModelPrepProgress.fromDownloadFraction(0.4, phaseWeight: 0).fraction - 0.34) < 1e-9,
            "a zero weight cannot divide the fraction away"
        )
    }

    private static func testETAEstimateNeedsRealProgress() {
        expect(ModelPrepProgress.estimateETA(fraction: 0.0, elapsed: 10) == nil, "no progress means no estimate")
        expect(ModelPrepProgress.estimateETA(fraction: 0.5, elapsed: 0.2) == nil, "too early to extrapolate")
        expect(ModelPrepProgress.estimateETA(fraction: 1.0, elapsed: 10) == nil, "a finished download has no ETA")
        expect(
            ModelPrepProgress.estimateETA(fraction: 0.5, elapsed: 10) == 10,
            "halfway after 10s means about 10s left"
        )
        expect(
            ModelPrepProgress.estimateETA(fraction: 0.25, elapsed: 10) == 30,
            "a quarter after 10s means about 30s left"
        )
    }

    /// The percent stalls for minutes on Parakeet's one huge encoder file, so the
    /// throttle must still let the ETA refresh or the menu looks frozen.
    private static func testThrottleHeartbeatRefreshesStuckPercent() {
        let throttle = ModelProgressThrottle()
        let progress = ModelPrepProgress.fromDownloadFraction(0.10, filesCompleted: 1, filesTotal: 7)
        expect(throttle.shouldPublish(progress), "the first update always publishes")
        expect(!throttle.shouldPublish(progress), "an identical update inside the window is dropped")
        Thread.sleep(forTimeInterval: 1.05)
        expect(throttle.shouldPublish(progress), "the heartbeat republishes an unchanged percent")
    }

    private static func testCompileOccupiesTheTailBand() {
        let first = ModelPrepProgress.compiling(name: "encoder", step: 0, total: 4)
        let mid = ModelPrepProgress.compiling(name: "decoder", step: 2, total: 4)
        let last = ModelPrepProgress.compiling(name: "joint", step: 4, total: 4)
        expect(abs(first.fraction - 0.85) < 1e-9, "compiling starts where bytes ended")
        expect(first.fraction < mid.fraction && mid.fraction < last.fraction, "compile progress is monotonic")
        expect(last.fraction <= 1.0, "compile progress never exceeds 1")
        expect(mid.phase == .compiling("decoder"), "the compiling model name is carried for the label")
        expect(
            ModelPrepProgress.compiling(name: "single", step: 0, total: 0).fraction <= 1.0,
            "an unknown compile step count does not overflow"
        )
    }

    private static func testFractionNeverExceedsOne() {
        expect(ModelPrepProgress.warmup.fraction <= 1.0, "warmup stays within range")
        expect(ModelPrepProgress.warmup.fraction > 0.85, "warmup is past the byte band")
        expect(ModelPrepProgress.paused.phase == .paused, "paused is its own phase")
    }

    // MARK: - Labels

    private static func testDownloadLabelCarriesRateAndETA() {
        let progress = ModelPrepProgress(
            phase: .downloading(files: 3, total: 7),
            fraction: 0.425,
            bytesPerSecond: 5_000_000,
            etaSeconds: 90
        )
        let label = progress.menuLabel
        expect(label.contains("42%"), "download label shows a floor-rounded percent, got \(label)")
        expect(label.contains("3/7"), "download label shows file progress, got \(label)")
        expect(label.contains("5.0 MB/s"), "download label shows throughput, got \(label)")
        expect(label.contains("1 分钟"), "download label shows an ETA, got \(label)")

        let bare = ModelPrepProgress(
            phase: .downloading(files: 0, total: 0),
            fraction: 0,
            bytesPerSecond: nil,
            etaSeconds: nil
        ).menuLabel
        expect(!bare.contains("MB/s"), "no throughput yet means no throughput text, got \(bare)")
        expect(!bare.contains("/0"), "an unknown file count is omitted, got \(bare)")
        expect(bare.contains("0%"), "a just-started download still shows a percent, got \(bare)")
    }

    private static func testNonDownloadLabels() {
        let phases: [ModelPrepProgress.Phase] = [
            .listing, .compiling("encoder"), .warmup, .stalled(seconds: 12), .retrying, .paused,
        ]
        for phase in phases {
            let label = ModelPrepProgress(phase: phase, fraction: 0.5, bytesPerSecond: nil, etaSeconds: nil)
                .menuLabel
            expect(!label.isEmpty, "\(phase) needs a menu label")
        }
        let stalled = ModelPrepProgress(phase: .stalled(seconds: 12), fraction: 0.5, bytesPerSecond: nil, etaSeconds: nil)
        expect(stalled.menuLabel.contains("12"), "a stall reports how long it has been stuck")
        let compiling = ModelPrepProgress(phase: .compiling("encoder"), fraction: 0.9, bytesPerSecond: nil, etaSeconds: nil)
        expect(compiling.menuLabel.contains("encoder"), "compiling names the model being compiled")
    }

    private static func testETAFormatting() {
        expect(ModelPrepProgress.formatETA(45) == "45 秒", "sub-minute ETAs are seconds")
        expect(ModelPrepProgress.formatETA(90) == "1 分钟", "sub-hour ETAs are whole minutes")
        expect(ModelPrepProgress.formatETA(7_200) == "2 小时", "long ETAs are hours")
    }

    // MARK: - Mirror

    private static func testMirrorRawValuesAreRegistryHosts() {
        expect(ModelDownloadMirror.official.rawValue == "https://huggingface.co", "official host is HuggingFace")
        expect(ModelDownloadMirror.hfMirror.rawValue == "https://hf-mirror.com", "mirror host is hf-mirror.com")
        for mirror in ModelDownloadMirror.allCases {
            expect(URL(string: mirror.rawValue) != nil, "\(mirror) raw value is a usable base URL")
            expect(!mirror.rawValue.hasSuffix("/"), "\(mirror) base URL has no trailing slash to double up")
            expect(!mirror.displayName.isEmpty, "\(mirror) needs a menu label")
        }
    }

    private static func testMirrorRoundTripsThroughDefaults() {
        let defaults = UserDefaults.standard
        let key = ModelDownloadMirror.defaultsKey
        let saved = defaults.object(forKey: key)
        let savedBaseURL = ModelRegistry.baseURL
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            ModelRegistry.baseURL = savedBaseURL
        }

        defaults.removeObject(forKey: key)
        expect(ModelDownloadMirror.current == .official, "the default mirror is the official host")

        defaults.set("not-a-mirror", forKey: key)
        expect(ModelDownloadMirror.current == .official, "an unknown stored mirror falls back to official")

        ModelDownloadMirror.current = .hfMirror
        expect(ModelDownloadMirror.current == .hfMirror, "the chosen mirror is persisted")
        expect(
            ModelRegistry.baseURL == ModelDownloadMirror.hfMirror.rawValue,
            "choosing a mirror retargets FluidAudio downloads, got \(ModelRegistry.baseURL)"
        )

        ModelDownloadMirror.current = .official
        ModelDownloadMirror.applyToRegistry()
        expect(
            ModelRegistry.baseURL == ModelDownloadMirror.official.rawValue,
            "switching back retargets FluidAudio again"
        )
    }

    // MARK: - Throttle

    private static func testThrottleSuppressesChatter() {
        let throttle = ModelProgressThrottle()
        let start = ModelPrepProgress.fromDownloadFraction(0.10, filesCompleted: 1, filesTotal: 7)
        expect(throttle.shouldPublish(start), "the first update always publishes")
        expect(!throttle.shouldPublish(start), "an identical update is dropped")

        let nudged = ModelPrepProgress.fromDownloadFraction(0.11, filesCompleted: 1, filesTotal: 7)
        expect(
            !throttle.shouldPublish(nudged),
            "a percent bump inside the throttle window is dropped so the menu does not thrash"
        )

        let nextFile = ModelPrepProgress.fromDownloadFraction(0.30, filesCompleted: 2, filesTotal: 7)
        expect(throttle.shouldPublish(nextFile), "a phase change publishes immediately")

        throttle.reset()
        expect(throttle.shouldPublish(nextFile), "reset makes the next update the first one again")
    }
}
