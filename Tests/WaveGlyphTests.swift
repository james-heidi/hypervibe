import Foundation
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct WaveGlyphTests {
    static func main() {
        testFiveBarsCentered()
        testLargeBarCount()
        print("WaveGlyphTests: PASS")
    }

    private static func testFiveBarsCentered() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bars = WaveGlyph.barRects(in: rect, barCount: 5)
        expect(bars.count == 5, "five bars")
        let mid = bars[2].midY
        expect(abs(mid - 50) < 0.5, "tallest bar centered vertically")
        expect(bars[0].height < bars[2].height, "outer shorter than center")
    }

    private static func testLargeBarCount() {
        let bars = WaveGlyph.barRects(in: CGRect(x: 0, y: 0, width: 200, height: 200), barCount: 7)
        expect(bars.count == 7, "seven bars for large icons")
    }
}
