import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HCICaptureBootstrapTests {
    static func main() {
        testBundledPacketLoggerWins()
        testShellQuoting()
        print("HCICaptureBootstrapTests: PASS")
    }

    private static func testBundledPacketLoggerWins() {
        let candidates = [
            "/App/Contents/Resources/Tools/PacketLogger.app/Contents/Resources/packetlogger",
            "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
        ]
        let found = PacketLoggerLocator.firstExecutable(
            candidates: candidates,
            isExecutable: { $0.hasPrefix("/App/") }
        )
        expect(found == candidates[0], "bundled PacketLogger must take precedence")
    }

    private static func testShellQuoting() {
        expect(
            ShellQuote.single("a'b") == "'a'\"'\"'b'",
            "single-quote escaping must be safe for /bin/sh"
        )
    }
}
