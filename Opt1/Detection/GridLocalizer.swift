import CoreGraphics
import Foundation
import Vision

struct GridLocalization {
    let gridRectInImage: CGRect
    let canonicalGridImage: CGImage
    let cellSize: CGSize
    let sourceHintRect: CGRect?
    let localizationScore: Float
    let method: String
}
final class GridLocalizer {
    private let canonicalSize = 500
    private let maxROIDimension: CGFloat = 1400

    func localizeGrid(
        in image: CGImage,
        mode: PuzzleDetectionPipeline.InputMode,
        preferredSearchRect: CGRect? = nil
    ) -> GridLocalization? {
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let roi: CGRect
        switch mode {
        case .snipCrop:
            roi = imageRect
        case .fullFrame:
            roi = preferredSearchRect ?? deriveROIFromControlText(in: image) ?? imageRect
        }

        let clampedROI = roi.intersection(imageRect).integral
        guard clampedROI.width >= 40, clampedROI.height >= 40 else { return nil }

        let maxSide = max(clampedROI.width, clampedROI.height)
        let scale: CGFloat = maxSide > maxROIDimension ? maxROIDimension / maxSide : 1.0
        guard let roiPixels = extractROIPixels(image: image, rect: clampedROI, scale: scale) else { return nil }

        if let railsHit = detectRails(rgb: roiPixels.rgb, width: roiPixels.width, height: roiPixels.height) {
            return finalize(
                image: image,
                imageRect: imageRect,
                roi: clampedROI,
                rectInROI: railsHit.rect,
                roiScale: scale,
                score: railsHit.score,
                method: "rails"
            )
        }
        if let innerHit = detectInnerFrame(rgb: roiPixels.rgb, width: roiPixels.width, height: roiPixels.height) {
            return finalize(
                image: image,
                imageRect: imageRect,
                roi: clampedROI,
                rectInROI: innerHit.rect,
                roiScale: scale,
                score: innerHit.score,
                method: "inner_frame"
            )
        }
        return nil
    }

    // MARK: - Finalization

    private func finalize(
        image: CGImage,
        imageRect: CGRect,
        roi: CGRect,
        rectInROI: CGRect,
        roiScale: CGFloat,
        score: Float,
        method: String
    ) -> GridLocalization? {
        let inv: CGFloat = roiScale > 0 ? 1.0 / roiScale : 1.0
        let rectInImage = CGRect(
            x: roi.minX + rectInROI.minX * inv,
            y: roi.minY + rectInROI.minY * inv,
            width: rectInROI.width * inv,
            height: rectInROI.height * inv
        ).intersection(imageRect).integral
        guard rectInImage.width >= 100, rectInImage.height >= 100 else { return nil }
        guard let canonical = rasterize(image, rect: rectInImage, targetSize: canonicalSize) else { return nil }
        let cell = CGSize(width: rectInImage.width / 5.0, height: rectInImage.height / 5.0)
        return GridLocalization(
            gridRectInImage: rectInImage,
            canonicalGridImage: canonical,
            cellSize: cell,
            sourceHintRect: roi.equalTo(imageRect) ? nil : roi,
            localizationScore: score,
            method: method
        )
    }

    // MARK: - Control-text ROI pre-filter (unchanged from prior version)

