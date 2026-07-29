import Foundation
import AppKit
import CoreGraphics

/// Render one frame of the HyperVibe icon at the given pixel size.
/// Design: squircle with solid #252525 background and white wave bars
/// matching the menu-bar glyph (`WaveGlyph`).
func renderIcon(size: CGFloat) -> Data? {
    let w = Int(size), h = Int(size)
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: space, bitmapInfo: bitmap.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    ctx.clip()

    ctx.setFillColor(CGColor(red: 0x25/255, green: 0x25/255, blue: 0x25/255, alpha: 1))
    ctx.fill(rect)

    let barCount = size <= 32 ? WaveGlyph.barCount : 7
    let inset = rect.insetBy(dx: size * 0.18, dy: size * 0.18)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for bar in WaveGlyph.barRects(in: inset, barCount: barCount) {
        ctx.addPath(CGPath(
            roundedRect: bar,
            cornerWidth: bar.width / 2,
            cornerHeight: bar.width / 2,
            transform: nil
        ))
        ctx.fillPath()
    }

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

@main
struct IconGenerator {
    static func main() throws {
        let frames: [(name: String, px: Int)] = [
            ("icon_16x16.png",       16),
            ("icon_16x16@2x.png",    32),
            ("icon_32x32.png",       32),
            ("icon_32x32@2x.png",    64),
            ("icon_128x128.png",    128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png",    256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png",    512),
            ("icon_512x512@2x.png",1024),
        ]

        let outDir = URL(fileURLWithPath: "HyperVibe.iconset")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for frame in frames {
            guard let data = renderIcon(size: CGFloat(frame.px)) else {
                print("Failed to render \(frame.name)")
                continue
            }
            try data.write(to: outDir.appendingPathComponent(frame.name))
        }
        print("Wrote \(frames.count) frames to HyperVibe.iconset/")
    }
}
