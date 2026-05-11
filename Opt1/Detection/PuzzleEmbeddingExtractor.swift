import CoreGraphics
import Foundation

enum PuzzleEmbeddingExtractor {
    static let version = 1
    static let versionV2 = 2
    static let versionV3 = 3
    static let versionV4 = 4

    static func embedding(for image: CGImage, side: Int = 48) -> [Float]? {
        let source = centerInsetCrop(image, insetFraction: side <= 32 ? 0.12 : 0.0) ?? image
        guard let gray = renderGrayscale(source, side: side) else { return nil }
        let hist = intensityHistogram(gray, bins: 32)
        let grad = gradientHistogram(gray, side: side, bins: 16)
        let quad = quadrantMeans(gray, side: side)
        return l2normalize(hist + grad + quad)
    }

    /// V2 color-aware embedding: grayscale features + HSV hue/saturation histograms.
    /// Matches `embedding_for_image_bgr_v2()` in puzzle_embedding_utils.py.
    /// Dimension: 32 (intensity) + 16 (gradient) + 4 (quadrant) + 16 (hue) + 8 (sat) = 76.
    static func colorEmbedding(for image: CGImage, side: Int = 32) -> [Float]? {
        let source = centerInsetCrop(image, insetFraction: side <= 32 ? 0.22 : 0.0) ?? image
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        var gray = [Float](repeating: 0, count: side * side)
        var hues = [Float](repeating: 0, count: side * side)
        var sats = [Float](repeating: 0, count: side * side)

        for i in 0..<(side * side) {
            let r = Float(raw[i * 4])
            let g = Float(raw[i * 4 + 1])
            let b = Float(raw[i * 4 + 2])
            gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0

            let cmax = max(r, max(g, b))
            let cmin = min(r, min(g, b))
            let delta = cmax - cmin

            let saturation: Float = cmax > 0 ? delta / cmax : 0
            sats[i] = saturation / 1.0

            var hue: Float = 0
            if delta > 0 {
                if cmax == r {
                    hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if cmax == g {
                    hue = 60 * ((b - r) / delta + 2)
                } else {
                    hue = 60 * ((r - g) / delta + 4)
                }
                if hue < 0 { hue += 360 }
            }
            hues[i] = hue / 360.0
        }

        let hist = intensityHistogram(gray, bins: 32)
        let grad = gradientHistogram(gray, side: side, bins: 16)
        let quad = quadrantMeans(gray, side: side)

        let hueBins = 16
        var hueHist = [Float](repeating: 0, count: hueBins)
        for h in hues {
            let clamped = min(0.9999, max(0, h))
            hueHist[Int(clamped * Float(hueBins))] += 1
        }
        let hueScale = 1.0 / Float(max(1, hues.count))
        hueHist = hueHist.map { $0 * hueScale }

        let satBins = 8
        var satHist = [Float](repeating: 0, count: satBins)
        for s in sats {
            let clamped = min(0.9999, max(0, s))
            satHist[Int(clamped * Float(satBins))] += 1
        }
        let satScale = 1.0 / Float(max(1, sats.count))
        satHist = satHist.map { $0 * satScale }

        return l2normalize(hist + grad + quad + hueHist + satHist)
    }

    /// V3 embedding: v2 features + 2x2 spatial gradient grid.
    /// Matches `embedding_for_image_bgr_v3()` in puzzle_embedding_utils.py.
    /// Dimension: 76 (v2) + 32 (spatial gradient 8 bins x 4 cells) = 108.
    static func colorEmbeddingV3(for image: CGImage, side: Int = 32) -> [Float]? {
        let source = centerInsetCrop(image, insetFraction: side <= 32 ? 0.22 : 0.0) ?? image
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        var gray = [Float](repeating: 0, count: side * side)
        var hues = [Float](repeating: 0, count: side * side)
        var sats = [Float](repeating: 0, count: side * side)

        for i in 0..<(side * side) {
            let r = Float(raw[i * 4])
            let g = Float(raw[i * 4 + 1])
            let b = Float(raw[i * 4 + 2])
            gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0

            let cmax = max(r, max(g, b))
            let cmin = min(r, min(g, b))
            let delta = cmax - cmin
            sats[i] = cmax > 0 ? delta / cmax : 0

            var hue: Float = 0
            if delta > 0 {
                if cmax == r {
                    hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if cmax == g {
                    hue = 60 * ((b - r) / delta + 2)
                } else {
                    hue = 60 * ((r - g) / delta + 4)
                }
                if hue < 0 { hue += 360 }
            }
            hues[i] = hue / 360.0
        }

        let hist = intensityHistogram(gray, bins: 32)
        let grad = gradientHistogram(gray, side: side, bins: 16)
        let quad = quadrantMeans(gray, side: side)

        let hueBins = 16
        var hueHist = [Float](repeating: 0, count: hueBins)
        for h in hues {
            let clamped = min(0.9999, max(0, h))
            hueHist[Int(clamped * Float(hueBins))] += 1
        }
        let hueScale = 1.0 / Float(max(1, hues.count))
        hueHist = hueHist.map { $0 * hueScale }

        let satBins = 8
        var satHist = [Float](repeating: 0, count: satBins)
        for s in sats {
            let clamped = min(0.9999, max(0, s))
            satHist[Int(clamped * Float(satBins))] += 1
        }
        let satScale = 1.0 / Float(max(1, sats.count))
        satHist = satHist.map { $0 * satScale }

        let spatialBins = 8
        let cellH = side / 2
        let cellW = side / 2
        var spatialGrad = [Float]()
        spatialGrad.reserveCapacity(spatialBins * 4)

        for cellRow in 0..<2 {
            for cellCol in 0..<2 {
                var cellHist = [Float](repeating: 0, count: spatialBins)
                let yStart = cellRow * cellH + 1
                let yEnd = min((cellRow + 1) * cellH, side - 1)
                let xStart = cellCol * cellW + 1
                let xEnd = min((cellCol + 1) * cellW, side - 1)
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        let i = y * side + x
                        let gx = (gray[i + 1] - gray[i - 1]) * 0.5
                        let gy = (gray[i + side] - gray[i - side]) * 0.5
                        let magnitude = sqrt(gx * gx + gy * gy)
                        var angle = atan2(gy, gx)
                        if angle < 0 { angle += Float.pi * 2 }
                        let bin = min(spatialBins - 1, Int((angle / (Float.pi * 2)) * Float(spatialBins)))
                        cellHist[bin] += magnitude
                    }
                }
                cellHist = l1normalize(cellHist)
                spatialGrad.append(contentsOf: cellHist)
            }
        }

        return l2normalize(hist + grad + quad + hueHist + satHist + spatialGrad)
    }