    private func deriveROIFromControlText(in image: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try handler.perform([request]) } catch { return nil }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        var anchors: [CGRect] = []
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let lower = top.string.lowercased()
            let isAnchor = lower.contains("hint") || lower.contains("reset") || lower.contains("check") ||
                (lower.contains("invert") && lower.contains("keyboard"))
            guard isAnchor else { continue }
            let bb = obs.boundingBox
            let pixel = CGRect(
                x: bb.minX * imgW,
                y: (1.0 - bb.maxY) * imgH,
                width: bb.width * imgW,
                height: bb.height * imgH
            )
            anchors.append(pixel)
        }
        guard !anchors.isEmpty else { return nil }
        let union = anchors.reduce(anchors[0]) { $0.union($1) }
        let search = CGRect(
            x: union.maxX + union.width * 0.4,
            y: max(0, union.minY - union.height * 2.0),
            width: imgW - (union.maxX + union.width * 0.4),
            height: min(imgH, union.height * 18.0)
        )
        let clamped = search.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        return clamped.width > 80 && clamped.height > 80 ? clamped : nil
    }

    // MARK: - ROI pixel extraction

    /// 24-bit RGB buffer sized `width * height * 3`. Stored as a contiguous
    /// row-major array so downstream detectors can use plain integer indices
    /// without worrying about stride.
    private struct ROIPixels {
        let rgb: [UInt8]
        let width: Int
        let height: Int
    }

    /// Extracts the ROI as a contiguous RGB buffer. When `scale < 1` the ROI is
    /// drawn into a smaller context using bilinear interpolation so detectors
    /// run on a bounded pixel budget; the caller is responsible for un-scaling
    /// any resulting rectangles back into the original ROI coordinate frame.
    private func extractROIPixels(image: CGImage, rect: CGRect, scale: CGFloat = 1.0) -> ROIPixels? {
        let w = max(1, Int((rect.width * scale).rounded()))
        let h = max(1, Int((rect.height * scale).rounded()))
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let drawRect = CGRect(
            x: -rect.minX * scale,
            y: -rect.minY * scale,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        ctx.interpolationQuality = scale < 1.0 ? .low : .none
        ctx.draw(image, in: drawRect)
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            out[i * 3] = raw[i * 4]
            out[i * 3 + 1] = raw[i * 4 + 1]
            out[i * 3 + 2] = raw[i * 4 + 2]
        }
        return ROIPixels(rgb: out, width: w, height: h)
    }

    // MARK: - Rails detector

    private struct RailsHit {
        let rect: CGRect
        let score: Float
    }

    private func detectRails(rgb: [UInt8], width w: Int, height h: Int) -> RailsHit? {
        guard h >= 40, w >= 40 else { return nil }

        // Grayscale in [0,1] with the standard ITU-R BT.601 weights OpenCV uses.
        var gray = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgb[i * 3])
            let g = Float(rgb[i * 3 + 1])
            let b = Float(rgb[i * 3 + 2])
            gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        var colProfile = [Float](repeating: 0, count: w)
        var rowProfile = [Float](repeating: 0, count: h)
        if w >= 3, h >= 3 {
            for y in 1..<(h - 1) {
                let rowBase = y * w
                for x in 1..<(w - 1) {
                    let i = rowBase + x
                    let tl = gray[i - w - 1], t = gray[i - w], tr = gray[i - w + 1]
                    let l  = gray[i - 1],     r = gray[i + 1]
                    let bl = gray[i + w - 1], bt = gray[i + w], br = gray[i + w + 1]
                    let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                    let gy = (bl + 2 * bt + br) - (tl + 2 * t + tr)
                    colProfile[x] += abs(gx)
                    rowProfile[y] += abs(gy)
                }
            }
        }

        guard let colFit = fitPeriodicPeaks(signal: colProfile) else { return nil }
        guard let rowFit = fitPeriodicPeaks(signal: rowProfile) else { return nil }
        if colFit.score < 0.15 || rowFit.score < 0.15 { return nil }
        if colFit.regularity < 0.80 || rowFit.regularity < 0.80 { return nil }

        let xLeft = colFit.peaks.first ?? 0
        let xRight = colFit.peaks.last ?? 0
        let yTop = rowFit.peaks.first ?? 0
        let yBot = rowFit.peaks.last ?? 0
        let ww = xRight - xLeft
        let hh = yBot - yTop
        if ww < 100 || hh < 100 { return nil }

        let shape = 1.0 - Float(abs(ww - hh)) / max(1.0, Float(ww))
        let peakScore = 0.5 * (colFit.score + rowFit.score)
        let regularity = 0.5 * (colFit.regularity + rowFit.regularity)
        let score = max(0.0, min(1.0, 0.45 * peakScore + 0.35 * regularity + 0.20 * shape))

        let rect = CGRect(x: xLeft, y: yTop, width: ww, height: hh)
        return RailsHit(rect: rect, score: score)
    }

    private struct PeakFit {
        let peaks: [Int]
        let score: Float
        let regularity: Float
    }

    /// Brute-force search for `count` evenly-spaced peaks in a 1D signal.
    /// Parameters are tuned to match `inner_grid_localizers._fit_periodic_peaks`.
    private func fitPeriodicPeaks(
        signal: [Float],
        count: Int = 6,
        minSpacingFrac: Float = 0.10,
        maxSpacingFrac: Float = 0.25,
        toleranceFrac: Float = 0.015,
        smoothingFrac: Float = 0.005
    ) -> PeakFit? {
        let n = signal.count
        if n < 10 { return nil }
        let ms = max(2, Int((minSpacingFrac * Float(n)).rounded()))
        let MS = max(ms + 1, Int((maxSpacingFrac * Float(n)).rounded()))
        let tol = max(1, Int((toleranceFrac * Float(n)).rounded()))
        let smoothRadius = max(1, Int((smoothingFrac * Float(n)).rounded()))

        let smooth = boxFilter1D(signal: signal, radius: smoothRadius)
        let norm = normalizeUnit(smooth)

        var best: PeakFit?
        for s in ms...MS {
            let totalSpan = s * (count - 1)
            let x0Max = n - 1 - totalSpan
            if x0Max < 0 { continue }
            for x0 in 0...x0Max {
                var scoreSum: Float = 0
                var peaks = [Int](repeating: 0, count: count)
                var valid = true
                for k in 0..<count {
                    let p = x0 + k * s
                    let lo = max(0, p - tol)
                    let hi = min(n, p + tol + 1)
                    if hi <= lo { valid = false; break }
                    var bestVal: Float = -.infinity
                    var bestIdx = lo
                    for j in lo..<hi {
                        let v = norm[j]
                        if v > bestVal { bestVal = v; bestIdx = j }
                    }
                    scoreSum += bestVal
                    peaks[k] = bestIdx
                }
                if !valid { continue }
                let score = scoreSum / Float(count)
                if let b = best, score <= b.score { continue }

                // Regularity = 1 - stdev(gaps)/mean(gaps), clamped to [0, 1].
                var gaps = [Float]()
                gaps.reserveCapacity(count - 1)
                for k in 1..<count {
                    gaps.append(Float(peaks[k] - peaks[k - 1]))
                }
                var reg: Float = 0
                if !gaps.isEmpty {
                    let mean = gaps.reduce(0, +) / Float(gaps.count)
                    if mean > 1e-3 {
                        let variance = gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(gaps.count)
                        let std = sqrt(max(0, variance))
                        reg = max(0, 1 - std / mean)
                    }
                }
                reg = max(0, min(1, reg))

                best = PeakFit(peaks: peaks, score: score, regularity: reg)
            }
        }
        return best
    }

    private func boxFilter1D(signal: [Float], radius: Int) -> [Float] {
        if radius <= 0 { return signal }
        let n = signal.count
        var out = [Float](repeating: 0, count: n)
        let window = 2 * radius + 1
        let inv = 1.0 / Float(window)
        for i in 0..<n {
            var sum: Float = 0
            for k in -radius...radius {
                // `mode='same'` with implicit zero padding. The Python version
                // uses `np.convolve(..., mode='same')` which also pads with
                // zeros when the kernel extends past the edge; matching that
                // here keeps the normalized signal comparable end-to-end.
                let j = i + k
                if j >= 0, j < n { sum += signal[j] }
            }
            out[i] = sum * inv
        }
        return out
    }

    private func normalizeUnit(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return signal }
        var lo = signal[0], hi = signal[0]
        for v in signal {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        if hi - lo < 1e-6 { return [Float](repeating: 0, count: signal.count) }
        let scale = 1.0 / (hi - lo)
        return signal.map { ($0 - lo) * scale }
    }

    // MARK: - Inner-frame detector

    private struct InnerFrameHit {
        let rect: CGRect
        let score: Float
    }

    private func detectInnerFrame(rgb: [UInt8], width w: Int, height h: Int) -> InnerFrameHit? {
        guard h >= 40, w >= 40 else { return nil }

        var mask = [UInt8](repeating: 0, count: w * h)
        var brownPixels = 0
        for i in 0..<(w * h) {
            let r = rgb[i * 3]
            let g = rgb[i * 3 + 1]
            let b = rgb[i * 3 + 2]
            if isBrown(r: r, g: g, b: b) {
                mask[i] = 1
                brownPixels += 1
            }
        }
        if brownPixels < 600 { return nil }

        let dilated = runningMax2D(mask: mask, width: w, height: h, radius: 4)
        let closed = runningMin2D(mask: dilated, width: w, height: h, radius: 4)

        // Invert and flood-fill connected components (4-connectivity).
        var inv = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { inv[i] = closed[i] == 0 ? 1 : 0 }

        let marginX = max(0, Int((0.03 * Float(w)).rounded()))
        let marginY = max(0, Int((0.03 * Float(h)).rounded()))
        let minArea = max(50, Int((0.0005 * Float(w * h)).rounded()))

        var labels = [Int](repeating: 0, count: w * h)
        var nextLabel = 1
        var queue = [Int]()
        queue.reserveCapacity(1024)

        struct Component {
            var minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int
        }
        var interior: [Component] = []

        for y in 0..<h {
            for x in 0..<w {
                let start = y * w + x
                if inv[start] == 0 || labels[start] != 0 { continue }
                labels[start] = nextLabel
                queue.removeAll(keepingCapacity: true)
                queue.append(start)
                var qi = 0
                var comp = Component(minX: x, minY: y, maxX: x, maxY: y, area: 0)
                while qi < queue.count {
                    let p = queue[qi]
                    qi += 1
                    let px = p % w
                    let py = p / w
                    comp.area += 1
                    if px < comp.minX { comp.minX = px }
                    if py < comp.minY { comp.minY = py }
                    if px > comp.maxX { comp.maxX = px }
                    if py > comp.maxY { comp.maxY = py }

                    if px > 0 {
                        let n = p - 1
                        if inv[n] == 1, labels[n] == 0 {
                            labels[n] = nextLabel; queue.append(n)
                        }
                    }
                    if px < w - 1 {
                        let n = p + 1
                        if inv[n] == 1, labels[n] == 0 {
                            labels[n] = nextLabel; queue.append(n)
                        }
                    }
                    if py > 0 {
                        let n = p - w
                        if inv[n] == 1, labels[n] == 0 {
                            labels[n] = nextLabel; queue.append(n)
                        }
                    }
                    if py < h - 1 {
                        let n = p + w
                        if inv[n] == 1, labels[n] == 0 {
                            labels[n] = nextLabel; queue.append(n)
                        }
                    }
                }
                nextLabel += 1

                let cw = comp.maxX - comp.minX + 1
                let ch = comp.maxY - comp.minY + 1
                let touchesBoundary =
                    comp.minX <= marginX ||
                    comp.minY <= marginY ||
                    comp.minX + cw - 1 >= w - 1 - marginX ||
                    comp.minY + ch - 1 >= h - 1 - marginY
                if touchesBoundary { continue }
                if comp.area < minArea { continue }
                interior.append(comp)
            }
        }

        if interior.isEmpty { return nil }
        var minX = interior[0].minX
        var minY = interior[0].minY
        var maxX = interior[0].maxX
        var maxY = interior[0].maxY
        for c in interior {
            if c.minX < minX { minX = c.minX }
            if c.minY < minY { minY = c.minY }
            if c.maxX > maxX { maxX = c.maxX }
            if c.maxY > maxY { maxY = c.maxY }
        }
        let ww = maxX - minX + 1
        let hh = maxY - minY + 1
        if ww < 100 || hh < 100 { return nil }

        let shape = 1.0 - Float(abs(ww - hh)) / max(1.0, Float(ww))
        let areaRatio = Float(ww * hh) / max(1.0, Float(w * h))
        let content = max(0.05, min(1.0, areaRatio * 1.8))
        let score = max(0.0, min(1.0, 0.45 * shape + 0.55 * content))

        let rect = CGRect(x: minX, y: minY, width: ww, height: hh)
        return InnerFrameHit(rect: rect, score: score)
    }

    /// O(n) running-max 2D box filter with radius `r` (window 2r+1) using the
    /// monotonic-deque trick separately along rows and columns. Matches
    /// `cv2.dilate` with a rect SE of matching radius.
    private func runningMax2D(mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var rowOut = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let base = y * w
            // Windows are small (r<=4 in practice), so an explicit loop is
            // cheaper than a monotonic-deque sliding max and has tighter
            // instruction-cache footprint.
            for x in 0..<w {
                var mx: UInt8 = 0
                let lo = max(0, x - r)
                let hi = min(w - 1, x + r)
                for i in lo...hi { if mask[base + i] > mx { mx = mask[base + i] } }
                rowOut[base + x] = mx
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            for y in 0..<h {
                var mx: UInt8 = 0
                let lo = max(0, y - r)
                let hi = min(h - 1, y + r)
                for i in lo...hi { if rowOut[i * w + x] > mx { mx = rowOut[i * w + x] } }
                out[y * w + x] = mx
            }
        }
        return out
    }

    private func runningMin2D(mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var rowOut = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let base = y * w
            for x in 0..<w {
                var mn: UInt8 = 1
                let lo = max(0, x - r)
                let hi = min(w - 1, x + r)
                for i in lo...hi { if mask[base + i] < mn { mn = mask[base + i] } }
                rowOut[base + x] = mn
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            for y in 0..<h {
                var mn: UInt8 = 1
                let lo = max(0, y - r)
                let hi = min(h - 1, y + r)
                for i in lo...hi { if rowOut[i * w + x] < mn { mn = rowOut[i * w + x] } }
                out[y * w + x] = mn
            }
        }
        return out
    }

    /// Brown-pixel predicate shared with Python's `_is_brown_mask` in
    /// `Opt1/Scripts/puzzle_localizer.py`. Any change here must update both.
    private func isBrown(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let rf = Int(r), gf = Int(g), bf = Int(b)
        if rf < 48 || gf < 30 || bf > 140 { return false }
        if rf <= gf + 6 { return false }
        return bf < gf + 20
    }

    // MARK: - Canonical rasterization

    private func rasterize(_ image: CGImage, rect: CGRect, targetSize: Int) -> CGImage? {
        guard let crop = image.cropping(to: rect.integral) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: targetSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        return ctx.makeImage()
    }
}
