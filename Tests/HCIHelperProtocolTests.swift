import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HCIHelperProtocolTests {
    static func main() {
        testEncodeDecodeStartStop()
        testPathValidation()
        testInstallScriptIsOneShot()
        testLaunchdPlistPointsAtInstalledHelper()
        print("HCIHelperProtocolTests: PASS")
    }

    private static func testEncodeDecodeStartStop() {
        let start = HCIHelperRequest.start(
            packetLoggerPath: "/Applications/HyperVibe.app/Contents/Resources/Tools/PacketLogger.app/Contents/Resources/packetlogger",
            parentPID: 4242
        )
        let encoded = HCIHelperCodec.encode(start)
        expect(encoded.hasSuffix("\n"), "requests must be newline-terminated")
        expect(!encoded.contains("\n\n"), "single-line framing")

        guard let decoded = HCIHelperCodec.decodeRequest(encoded) else {
            expect(false, "start request must decode")
            return
        }
        guard case let .start(packetLogger, pid) = decoded else {
            expect(false, "decoded request must be start")
            return
        }
        expect(
            packetLogger.hasSuffix("/Contents/Resources/packetlogger"),
            "packetlogger path round-trips"
        )
        expect(pid == 4242, "parent pid round-trips")

        let stopLine = HCIHelperCodec.encode(.stop)
        expect(HCIHelperCodec.decodeRequest(stopLine) == .stop, "stop round-trips")
        expect(HCIHelperCodec.decodeRequest(HCIHelperCodec.encode(.ping)) == .ping, "ping round-trips")
        expect(HCIHelperCodec.decodeRequest(HCIHelperCodec.encode(.version)) == .version, "version round-trips")
        let version = HCIHelperCodec.encodeResponse(.version(HCIHelperCodec.currentHelperVersion))
        expect(
            HCIHelperCodec.decodeResponse(version) == .version(HCIHelperCodec.currentHelperVersion),
            "version response round-trips"
        )

        let ok = HCIHelperCodec.encodeResponse(.ok)
        expect(HCIHelperCodec.decodeResponse(ok) == .ok, "ok response round-trips")
        let started = HCIHelperCodec.encodeResponse(
            .started(outputPath: "/var/tmp/out.nhdr", tokenPath: "/var/tmp/alive")
        )
        expect(
            HCIHelperCodec.decodeResponse(started)
                == .started(outputPath: "/var/tmp/out.nhdr", tokenPath: "/var/tmp/alive"),
            "started response round-trips"
        )
        let err = HCIHelperCodec.encodeResponse(.error("nope"))
        expect(HCIHelperCodec.decodeResponse(err) == .error("nope"), "error response round-trips")
    }

    private static func testPathValidation() {
        expect(
            !HCIHelperPathValidation.isAllowedPacketLoggerPath("/usr/local/bin/packetlogger"),
            "bare packetlogger must be rejected"
        )
        expect(
            !HCIHelperPathValidation.isAllowedPacketLoggerPath("/tmp/evil"),
            "arbitrary path must be rejected"
        )
    }

    private static func testInstallScriptIsOneShot() {
        let script = HCIHelperInstall.makeInstallScript(
            helperSourcePath: "/Applications/HyperVibe.app/Contents/Resources/Helpers/com.hypervibe.hcihelper",
            helperInstallPath: HCIHelperPaths.helperBinary,
            plistPath: HCIHelperPaths.launchdPlist,
            label: HCIHelperPaths.launchdLabel
        )
        expect(script.contains("cp "), "install copies helper")
        expect(script.contains(HCIHelperPaths.helperBinary), "install targets helper path")
        expect(script.contains(HCIHelperPaths.launchdPlist), "install writes launchd plist")
        expect(script.contains(HCIHelperPaths.sessionRoot), "install prepares session root")
        expect(script.contains("bootstrap system"), "install bootstraps LaunchDaemon")
        expect(script.contains("kickstart -k"), "install restarts helper")
        expect(!script.contains("packetlogger convert"), "install must not start capture itself")
    }

    private static func testLaunchdPlistPointsAtInstalledHelper() {
        let plist = HCIHelperInstall.makeLaunchdPlist(
            label: HCIHelperPaths.launchdLabel,
            helperPath: HCIHelperPaths.helperBinary,
            socketPath: HCIHelperPaths.socketPath
        )
        expect(plist.contains("<string>\(HCIHelperPaths.launchdLabel)</string>"), "plist label")
        expect(plist.contains("<string>\(HCIHelperPaths.helperBinary)</string>"), "plist program")
        expect(plist.contains("<key>RunAtLoad</key>"), "plist runs at load")
        expect(plist.contains("<true/>"), "RunAtLoad true")
        expect(plist.contains(HCIHelperPaths.socketPath), "socket path is a program argument")
        expect(plist.contains("--socket"), "helper receives --socket")
    }
}