    /// V4 embedding: v3 (108) + 3x3 spatial HOG (72) + rotation-invariant
    /// uniform LBP (10) + per-quadrant HSV colour moments (12) = **202** dims.
    ///
    /// Matches `embedding_for_image_bgr_v4()` in puzzle_embedding_utils.py.
    /// Design goals over v3: (a) finer intra-tile edge layout than v3's 2x2
    /// HOG, (b) a texture descriptor (LBP) that's orthogonal to colour, and
    /// (c) colour *layout* (per-quadrant HSV means), which v3's global hue/sat
    /// histograms collapse.
    static func colorEmbeddingV4(for image: CGImage, side: Int = 32) -> [Float]? {
        let source = centerInsetCrop(image, insetFraction: side <= 32 ? 0.22 : 0.0) ?? image
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        var gray = [Float](repeating: 0, count: side * side)
        var grayU8 = [UInt8](repeating: 0, count: side * side)
        var hues = [Float](repeating: 0, count: side * side)
        var sats = [Float](repeating: 0, count: side * side)
        var vals = [Float](repeating: 0, count: side * side)

        for i in 0..<(side * side) {
            let r = Float(raw[i * 4])
            let g = Float(raw[i * 4 + 1])
            let b = Float(raw[i * 4 + 2])
            let gy = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            gray[i] = gy
            grayU8[i] = UInt8(max(0.0, min(255.0, Float(gy * 255.0))))

            let cmax = max(r, max(g, b))
            let cmin = min(r, min(g, b))
            let delta = cmax - cmin
            sats[i] = cmax > 0 ? delta / cmax : 0
            vals[i] = cmax / 255.0

            var hue: Float = 0
            if delta > 0 {
                if cmax == r {
                    hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if cmax == g {
                    hue = 60 * ((b - r) / delta + 2)
                } else {
                    hue = 60 * ((r - g) / delta + 4)
                }
                if hue < 0 { hue += 360 }
            }
            hues[i] = hue / 360.0
        }

        // v3 base features.
        let hist = intensityHistogram(gray, bins: 32)
        let grad = gradientHistogram(gray, side: side, bins: 16)
        let quad = quadrantMeans(gray, side: side)

        let hueBins = 16
        var hueHist = [Float](repeating: 0, count: hueBins)
        for h in hues {
            let clamped = min(0.9999, max(0, h))
            hueHist[Int(clamped * Float(hueBins))] += 1
        }
        let hueScale = 1.0 / Float(max(1, hues.count))
        hueHist = hueHist.map { $0 * hueScale }

        let satBins = 8
        var satHist = [Float](repeating: 0, count: satBins)
        for s in sats {
            let clamped = min(0.9999, max(0, s))
            satHist[Int(clamped * Float(satBins))] += 1
        }
        let satScale = 1.0 / Float(max(1, sats.count))
        satHist = satHist.map { $0 * satScale }

        // v3 2x2 spatial HOG (8 bins x 4 cells = 32 dims).
        let coarseBins = 8
        let cellH2 = side / 2
        let cellW2 = side / 2
        var coarseHog = [Float]()
        coarseHog.reserveCapacity(coarseBins * 4)
        for cellRow in 0..<2 {
            for cellCol in 0..<2 {
                var cellHist = [Float](repeating: 0, count: coarseBins)
                let yStart = cellRow * cellH2 + 1
                let yEnd = min((cellRow + 1) * cellH2, side - 1)
                let xStart = cellCol * cellW2 + 1
                let xEnd = min((cellCol + 1) * cellW2, side - 1)
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        let i = y * side + x
                        let gx = (gray[i + 1] - gray[i - 1]) * 0.5
                        let gyv = (gray[i + side] - gray[i - side]) * 0.5
                        let mag = sqrt(gx * gx + gyv * gyv)
                        var ang = atan2(gyv, gx)
                        if ang < 0 { ang += Float.pi * 2 }
                        let bin = min(coarseBins - 1, Int((ang / (Float.pi * 2)) * Float(coarseBins)))
                        cellHist[bin] += mag
                    }
                }
                cellHist = l1normalize(cellHist)
                coarseHog.append(contentsOf: cellHist)
            }
        }

