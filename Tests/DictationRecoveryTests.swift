import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct DictationRecoveryTests {
    static func main() {
        testRetypePreferredOverPending()
        testResumeWhenNoTranscript()
        testTakePendingClears()
        testTrimKeepsRecent()
        print("DictationRecoveryTests: PASS")
    }

    private static func testRetypePreferredOverPending() {
        let store = DictationRecoveryStore()
        store.recordPending([1, 2, 3, 4], sampleRate: 4, reason: .emptyResult)
        store.recordTranscript("hello world")
        guard case .retype(let text) = store.mode else {
            expect(false, "expected retype mode")
            return
        }
        expect(text == "hello world", "transcript text")
        expect(store.pending.isEmpty, "pending cleared by transcript")
    }

    private static func testResumeWhenNoTranscript() {
        let store = DictationRecoveryStore()
        store.recordPending([Int16](repeating: 1, count: 48_000), sampleRate: 48_000, reason: .tooShort)
        guard case .resume(let seconds, let reason) = store.mode else {
            expect(false, "expected resume mode")
            return
        }
        expect(abs(seconds - 1.0) < 0.01, "one second of audio")
        expect(reason == .tooShort, "reason preserved")
    }

    private static func testTakePendingClears() {
        let store = DictationRecoveryStore()
        store.recordPending([9, 8, 7], sampleRate: 3, reason: .engineError)
        let taken = store.takePending()
        expect(taken?.samples == [9, 8, 7], "samples returned")
        expect(store.mode == .none, "cleared after take")
    }

    private static func testTrimKeepsRecent() {
        let store = DictationRecoveryStore()
        let rate = 10.0
        let samples = Array(0..<Int(rate * 40)).map { Int16($0) }
        store.recordPending(samples, sampleRate: rate, reason: .disconnected)
        expect(store.pending.count == Int(rate * DictationRecoveryStore.maxPendingSeconds), "trimmed to cap")
        expect(store.pending.first == Int16(rate * 10), "kept the most recent suffix")
    }
}
