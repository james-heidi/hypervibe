import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RemoteAdapterTests {
    static func main() {
        testProductIDRouting()
        testSharedHIDIdentify()
        testActiveAdapterFallback()
        testKnownProductIDUnion()
        print("RemoteAdapterTests: PASS")
    }

    private static func testProductIDRouting() {
        expect(RemoteAdapterRegistry.adapter(forProductID: 0x0314).model == .a2540, "0x0314 → a2540")
        expect(RemoteAdapterRegistry.adapter(forProductID: 0x0315).model == .a2854, "0x0315 → a2854")
        expect(RemoteAdapterRegistry.adapter(forProductID: 0x0266).model == .unknown, "0x0266 → unknown")
        expect(RemoteAdapterRegistry.adapter(forProductID: 0x9999).model == .unknown, "unknown PID → unknown")
    }

    private static func testSharedHIDIdentify() {
        let a2540 = RemoteAdapterRegistry.a2540
        let a2854 = RemoteAdapterRegistry.a2854
        expect(a2540.identifyButton(page: 0x0C, usage: 0x60) == .tv, "A2540 TV")
        expect(a2854.identifyButton(page: 0x0C, usage: 0x60) == .tv, "A2854 TV")
        expect(a2540.identifyButton(page: 0x0C, usage: 0x42) == .ringUp, "A2540 ringUp")
        expect(a2540.identifyButton(page: 0x0C, usage: 0xE2) == .mute, "A2540 mute")
        expect(a2540.identifyButton(page: 0x0C, usage: 0x04) == .siri, "A2540 siri")
        expect(a2540.identifyButton(page: 0x01, usage: 0x99) == nil, "unmapped usage")
        expect(
            a2540.holdCapableButtons.contains("siri")
                && a2854.holdCapableButtons.contains("playPause"),
            "hold-capable sets"
        )
    }

    private static func testActiveAdapterFallback() {
        RemoteAdapterRegistry.setActive(productID: 0x0314)
        expect(RemoteAdapterRegistry.activeAdapter.model == .a2540, "active a2540")
        RemoteAdapterRegistry.setActive(productID: nil)
        expect(RemoteAdapterRegistry.activeAdapter.model == .a2854, "disconnect → a2854 fallback")
    }

    private static func testKnownProductIDUnion() {
        let ids = RemoteAdapterRegistry.allKnownProductIDs
        expect(ids.contains(0x0314), "includes A2540")
        expect(ids.contains(0x0315), "includes A2854")
        expect(ids.contains(0x0266), "includes legacy A1513")
    }
}