        let fineBins = 8
        let grid = 3
        var fineHog = [Float]()
        fineHog.reserveCapacity(fineBins * grid * grid)
        for r in 0..<grid {
            for c in 0..<grid {
                var cellHist = [Float](repeating: 0, count: fineBins)
                let r0 = (r * side) / grid
                let r1 = ((r + 1) * side) / grid
                let c0 = (c * side) / grid
                let c1 = ((c + 1) * side) / grid
                // Central differences inside the cell; border pixels contribute 0.
                let yStart = max(1, r0)
                let yEnd = min(side - 1, r1)
                let xStart = max(1, c0)
                let xEnd = min(side - 1, c1)
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        let i = y * side + x
                        let gx = (gray[i + 1] - gray[i - 1]) * 0.5
                        let gyv = (gray[i + side] - gray[i - side]) * 0.5
                        let mag = sqrt(gx * gx + gyv * gyv)
                        var ang = atan2(gyv, gx)
                        if ang < 0 { ang += Float.pi * 2 }
                        let bin = min(fineBins - 1, Int((ang / (Float.pi * 2)) * Float(fineBins)))
                        cellHist[bin] += mag
                    }
                }
                cellHist = l1normalize(cellHist)
                fineHog.append(contentsOf: cellHist)
            }
        }

        let lbpHist = lbpRotationInvariantUniformHistogram(grayU8: grayU8, side: side)

        let hsvMoments = perQuadrantHSVMoments(
            hues: hues, sats: sats, vals: vals, side: side
        )

        return l2normalize(
            hist + grad + quad + hueHist + satHist + coarseHog + fineHog + lbpHist + hsvMoments
        )
    }

    /// 8-neighbourhood LBP with rotation-invariant uniform pattern mapping.
    /// 10 bins: 0..8 = popcount of uniform patterns (≤2 transitions), 9 = non-uniform.
    private static func lbpRotationInvariantUniformHistogram(grayU8: [UInt8], side: Int) -> [Float] {
        guard side >= 3 else { return [Float](repeating: 0, count: 10) }
        let table = lbpUniformTable
        var hist = [Float](repeating: 0, count: 10)
        var total = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let c = grayU8[y * side + x]
                var code: UInt16 = 0
                if grayU8[(y - 1) * side + x]     >= c { code |= 1 << 0 }
                if grayU8[(y - 1) * side + x + 1] >= c { code |= 1 << 1 }
                if grayU8[y       * side + x + 1] >= c { code |= 1 << 2 }
                if grayU8[(y + 1) * side + x + 1] >= c { code |= 1 << 3 }
                if grayU8[(y + 1) * side + x]     >= c { code |= 1 << 4 }
                if grayU8[(y + 1) * side + x - 1] >= c { code |= 1 << 5 }
                if grayU8[y       * side + x - 1] >= c { code |= 1 << 6 }
                if grayU8[(y - 1) * side + x - 1] >= c { code |= 1 << 7 }
                hist[Int(table[Int(code)])] += 1
                total += 1
            }
        }
        if total > 0 {
            let scale = 1.0 / Float(total)
            hist = hist.map { $0 * scale }
        }
        return hist
    }

    /// Lookup table mapping each 8-bit LBP code to a rotation-invariant-uniform bucket:
    ///   * ≤2 bit-transitions ⇒ popcount of the code (0..8)
    ///   * otherwise          ⇒ 9 (non-uniform)
    /// Computed once; Swift lazily initialises static lets so this is thread-safe.
    private static let lbpUniformTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for code in 0..<256 {
            var bits = [Int](repeating: 0, count: 8)
            for i in 0..<8 { bits[i] = (code >> i) & 1 }
            var transitions = 0
            for i in 0..<8 where bits[i] != bits[(i + 1) % 8] { transitions += 1 }
            if transitions <= 2 {
                var count = 0
                for b in bits { count += b }
                table[code] = UInt8(count)
            } else {
                table[code] = 9
            }
        }
        return table
    }()

    private static func perQuadrantHSVMoments(
        hues: [Float], sats: [Float], vals: [Float], side: Int
    ) -> [Float] {
        let half = side / 2
        if half == 0 || half == side {
            return [Float](repeating: 0, count: 12)
        }
        // Ordering: TL, TR, BL, BR → (meanH, meanS, meanV) per quadrant.
        var sums = [Float](repeating: 0, count: 12)
        var counts = [Int](repeating: 0, count: 4)
        for y in 0..<side {
            for x in 0..<side {
                let q = (y < half ? 0 : 2) + (x < half ? 0 : 1)
                let i = y * side + x
                sums[q * 3 + 0] += hues[i]
                sums[q * 3 + 1] += sats[i]
                sums[q * 3 + 2] += vals[i]
                counts[q] += 1
            }
        }
        var out = [Float](repeating: 0, count: 12)
        for q in 0..<4 {
            let c = max(1, counts[q])
            out[q * 3 + 0] = sums[q * 3 + 0] / Float(c)
            out[q * 3 + 1] = sums[q * 3 + 1] / Float(c)
            out[q * 3 + 2] = sums[q * 3 + 2] / Float(c)
        }
        return out
    }

    static func tileEmbeddings(for canonicalGrid: CGImage) -> [[Float]?] {
        var out = [[Float]?](repeating: nil, count: 25)
        for idx in 0..<25 {
            let r = idx / 5
            let c = idx % 5
            let rect = cellRect(
                row: r,
                col: c,
                imageWidth: canonicalGrid.width,
                imageHeight: canonicalGrid.height,
                insetFraction: 0.16
            )
            guard let sub = canonicalGrid.cropping(to: rect) else { continue }
            out[idx] = embedding(for: sub, side: 32)
        }
        return out
    }

    private static func cellRect(
        row: Int,
        col: Int,
        imageWidth: Int,
        imageHeight: Int,
        insetFraction: CGFloat
    ) -> CGRect {
        // Integer partitioning guarantees contiguous non-overlapping cells.
        let x0 = CGFloat((col * imageWidth) / 5)
        let y0 = CGFloat((row * imageHeight) / 5)
        let x1 = CGFloat(((col + 1) * imageWidth) / 5)
        let y1 = CGFloat(((row + 1) * imageHeight) / 5)
        var w = max(1, x1 - x0)
        var h = max(1, y1 - y0)

        let edgeCount = (row == 0 || row == 4 ? 1 : 0) + (col == 0 || col == 4 ? 1 : 0)
        let localInset: CGFloat
        var adjustedInset: CGFloat
        switch edgeCount {
        case 2: adjustedInset = insetFraction + 0.08
        case 1: adjustedInset = insetFraction + 0.04
        default: adjustedInset = insetFraction
        }
        // Bottom row usually carries the strongest frame contamination.
        if row == 4 { adjustedInset += 0.04 }
        // Right edge also tends to retain frame bleed in this UI.
        if col == 4 { adjustedInset += 0.04 }
        localInset = adjustedInset
        let padX = min(max(1, Int(w * localInset)), max(1, Int((w - 1) / 2)))
        let padY = min(max(1, Int(h * localInset)), max(1, Int((h - 1) / 2)))
        let ix0 = x0 + CGFloat(padX)
        let iy0 = y0 + CGFloat(padY)
        let ix1 = x1 - CGFloat(padX)
        let iy1 = y1 - CGFloat(padY)
        if ix1 > ix0, iy1 > iy0 {
            return CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)
        }

        // Fallback if cell is too small for inset.
        w = max(1, x1 - x0)
        h = max(1, y1 - y0)
        return CGRect(x: x0, y: y0, width: w, height: h)
    }

    private static func centerInsetCrop(_ image: CGImage, insetFraction: CGFloat) -> CGImage? {
        guard insetFraction > 0 else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let padX = max(1, Int(w * insetFraction))
        let padY = max(1, Int(h * insetFraction))
        let rect = CGRect(
            x: CGFloat(padX),
            y: CGFloat(padY),
            width: max(1, w - CGFloat(padX * 2)),
            height: max(1, h - CGFloat(padY * 2))
        )
        return image.cropping(to: rect)
    }

    private static func renderGrayscale(_ image: CGImage, side: Int) -> [Float]? {
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Float](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            gray[i] = (0.299 * Float(raw[i * 4]) + 0.587 * Float(raw[i * 4 + 1]) + 0.114 * Float(raw[i * 4 + 2])) / 255.0
        }
        return gray
    }

    private static func intensityHistogram(_ gray: [Float], bins: Int) -> [Float] {
        var hist = [Float](repeating: 0, count: bins)
        for px in gray {
            let clamped = min(0.9999, max(0, px))
            hist[Int(clamped * Float(bins))] += 1
        }
        let scale = 1.0 / Float(max(1, gray.count))
        return hist.map { $0 * scale }
    }

    private static func gradientHistogram(_ gray: [Float], side: Int, bins: Int) -> [Float] {
        if side < 3 { return [Float](repeating: 0, count: bins) }
        var hist = [Float](repeating: 0, count: bins)
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let gx = (gray[i + 1] - gray[i - 1]) * 0.5
                let gy = (gray[i + side] - gray[i - side]) * 0.5
                let mag = sqrt(gx * gx + gy * gy)
                var angle = atan2(gy, gx)
                if angle < 0 { angle += Float.pi * 2 }
                let bin = min(bins - 1, Int((angle / (Float.pi * 2)) * Float(bins)))
                hist[bin] += mag
            }
        }
        return l1normalize(hist)
    }

    private static func quadrantMeans(_ gray: [Float], side: Int) -> [Float] {
        let half = side / 2
        if half == 0 { return [Float](repeating: 0, count: 4) }
        var sums = [Float](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)
        for y in 0..<side {
            for x in 0..<side {
                let q = (y < half ? 0 : 2) + (x < half ? 0 : 1)
                sums[q] += gray[y * side + x]
                counts[q] += 1
            }
        }
        return (0..<4).map { idx in
            guard counts[idx] > 0 else { return 0 }
            return sums[idx] / Float(counts[idx])
        }
    }

    private static func l1normalize(_ vector: [Float]) -> [Float] {
        let sum = vector.reduce(0, +)
        guard sum > 1e-6 else { return vector }
        return vector.map { $0 / sum }
    }

    private static func l2normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        for v in vector { norm += v * v }
        norm = sqrt(norm)
        guard norm > 1e-6 else { return vector }
        return vector.map { $0 / norm }
    }
}
