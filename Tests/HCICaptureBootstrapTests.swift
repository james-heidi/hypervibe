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
        testPrivilegedScriptLifecycle()
        testPrivilegedScriptSyntax()
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

    private static func testPrivilegedScriptLifecycle() {
        let config = PrivilegedHCICaptureConfig(
            packetLoggerPath: "/App's Tools/packetlogger",
            sessionDirectoryPath: "/tmp/hv",
            outputPath: "/tmp/hv/output.nhdr",
            tokenPath: "/tmp/hv/alive",
            parentPID: 4242
        )
        let script = PrivilegedHCICaptureScript.make(config)

        expect(script.contains("HCISkipAuth -bool true"), "script must bypass profile auth")
        expect(script.contains("RawAudioTrace -bool true"), "script must enable raw audio")
        expect(script.contains("killall -30 bluetoothd"), "script must reload bluetoothd")
        expect(script.contains("defaults export"), "script must back up existing preferences")
        expect(script.contains("defaults import"), "script must restore existing preferences")
        expect(script.contains("trap cleanup EXIT INT TERM"), "script must restore on exit")
        expect(script.contains("rm -rf \"$SESSION_DIR\""), "script must remove crash leftovers")
        expect(script.contains("PARENT_PID=4242"), "script must record HyperVibe PID")
        expect(
            script.contains("kill -0 \"$PARENT_PID\""),
            "script must stop when HyperVibe exits"
        )
        expect(
            script.contains("'/App'\"'\"'s Tools/packetlogger' convert -s -f nhdr"),
            "PacketLogger path must be shell-quoted"
        )
    }

    private static func testPrivilegedScriptSyntax() {
        let script = PrivilegedHCICaptureScript.make(
            PrivilegedHCICaptureConfig(
                packetLoggerPath: "/Applications/PacketLogger.app/packetlogger",
                sessionDirectoryPath: "/tmp/hv",
                outputPath: "/tmp/hv/output.nhdr",
                tokenPath: "/tmp/hv/alive",
                parentPID: 4242
            )
        )
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            expect(process.terminationStatus == 0, "privileged shell script must parse")
        } catch {
            expect(false, "could not syntax-check privileged shell script: \(error)")
        }
    }
}
