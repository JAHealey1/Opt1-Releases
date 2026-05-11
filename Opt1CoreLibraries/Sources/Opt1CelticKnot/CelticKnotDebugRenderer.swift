import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Celtic knot debug outputs

public struct CelticKnotDebugRenderer {

    public init() {}

    /// Draw colored circles at every template position over the puzzle-bounds crop for visual debugging.
    /// Set to a track index (0, 1, 2) to draw only that track's circles,
    /// or nil to draw all tracks. Useful for verifying track geometry.
    public static var debugTrackFilter: [Int]? = nil // Change to 0, 1, 2, 3, or nil

    public func drawTemplateOverlay(
        on image: CGImage,
        puzzleBounds: CGRect,
        layout: CelticKnotLayout
    ) -> CGImage? {
        let expectedW = Int(puzzleBounds.width)
        let expectedH = Int(puzzleBounds.height)
        guard expectedW > 10, expectedH > 10 else { return nil }

        guard let puzzleCrop = image.cropping(to: puzzleBounds) else { return nil }

        // Use the actual crop dimensions; if the image was clipped at the screen edge
        // the crop may be shorter than expected (e.g. OSRS window extending off-screen).
        let w = puzzleCrop.width
        let h = puzzleCrop.height
        if h < expectedH {
            print("[CelticKnot] ⚠️ Overlay crop clipped: expected \(expectedH)px tall, " +
                  "got \(h)px — OSRS window may be near the bottom of the screen")
        }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(puzzleCrop, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Scale slot positions to account for the clipped height.
        let heightScale = CGFloat(h) / CGFloat(expectedH)

        let trackColors: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 0.85),
            CGColor(red: 0, green: 1, blue: 0, alpha: 0.85),
            CGColor(red: 0, green: 0.5, blue: 1, alpha: 0.85),
            CGColor(red: 1, green: 1, blue: 0, alpha: 0.85),
        ]

        let diam = layout.estimatedRuneDiameter
        let cropSide = min(puzzleBounds.width, puzzleBounds.height) * diam

        for (trackIdx, track) in layout.tracks.enumerated() {
            if let filter = Self.debugTrackFilter, !filter.contains(where: { $0 == trackIdx }) { continue }
            let color = trackColors[trackIdx % trackColors.count]
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1.5)

            for slot in track {
                let px = slot.x * CGFloat(w)
                let py = slot.y * CGFloat(expectedH) * heightScale
                let flippedY = CGFloat(h) - py

                ctx.strokeEllipse(in: CGRect(
                    x: px - cropSide / 2,
                    y: flippedY - cropSide / 2,
                    width: cropSide,
                    height: cropSide
                ))

                let label = "\(slot.slotIndex)"
                let fontSize: CGFloat = max(10, min(10, cropSide * 0.4))
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: color,
                ]
                guard let attrStr = CFAttributedStringCreate(nil, label as CFString, attrs as CFDictionary) else { continue }
                let line = CTLineCreateWithAttributedString(attrStr)

                ctx.saveGState()
                ctx.translateBy(x: px + cropSide / 2 + 1, y: flippedY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: 0, y: -fontSize * 0.35)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Debug output

