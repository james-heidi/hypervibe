import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class MockPolishBackend: TranscriptPolishBackend {
    var available: Bool
    var result: Result<String, Error>
    var delayNanoseconds: UInt64
    var callCount = 0
    var lastInput: String?

    init(
        available: Bool = true,
        result: Result<String, Error> = .success("polished"),
        delayNanoseconds: UInt64 = 0
    ) {
        self.available = available
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    var isAvailable: Bool { available }

    func polish(
        _ text: String,
        instructions: String,
        generation: UUID,
        isCurrent: @escaping () -> Bool
    ) async throws -> String {
        callCount += 1
        lastInput = text
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard isCurrent() else { throw TranscriptPolishError.cancelled }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

@main
struct TranscriptPolisherTests {
    static func main() {
        testModePersistence()
        testPromptHelpers()
        testCloudRequestAndParse()
        testAutomaticLocalThenCloudFallback()
        testTimeoutFallsBackToRaw()
        testCancelSuppressesStaleResult()
        testOffAndShortSkip()
        print("TranscriptPolisherTests: PASS")
    }

    private static func testModePersistence() {
        let previous = TranscriptPolishMode.current
        defer { TranscriptPolishMode.current = previous }

        TranscriptPolishMode.current = .cloud
        expect(TranscriptPolishMode.current == .cloud, "persist cloud mode")
        TranscriptPolishMode.current = .local
        expect(TranscriptPolishMode.current == .local, "persist local mode")
        TranscriptPolishMode.current = .automatic
        expect(TranscriptPolishMode.current == .automatic, "persist automatic mode")
        expect(
            TranscriptPolishMode.allCases.map(\.rawValue).sorted()
                == ["automatic", "cloud", "local", "off"],
            "all modes listed"
        )
    }

    private static func testPromptHelpers() {
        expect(TranscriptPolishPrompt.shouldSkip(""), "empty skip")
        expect(TranscriptPolishPrompt.shouldSkip("hi"), "short skip")
        expect(TranscriptPolishPrompt.shouldSkip("How are you today?"), "clean short skip")
        expect(
            !TranscriptPolishPrompt.shouldSkip("嗯这个功能我觉得还可以再优化一下速度"),
            "filler text should polish"
        )
        expect(
            TranscriptPolishPrompt.instructions.contains("filler"),
            "instructions mention fillers"
        )
        expect(
            TranscriptPolishPrompt.maxOutputTokens(for: "hello world") >= 48,
            "token cap has a floor"
        )
    }

    private static func testCloudRequestAndParse() {
        let body = try! CloudTranscriptPolishBackend.makeRequestBody(
            model: "gpt-4.1-nano",
            instructions: "clean",
            input: "um hello",
            maxOutputTokens: 64
        )
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        expect(json["model"] as? String == "gpt-4.1-nano", "body model")
        expect(json["instructions"] as? String == "clean", "body instructions")
        expect(json["input"] as? String == "um hello", "body input")
        expect(json["store"] as? Bool == false, "store disabled")
        expect(json["max_output_tokens"] as? Int == 64, "max tokens capped")

        let nested = """
        {"output":[{"type":"message","content":[{"type":"output_text","text":" Hello "}]}]}
        """.data(using: .utf8)!
        expect(
            try! CloudTranscriptPolishBackend.parseOutputText(nested) == "Hello",
            "nested output_text"
        )

        let direct = #"{"output_text":" Direct "}"#.data(using: .utf8)!
        expect(
            try! CloudTranscriptPolishBackend.parseOutputText(direct) == "Direct",
            "direct output_text"
        )
    }

    private static func awaitResult(
        _ polish: (@escaping (String) -> Void) -> Void,
        timeout: TimeInterval = 3.0
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        polish { text in
            result = text
            semaphore.signal()
        }
        // Pump main briefly so timeout/main deliveries can run in this CLI harness.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if semaphore.wait(timeout: .now()) == .success {
                return result
            }
        }
        fputs("FAIL: polish timed out waiting for completion\n", stderr)
        exit(1)
    }

    private static func testAutomaticLocalThenCloudFallback() {
        let previous = TranscriptPolishMode.current
        defer { TranscriptPolishMode.current = previous }
        TranscriptPolishMode.current = .automatic

        let local = MockPolishBackend(
            available: true,
            result: .failure(TranscriptPolishError.backend("boom"))
        )
        let cloud = MockPolishBackend(
            available: true,
            result: .success("from-cloud")
        )
        let polisher = TranscriptPolisher(local: local, cloud: cloud)
        let result = awaitResult { polisher.polish("um this transcript needs a real polish pass please", completion: $0) }
        expect(local.callCount == 1, "automatic tries local first")
        expect(cloud.callCount == 1, "automatic falls back to cloud")
        expect(result == "from-cloud", "cloud result used after local failure")
    }

    private static func testTimeoutFallsBackToRaw() {
        let previous = TranscriptPolishMode.current
        defer { TranscriptPolishMode.current = previous }
        TranscriptPolishMode.current = .cloud

        // Delay well past the budget so the timeout path wins.
        let cloud = MockPolishBackend(
            available: true,
            result: .success("late-polished"),
            delayNanoseconds: UInt64(TranscriptPolisher.budgetSeconds * 3 * 1_000_000_000)
        )
        let polisher = TranscriptPolisher(
            local: MockPolishBackend(available: false),
            cloud: cloud
        )
        let raw = "um timeout should keep this longer raw transcript text"
        let result = awaitResult(
            { polisher.polish(raw, completion: $0) },
            timeout: TranscriptPolisher.budgetSeconds + 2.0
        )
        expect(result == raw, "timeout must deliver raw transcript")
    }

    private static func testCancelSuppressesStaleResult() {
        let previous = TranscriptPolishMode.current
        defer { TranscriptPolishMode.current = previous }
        TranscriptPolishMode.current = .cloud

        let cloud = MockPolishBackend(
            available: true,
            result: .success("stale-should-not-arrive"),
            delayNanoseconds: 200_000_000
        )
        let polisher = TranscriptPolisher(
            local: MockPolishBackend(available: false),
            cloud: cloud
        )

        var delivered: String?
        let semaphore = DispatchSemaphore(value: 0)
        polisher.polish("um stale generation suppression sample text here") { text in
            delivered = text
            semaphore.signal()
        }
        // Cancel immediately — completion must not fire for the cancelled generation.
        polisher.cancel()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if semaphore.wait(timeout: .now()) == .success {
                fputs("FAIL: cancelled polish still delivered '\(delivered ?? "")'\n", stderr)
                exit(1)
            }
        }
        expect(delivered == nil, "cancel must suppress stale polish delivery")
    }

    private static func testOffAndShortSkip() {
        let previous = TranscriptPolishMode.current
        defer { TranscriptPolishMode.current = previous }

        let local = MockPolishBackend(available: true, result: .success("x"))
        let cloud = MockPolishBackend(available: true, result: .success("y"))
        let polisher = TranscriptPolisher(local: local, cloud: cloud)

        TranscriptPolishMode.current = .off
        let offResult = awaitResult {
            polisher.polish("um this would be polished if enabled fully", completion: $0)
        }
        expect(offResult == "um this would be polished if enabled fully", "off returns raw")
        expect(local.callCount == 0 && cloud.callCount == 0, "off must not call backends")

        TranscriptPolishMode.current = .automatic
        let short = awaitResult { polisher.polish("hi", completion: $0) }
        expect(short == "hi", "short skip returns raw")
        expect(local.callCount == 0 && cloud.callCount == 0, "short must not call backends")
    }
}
