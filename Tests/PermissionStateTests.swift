import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PermissionStateTests {
    static func main() {
        testGrantedTitle()
        testMissingTitle()
        testPerPermissionLabels()
        print("PermissionStateTests: PASS")
    }

    private static func testGrantedTitle() {
        let title = HyperVibePermission.menuTitle(label: "辅助功能", granted: true)
        expect(title == "辅助功能：已授权 ✓", "granted title should confirm authorization, got \(title)")
    }

    private static func testMissingTitle() {
        let title = HyperVibePermission.menuTitle(label: "输入监控", granted: false)
        expect(title == "输入监控：点击授权…", "missing title should prompt to authorize, got \(title)")
    }

    private static func testPerPermissionLabels() {
        expect(HyperVibePermission.accessibility.menuLabel == "辅助功能", "accessibility label mismatch")
        expect(HyperVibePermission.inputMonitoring.menuLabel == "输入监控", "input monitoring label mismatch")
    }
}
