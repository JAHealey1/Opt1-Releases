import CoreGraphics

/// Geometry offsets for NXT puzzle modals at 100% UI scale, relative to the matched close-X rect.
enum NXTModalOffsetsAt100 {
    static let titleBarTopLeftFromX = (dx: -480, dy: -2)
    static let titleBarSize = (width: 505, height: 24)
    /// Celtic Knot: top of RESET/CHECK band relative to X.
    static let buttonBandTopFromX = 307
    /// Extra extent below the RESET/CHECK baseline for Towers parchment; bottom clues sit below the chrome row `findDialogBottomEdge` locks onto.
    static let towersModalExtentBelowButtons = 52

    /// Gap from Vision-measured title bottom to the **top** of the 7×7 hint grid at 100% UI scale (top clue band included in ROI).
    static let towersGridTopInsetBelowTitleBar = 46
    /// Nudge the hint ROI **up** by this many nominal 7×7 band heights so `gy == 0` sampling rects cover painted top clues (often sit slightly above naive `hintTop`).
    static let towersHintRoiExtraBandsAbove: CGFloat = 1
    /// Inner 7×7 hint grid width at 100% scale.
    static let towersHintAreaWidth = 342
    /// Fallback hint-area height at 100% when bottom-edge scan fails.
    static let towersHintAreaHeightFallback = 367
}

func scaledRectFromX(
    _ xRect: CGRect,
    offset: (dx: Int, dy: Int),
    size: (width: Int, height: Int),
    scale: CGFloat
) -> CGRect {
    CGRect(
        x: xRect.minX + CGFloat(offset.dx) * scale,
        y: xRect.minY + CGFloat(offset.dy) * scale,
        width: CGFloat(size.width) * scale,
        height: CGFloat(size.height) * scale
    )
}

/// Finds the dialog's top dark-frame row above the title (same scan Celtic Knot uses for `puzzleBounds.minY`).
func findDialogTopEdge(in image: CGImage, titleBounds: CGRect) -> CGFloat? {
    let scanHeight = 40
    let scanX0 = max(0, Int(titleBounds.midX) - 60)
    let scanX1 = min(image.width, Int(titleBounds.midX) + 60)
    let scanY0 = max(0, Int(titleBounds.minY) - scanHeight)
    let scanY1 = max(0, Int(titleBounds.minY))
    let w = scanX1 - scanX0
    let h = scanY1 - scanY0
    guard w > 20, h > 10 else { return nil }

    let cropRect = CGRect(x: scanX0, y: scanY0, width: w, height: h)
    guard let crop = image.cropping(to: cropRect) else { return nil }
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    guard let data = ctx.data else { return nil }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

    var topFrameRow: Int?
    for row in stride(from: h - 1, through: 0, by: -1) {
        var darkCount = 0
        var parchmentCount = 0
        for col in 0..<w {
            let i = (row * w + col) * 4
            let r = Float(buf[i]) / 255
            let g = Float(buf[i + 1]) / 255
            let b = Float(buf[i + 2]) / 255
            let maxC = max(r, max(g, b))
            if maxC < 0.18 {
                darkCount += 1
            } else if (r - b) > 0.04, maxC > 0.35, maxC < 0.85 {
                parchmentCount += 1
            }
        }
        let darkPct = Float(darkCount) / Float(w)
        let parchmentPct = Float(parchmentCount) / Float(w)
        if darkPct > 0.6 {
            topFrameRow = row
        } else if parchmentPct > 0.5, topFrameRow == nil {
            continue
        } else if topFrameRow != nil {
            break
        }
    }

    guard let row = topFrameRow else { return nil }
    return CGFloat(scanY0 + row)
}

