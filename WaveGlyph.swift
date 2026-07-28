//
//  WaveGlyph.swift
//  HyperVibe
//
//  Shared five-bar waveform geometry for the menu-bar template icon and the
//  Dock/Finder app icon. Sizes are fractions of the canvas so both 18pt and
//  1024px renders stay readable.
//

import CoreGraphics
import Foundation

enum WaveGlyph {
    /// Menu-bar / small-icon bar count.
    static let barCount = 5

    /// Relative heights matching the existing menu-bar glyph silhouette.
    static let heightRatios: [CGFloat] = [5, 9, 13, 9, 5]

    /// Optional denser silhouette for large app-icon canvases.
    static let largeHeightRatios: [CGFloat] = [5, 8, 11, 13, 11, 8, 5]

    static func ratios(forBarCount count: Int) -> [CGFloat] {
        if count >= 7 { return largeHeightRatios }
        return heightRatios
    }

    /// Lay out centered rounded bars inside `rect`.
    static func barRects(in rect: CGRect, barCount: Int = WaveGlyph.barCount) -> [CGRect] {
        let ratios = Self.ratios(forBarCount: barCount)
        let count = ratios.count
        guard count > 0 else { return [] }

        let size = min(rect.width, rect.height)
        let barWidth = size * 0.075
        let spacing = size * 0.055
        let maxHeight = size * 0.72
        let unit = ratios.max() ?? 1
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
        let startX = rect.midX - totalWidth / 2

        return ratios.enumerated().map { index, ratio in
            let height = maxHeight * (ratio / unit)
            return CGRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
        }
    }
}