    /// Draws the detected ClueTrainer-style tile grid over the puzzle crop.
    /// Cyan marks sampled tile centers, orange marks inferred lane traces, and
    /// magenta marks the snapped grid origin.
    private func drawGridAnalysisOverlay(
        on image: CGImage,
        puzzleBounds: CGRect,
        analysis: CelticKnotGridReader.Analysis
    ) -> CGImage? {
        guard let puzzleCrop = image.cropping(to: puzzleBounds) else { return nil }
        let w = puzzleCrop.width
        let h = puzzleCrop.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(puzzleCrop, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        func local(_ point: CGPoint) -> CGPoint {
            let x = point.x - puzzleBounds.minX
            let y = CGFloat(h) - (point.y - puzzleBounds.minY)
            return CGPoint(x: x, y: y)
        }

        drawGridAnalysisLegend(in: ctx, imageSize: CGSize(width: w, height: h), analysis: analysis)

        guard analysis.tilePitch > 0 else {
            return ctx.makeImage()
        }

        let origin = local(analysis.gridOriginInImage)
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.95))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: origin.x - 5, y: origin.y - 5, width: 10, height: 10))

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        ctx.setLineWidth(0.75)
        let latticeMinX = puzzleBounds.minX
        let latticeMaxX = puzzleBounds.maxX
        let latticeMinY = puzzleBounds.minY
        let latticeMaxY = puzzleBounds.maxY
        let firstColumn = Int(floor((latticeMinX - analysis.gridOriginInImage.x) / analysis.tilePitch))
        let lastColumn = Int(ceil((latticeMaxX - analysis.gridOriginInImage.x) / analysis.tilePitch))
        let firstRow = Int(floor((latticeMinY - analysis.gridOriginInImage.y) / analysis.tilePitch))
        let lastRow = Int(ceil((latticeMaxY - analysis.gridOriginInImage.y) / analysis.tilePitch))
        for x in firstColumn...lastColumn {
            let px = analysis.gridOriginInImage.x + CGFloat(x) * analysis.tilePitch
            guard px >= latticeMinX, px <= latticeMaxX else { continue }
            let top = local(CGPoint(x: px, y: latticeMinY))
            let bottom = local(CGPoint(x: px, y: latticeMaxY))
            ctx.move(to: top)
            ctx.addLine(to: bottom)
        }
        for y in firstRow...lastRow {
            let py = analysis.gridOriginInImage.y + CGFloat(y) * analysis.tilePitch
            guard py >= latticeMinY, py <= latticeMaxY else { continue }
            let left = local(CGPoint(x: latticeMinX, y: py))
            let right = local(CGPoint(x: latticeMaxX, y: py))
            ctx.move(to: left)
            ctx.addLine(to: right)
        }
        ctx.strokePath()

        let laneColors: [CGColor] = [
            CGColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.95),
            CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.95),
            CGColor(red: 0.2, green: 0.2, blue: 0.6, alpha: 0.95),
            CGColor(red: 1, green: 0.75, blue: 0, alpha: 0.95),
            CGColor(red: 0.65, green: 0.65, blue: 0.65, alpha: 0.95),
        ]

        for lane in analysis.lanes {
            let color = laneColors.indices.contains(lane.color)
                ? laneColors[lane.color]
                : CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.95)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
            for (idx, tile) in lane.tiles.enumerated() {
                let p = local(tile.centerInImage)
                if idx == 0 {
                    ctx.move(to: p)
                } else {
                    ctx.addLine(to: p)
                }
            }
            ctx.strokePath()
        }

        let trackColors: [CGColor] = [
            CGColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.9),
            CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.9),
            CGColor(red: 0.2, green: 0.2, blue: 0.6, alpha: 0.9),
            CGColor(red: 1, green: 0.75, blue: 0, alpha: 0.9),
            CGColor(red: 0.65, green: 0.65, blue: 0.65, alpha: 0.9),
        ]

        for tile in analysis.tiles {
            let p = local(tile.centerInImage)
            let radius: CGFloat = tile.isReadable ? (tile.isIntersection ? 4 : 2.5) : 1.5
            let color: CGColor
            if tile.isReadable,
               let trackColor = tile.trackColor,
               trackColors.indices.contains(trackColor) {
                color = trackColors[trackColor]
            } else if tile.isReadable {
                color = CGColor(red: 0, green: 1, blue: 1, alpha: 0.9)
            } else {
                color = CGColor(red: 1, green: 0, blue: 0, alpha: 0.45)
            }
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))

            if (tile.trackColorConfidence ?? 0) < 0.84 {
                ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.95))
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            }
        }

        return ctx.makeImage()
    }

    private func drawGridAnalysisLegend(
        in ctx: CGContext,
        imageSize: CGSize,
        analysis: CelticKnotGridReader.Analysis
    ) {
        let lines = [
            analysis.succeeded ? "GRID: TRUSTED" : "GRID: DIAGNOSTIC ONLY",
            "dots = track colour, larger = intersection",
            "magenta ring = weak strip-colour confidence",
            "magenta = origin, orange = traced lanes",
            "pitch \(String(format: "%.1f", analysis.tilePitch))  size \(analysis.gridSize.x)x\(analysis.gridSize.y)",
            "readable \(analysis.readableTileCount)/\(analysis.occupiedTileCount)  lanes \(analysis.lanes.count)",
        ]

        let fontSize: CGFloat = 10
        let lineHeight: CGFloat = 12
        let boxWidth: CGFloat = 245
        let boxHeight = CGFloat(lines.count) * lineHeight + 10
        let box = CGRect(x: 6, y: imageSize.height - boxHeight - 6, width: boxWidth, height: boxHeight)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(box)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        for (idx, lineText) in lines.enumerated() {
            let color: CGColor
            if idx == 0 {
                color = analysis.succeeded
                    ? CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1)
                    : CGColor(red: 1, green: 0.35, blue: 0.25, alpha: 1)
            } else {
                color = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            }
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
            ]
            guard let attrStr = CFAttributedStringCreate(nil, lineText as CFString, attrs as CFDictionary) else { continue }
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(
                x: box.minX + 6,
                y: box.maxY - 7 - CGFloat(idx + 1) * lineHeight
            )
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    public func saveDebugImages(
        image: CGImage,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        layoutType: CelticKnotLayoutType,
        layout: CelticKnotLayout,
        gridAnalysis: CelticKnotGridReader.Analysis? = nil,
        to dir: URL
    ) {
        let ts = Int(Date().timeIntervalSince1970)

        if let puzzleCrop = image.cropping(to: puzzleBounds) {
            savePNG(puzzleCrop, to: dir.appendingPathComponent("puzzle_\(ts).png"))
        }

        if let runeAreaCrop = image.cropping(to: runeArea) {
            savePNG(runeAreaCrop, to: dir.appendingPathComponent("rune_area_\(ts).png"))
        }

        if let overlay = drawTemplateOverlay(on: image, puzzleBounds: puzzleBounds, layout: layout) {
            savePNG(overlay, to: dir.appendingPathComponent("debug_overlay_\(ts).png"))
        }

        if let gridAnalysis,
           let overlay = drawGridAnalysisOverlay(on: image, puzzleBounds: puzzleBounds, analysis: gridAnalysis) {
            savePNG(overlay, to: dir.appendingPathComponent("grid_analysis_\(ts).png"))

            let summary = gridAnalysis.summaryLines.joined(separator: "\n") + "\n"
            try? summary.write(
                to: dir.appendingPathComponent("grid_analysis_\(ts).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        print("[CelticKnot] Debug images saved to \(dir.path)")
    }

    public func saveGridAnalysisDebug(
        image: CGImage,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        gridAnalysis: CelticKnotGridReader.Analysis,
        to dir: URL
    ) {
        let ts = Int(Date().timeIntervalSince1970)

        if let puzzleCrop = image.cropping(to: puzzleBounds) {
            savePNG(puzzleCrop, to: dir.appendingPathComponent("puzzle_\(ts).png"))
        }

        if let runeAreaCrop = image.cropping(to: runeArea) {
            savePNG(runeAreaCrop, to: dir.appendingPathComponent("rune_area_\(ts).png"))
        }

        if let overlay = drawGridAnalysisOverlay(on: image, puzzleBounds: puzzleBounds, analysis: gridAnalysis) {
            savePNG(overlay, to: dir.appendingPathComponent("grid_analysis_\(ts).png"))
        }

        let summary = gridAnalysis.summaryLines.joined(separator: "\n") + "\n"
        try? summary.write(
            to: dir.appendingPathComponent("grid_analysis_\(ts).txt"),
            atomically: true,
            encoding: .utf8
        )

        print("[CelticKnot] Grid debug saved to \(dir.path)")
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