/// Scans downward from just below the title bar to find the dark bottom chrome border of a
/// clue scroll modal.  Unlike `findDialogBottomEdge` this does not need a pre-calibrated
/// expected-bottom anchor — it searches the full plausible content range (50–600 scale units
/// below the title bar).  Returns the y coordinate of the bottom chrome row, or nil.
func findScrollContentBottom(in image: CGImage, titleBounds: CGRect, scale: CGFloat) -> CGFloat? {
    let minContent = Int((50  * scale).rounded())
    let maxContent = Int((600 * scale).rounded())
    let scanX0 = max(0, Int(titleBounds.minX))
    let scanX1 = min(image.width, Int(titleBounds.maxX))
    let scanY0 = min(image.height, Int(titleBounds.maxY) + minContent)
    let scanY1 = min(image.height, Int(titleBounds.maxY) + maxContent)
    let w = scanX1 - scanX0
    let h = scanY1 - scanY0
    guard w > 20, h > 10 else { return nil }

    let cropRect = CGRect(x: scanX0, y: scanY0, width: w, height: h)
    guard let crop = image.cropping(to: cropRect) else { return nil }
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    guard let data = ctx.data else { return nil }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

    var rowStats: [(darkPct: Float, parchmentPct: Float)] = []
    rowStats.reserveCapacity(h)
    for row in 0..<h {
        var darkCount = 0
        var parchmentCount = 0
        for col in 0..<w {
            let i = (row * w + col) * 4
            let r = Float(buf[i]) / 255
            let g = Float(buf[i + 1]) / 255
            let b = Float(buf[i + 2]) / 255
            let maxC = max(r, max(g, b))
            if maxC < 0.18 {
                darkCount += 1
            } else if (r - b) > 0.04, maxC > 0.35, maxC < 0.85 {
                parchmentCount += 1
            }
        }
        rowStats.append((
            darkPct: Float(darkCount) / Float(w),
            parchmentPct: Float(parchmentCount) / Float(w)
        ))
    }

    for row in 1..<h {
        let stats = rowStats[row]
        let above = rowStats[max(0, row - 3)..<row]
        let hasParchmentAbove = above.contains { $0.parchmentPct > 0.35 }
        if stats.darkPct > 0.55, hasParchmentAbove {
            return CGFloat(scanY0 + row + 1)
        }
    }
    return nil
}

/// Finds the bottom dark frame row below the button band. Keeps modal bounds tied to chrome
/// instead of OCR observations (shared by Celtic Knot and Towers anchor paths).
func findDialogBottomEdge(
    in image: CGImage,
    modalLeft: CGFloat,
    modalRight: CGFloat,
    buttonBandTop: CGFloat,
    expectedBottom: CGFloat,
    scale: CGFloat
) -> CGFloat? {
    let inset = max(4, Int(round(8 * scale)))
    let scanX0 = max(0, Int(modalLeft) + inset)
    let scanX1 = min(image.width, Int(modalRight) - inset)
    let searchSlack = max(6, Int(round(8 * scale)))
    let scanY0 = max(0, Int(floor(expectedBottom)) - searchSlack)
    let scanY1 = min(image.height - 1, Int(ceil(expectedBottom)) + searchSlack)
    let w = scanX1 - scanX0
    let h = scanY1 - scanY0 + 1
    guard w > 40, h > 10 else { return nil }

    let cropRect = CGRect(x: scanX0, y: scanY0, width: w, height: h)
    guard let crop = image.cropping(to: cropRect) else { return nil }
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    guard let data = ctx.data else { return nil }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

    var rowStats: [(darkPct: Float, parchmentPct: Float)] = []
    rowStats.reserveCapacity(h)
    for row in 0..<h {
        var darkCount = 0
        var parchmentCount = 0
        for col in 0..<w {
            let i = (row * w + col) * 4
            let r = Float(buf[i]) / 255
            let g = Float(buf[i + 1]) / 255
            let b = Float(buf[i + 2]) / 255
            let maxC = max(r, max(g, b))
            if maxC < 0.18 {
                darkCount += 1
            } else if (r - b) > 0.04, maxC > 0.35, maxC < 0.85 {
                parchmentCount += 1
            }
        }
        rowStats.append((
            darkPct: Float(darkCount) / Float(w),
            parchmentPct: Float(parchmentCount) / Float(w)
        ))
    }

    for row in 1..<h {
        let stats = rowStats[row]
        let above = rowStats[max(0, row - 3)..<row]
        let hasParchmentAbove = above.contains { $0.parchmentPct > 0.35 }
        if stats.darkPct > 0.55, hasParchmentAbove {
            return CGFloat(scanY0 + row + 1)
        }
    }
    return nil
}
