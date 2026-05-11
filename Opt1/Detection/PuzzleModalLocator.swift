import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Opt1Detection

struct PuzzleModalAnchorMatch {
    let xMatchInImage: CGRect
    let pinnedAnchor: LoadedAnchor
    let matchedAnchorKey: String
    let confidence: Float
    let searchToImageScale: CGFloat
}

struct PuzzleModalAnchorCandidate {
    let xMatchInImage: CGRect
    let anchor: LoadedAnchor
    let pinnedAnchor: LoadedAnchor
    let anchorKey: String
    let confidence: Float
    let searchToImageScale: CGFloat
}

struct LoadedAnchor {
    let key: String
    let pixels: [Float]
    let size: (w: Int, h: Int)
    let offset: SliderAnchorOffset
}

/// Shared close-X modal locator for puzzle interfaces that use the same NXT
/// modal chrome as slider puzzles.
final class PuzzleModalLocator {
    static let confidenceThreshold: Float = 0.92
    static let bracketedConfidenceThreshold: Float = 0.80

    private let configuration: DetectionConfiguration
    private lazy var anchors: [LoadedAnchor] = loadAllAnchors(resourceProvider: configuration.resources)

    init(configuration: DetectionConfiguration = .appDefault) {
        self.configuration = configuration
    }

    func locateCloseButton(
        in image: CGImage,
        logicalWindowWidth: CGFloat? = nil,
        bracketedConfidenceThreshold: Float = PuzzleModalLocator.bracketedConfidenceThreshold,
        onNoMatchCandidate: ((PuzzleModalAnchorCandidate) -> Void)? = nil,
        logPrefix: String = "PuzzleModalLocator"
    ) -> PuzzleModalAnchorMatch? {
        guard !anchors.isEmpty else {
            print("[\(logPrefix)] No anchors loaded — puzzle modal auto-detect unavailable (collect samples via Developer menu)")
            return nil
        }

        let pinnedScale = configuration.puzzleUIScalePercent ?? configuration.defaultPuzzleUIScale
        let bracketedScales = Self.bracketedScales(
            around: pinnedScale,
            supportedScales: configuration.supportedPuzzleUIScales,
            defaultScale: configuration.defaultPuzzleUIScale
        )
        let bracketedKeys = Set(bracketedScales.map { "scale_\($0)" })
        let pinnedKey = "scale_\(pinnedScale)"

        let dpr: CGFloat
        if let logicalWidth = logicalWindowWidth, logicalWidth > 0 {
            dpr = CGFloat(image.width) / logicalWidth
        } else {
            dpr = 1.0
        }

        let searchImage: CGImage
        let searchScale: CGFloat
        if dpr > 1.05 {
            let logW = Int(round(CGFloat(image.width) / dpr))
            let logH = Int(round(CGFloat(image.height) / dpr))
            searchImage = downsample(image, to: CGSize(width: logW, height: logH)) ?? image
            searchScale = dpr
        } else {
            searchImage = image
            searchScale = 1.0
        }

        print("[\(logPrefix)] Searching \(searchImage.width)×\(searchImage.height) px (dpr=\(String(format: "%.2f", dpr)))")
        let t0 = Date()

        guard let haystack = HaystackData(image: searchImage) else {
            print("[\(logPrefix)] Failed to build haystack data")
            return nil
        }
        let tHay = Date().timeIntervalSince(t0)

        var allResults: [(key: String, score: Float, x: Int, y: Int, anchor: LoadedAnchor)] = []
        for anchor in anchors {
            guard let match = findBestNCC(
                needle: anchor.pixels,
                needleSize: anchor.size,
                haystack: haystack
            ) else { continue }
            allResults.append((anchor.key, match.score, match.x, match.y, anchor))
        }

        let elapsed = Date().timeIntervalSince(t0)
        let timing = "haystack=\(String(format: "%.2f", tHay))s total=\(String(format: "%.2f", elapsed))s"
        allResults.sort { $0.score > $1.score }
        let dist = allResults
            .map { "\($0.key)=\(String(format: "%.3f", $0.score))" }
            .joined(separator: " ")

        guard let geometryAnchor = anchors.first(where: { $0.key == pinnedKey }) else {
            print("[\(logPrefix)] Pinned anchor '\(pinnedKey)' is not loaded — cannot derive modal geometry. Settings → RuneScape UI scale must point to a scale we ship needles for.")
            return nil
        }

        let inBracket = allResults.filter { bracketedKeys.contains($0.key) }
        if let winner = inBracket.first, winner.score >= bracketedConfidenceThreshold {
            let matchRectInImage = CGRect(
                x: CGFloat(winner.x) * searchScale,
                y: CGFloat(winner.y) * searchScale,
                width: CGFloat(winner.anchor.size.w) * searchScale,
                height: CGFloat(winner.anchor.size.h) * searchScale
            )
            let geomNote = winner.key == pinnedKey
                ? ""
                : " (geometry from pinned \(pinnedKey))"
            print("[\(logPrefix)] Matched '\(winner.key)' conf=\(String(format: "%.3f", winner.score)) (pinned \(pinnedScale)%, bracket \(bracketedScales.map(String.init).joined(separator: "/")))\(geomNote) x=(\(Int(matchRectInImage.minX)),\(Int(matchRectInImage.minY)) \(Int(matchRectInImage.width))×\(Int(matchRectInImage.height))) [\(timing)]")
            print("[\(logPrefix)] scores: \(dist)")
            return PuzzleModalAnchorMatch(
                xMatchInImage: matchRectInImage,
                pinnedAnchor: geometryAnchor,
                matchedAnchorKey: winner.key,
                confidence: winner.score,
                searchToImageScale: searchScale
            )
        }

        if let openBest = allResults.first {
            let bracketBest = inBracket.first
            let bracketDesc = bracketBest.map { "\($0.key)=\(String(format: "%.3f", $0.score))" } ?? "n/a"
            print("[\(logPrefix)] No bracket match (pinned \(pinnedScale)%, threshold \(bracketedConfidenceThreshold)) — bracket best \(bracketDesc), open best '\(openBest.key)'=\(String(format: "%.3f", openBest.score)) [\(timing)]")
            print("[\(logPrefix)] scores: \(dist)")
            if !bracketedKeys.contains(openBest.key) {
                print("[\(logPrefix)] Hint: best-scoring anchor is outside the bracket — your pinned UI scale (\(pinnedScale)%) may not match what RS is actually rendering.")
            }

            let diag = bracketBest ?? openBest
            let diagMatchInImage = CGRect(
                x: CGFloat(diag.x) * searchScale,
                y: CGFloat(diag.y) * searchScale,
                width: CGFloat(diag.anchor.size.w) * searchScale,
                height: CGFloat(diag.anchor.size.h) * searchScale
            )
            onNoMatchCandidate?(PuzzleModalAnchorCandidate(
                xMatchInImage: diagMatchInImage,
                anchor: diag.anchor,
                pinnedAnchor: geometryAnchor,
                anchorKey: diag.key,
                confidence: diag.score,
                searchToImageScale: searchScale
            ))
        } else {
            print("[\(logPrefix)] No candidates found [\(timing)]")
        }
        return nil
    }

    static func bracketedScales(
        around pinned: Int,
        supportedScales: [Int] = AppSettings.supportedPuzzleUIScales,
        defaultScale: Int = AppSettings.defaultPuzzleUIScale
    ) -> [Int] {
        let scales = supportedScales
        guard let idx = scales.firstIndex(of: pinned) else {
            let fallback = defaultScale
            return scales.firstIndex(of: fallback).map { i in
                Array(scales[max(0, i - 1) ... min(scales.count - 1, i + 1)])
            } ?? scales
        }
        let lo = max(0, idx - 1)
        let hi = min(scales.count - 1, idx + 1)
        return Array(scales[lo ... hi])
    }

    private struct NCCMatch {
        let x: Int
        let y: Int
        let score: Float
    }

    private func findBestNCC(
        needle: [Float],
        needleSize: (w: Int, h: Int),
        haystack: HaystackData
    ) -> NCCMatch? {
        let nW = needleSize.w
        let nH = needleSize.h
        let hW = haystack.width
        let hH = haystack.height
        guard hW >= nW, hH >= nH else { return nil }

        let searchW = hW - nW + 1
        let searchH = hH - nH + 1

        let nCount = Float(nW * nH)
        let needleSum: Float = {
            var s: Float = 0
            vDSP_sve(needle, 1, &s, vDSP_Length(needle.count))
            return s
        }()
        let needleMean = needleSum / nCount
        var needleSqSum: Float = 0
        vDSP_svesq(needle, 1, &needleSqSum, vDSP_Length(needle.count))
        let needleVar = needleSqSum / nCount - needleMean * needleMean
        guard needleVar > 1e-8 else { return nil }
        let needleStd = sqrtf(needleVar)

        let coarseStride = max(4, min(nW, nH) / 4)
        let topK = 16
        var topCandidates: [(score: Float, x: Int, y: Int)] = []
        topCandidates.reserveCapacity(topK + 1)

        func tryInsert(score: Float, x: Int, y: Int) {
            if topCandidates.count < topK {
                topCandidates.append((score, x, y))
                if topCandidates.count == topK {
                    topCandidates.sort { $0.score < $1.score }
                }
                return
            }
            if score > topCandidates[0].score {
                topCandidates[0] = (score, x, y)
                topCandidates.sort { $0.score < $1.score }
            }
        }

        var sy = 0
        while sy < searchH {
            var sx = 0
            while sx < searchW {
                if let score = nccAt(
                    sx: sx, sy: sy,
                    nW: nW, nH: nH,
                    haystack: haystack,
                    needle: needle,
                    nCount: nCount,
                    needleMean: needleMean,
                    needleStd: needleStd
                ) {
                    tryInsert(score: score, x: sx, y: sy)
                }
                sx += coarseStride
            }
            sy += coarseStride
        }

        guard !topCandidates.isEmpty else { return nil }

        var bestScore: Float = -1
        var bestX = 0
        var bestY = 0

        for cand in topCandidates {
            let x0 = max(0, cand.x - coarseStride)
            let x1 = min(searchW - 1, cand.x + coarseStride)
            let y0 = max(0, cand.y - coarseStride)
            let y1 = min(searchH - 1, cand.y + coarseStride)

            for fsy in y0 ... y1 {
                for fsx in x0 ... x1 {
                    if let score = nccAt(
                        sx: fsx, sy: fsy,
                        nW: nW, nH: nH,
                        haystack: haystack,
                        needle: needle,
                        nCount: nCount,
                        needleMean: needleMean,
                        needleStd: needleStd
                    ), score > bestScore {
                        bestScore = score
                        bestX = fsx
                        bestY = fsy
                    }
                }
            }
        }

        guard bestScore > -1 else { return nil }
        return NCCMatch(x: bestX, y: bestY, score: bestScore)
    }

    @inline(__always)
    private func nccAt(
        sx: Int, sy: Int,
        nW: Int, nH: Int,
        haystack: HaystackData,
        needle: [Float],
        nCount: Float,
        needleMean: Float, needleStd: Float
    ) -> Float? {
        let patchSum = haystack.rectSum(x: sx, y: sy, w: nW, h: nH)
        let patchSumSq = haystack.rectSumSq(x: sx, y: sy, w: nW, h: nH)
        let patchMean = patchSum / nCount
        let patchVar = patchSumSq / nCount - patchMean * patchMean
        guard patchVar > 1e-8 else { return nil }
        let patchStd = sqrtf(patchVar)

        var crossCorr: Float = 0
        let hW = haystack.width
        haystack.pixels.withUnsafeBufferPointer { hPtr in
            needle.withUnsafeBufferPointer { nPtr in
                for ny in 0 ..< nH {
                    let hStart = hPtr.baseAddress!.advanced(by: (sy + ny) * hW + sx)
                    let nStart = nPtr.baseAddress!.advanced(by: ny * nW)
                    var rowDot: Float = 0
                    vDSP_dotpr(hStart, 1, nStart, 1, &rowDot, vDSP_Length(nW))
                    crossCorr += rowDot
                }
            }
        }

        return (crossCorr / nCount - needleMean * patchMean) / (needleStd * patchStd)
    }

    private struct HaystackData {
        let pixels: [Float]
        let width: Int
        let height: Int
        let integral: [Double]
        let integralSq: [Double]

        init?(image: CGImage) {
            let w = image.width
            let h = image.height
            let bytesPerRow = w * 4
            var rawBytes = [UInt8](repeating: 0, count: h * bytesPerRow)

            guard let ctx = CGContext(
                data: &rawBytes,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

            var floats = [Float](repeating: 0, count: w * h)
            for i in 0 ..< w * h {
                let r = Float(rawBytes[i * 4])
                let g = Float(rawBytes[i * 4 + 1])
                let b = Float(rawBytes[i * 4 + 2])
                floats[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            }

            let iw = w + 1
            let ih = h + 1
            var integ = [Double](repeating: 0, count: iw * ih)
            var integSq = [Double](repeating: 0, count: iw * ih)
            for y in 0 ..< h {
                var rowSum: Double = 0
                var rowSumSq: Double = 0
                for x in 0 ..< w {
                    let v = Double(floats[y * w + x])
                    rowSum += v
                    rowSumSq += v * v
                    integ[(y + 1) * iw + (x + 1)] = integ[y * iw + (x + 1)] + rowSum
                    integSq[(y + 1) * iw + (x + 1)] = integSq[y * iw + (x + 1)] + rowSumSq
                }
            }

            self.pixels = floats
            self.width = w
            self.height = h
            self.integral = integ
            self.integralSq = integSq
        }

        @inline(__always)
        func rectSum(x: Int, y: Int, w: Int, h: Int) -> Float {
            let iw = width + 1
            let a = integral[y * iw + x]
            let b = integral[y * iw + (x + w)]
            let c = integral[(y + h) * iw + x]
            let d = integral[(y + h) * iw + (x + w)]
            return Float(d - b - c + a)
        }

        @inline(__always)
        func rectSumSq(x: Int, y: Int, w: Int, h: Int) -> Float {
            let iw = width + 1
            let a = integralSq[y * iw + x]
            let b = integralSq[y * iw + (x + w)]
            let c = integralSq[(y + h) * iw + x]
            let d = integralSq[(y + h) * iw + (x + w)]
            return Float(d - b - c + a)
        }
    }

    private func downsample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

private func loadAllAnchors(resourceProvider: Opt1ResourceProviding = BundleResourceProvider()) -> [LoadedAnchor] {
    guard let offsetsURL = resourceProvider.url(
        forResource: "anchor_offsets",
        withExtension: "json",
        subdirectory: "SliderAnchors"
    ),
        let offsetsData = try? Data(contentsOf: offsetsURL),
        let offsets = try? JSONDecoder().decode([String: SliderAnchorOffset].self, from: offsetsData)
    else {
        print("[PuzzleModalLocator] anchor_offsets.json not found in bundle — puzzle modal auto-detect disabled")
        return []
    }

    var anchors: [LoadedAnchor] = []
    let pixelLoader = PuzzleModalBundlePixelLoader()
    for (key, offset) in offsets {
        guard let pngURL = resourceProvider.url(
            forResource: key,
            withExtension: "png",
            subdirectory: "SliderAnchors/anchors"
        ),
            let provider = CGDataProvider(url: pngURL as CFURL),
            let cgImage = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            print("[PuzzleModalLocator] Missing needle PNG for key '\(key)' — skipping")
            continue
        }

        guard let pixels = pixelLoader.grayPixels(of: cgImage) else {
            print("[PuzzleModalLocator] Failed to convert needle '\(key)' to grayscale — skipping")
            continue
        }
        anchors.append(LoadedAnchor(
            key: key,
            pixels: pixels,
            size: (w: cgImage.width, h: cgImage.height),
            offset: offset
        ))
        print("[PuzzleModalLocator] Loaded anchor '\(key)' (\(cgImage.width)×\(cgImage.height) px)")
    }
    print("[PuzzleModalLocator] Loaded \(anchors.count) anchor(s)")
    return anchors
}

private struct PuzzleModalBundlePixelLoader {
    func grayPixels(of image: CGImage) -> [Float]? {
        let w = image.width
        let h = image.height
        let bytesPerRow = w * 4
        var rawBytes = [UInt8](repeating: 0, count: h * bytesPerRow)

        guard let ctx = CGContext(
            data: &rawBytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var floats = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h {
            let r = Float(rawBytes[i * 4])
            let g = Float(rawBytes[i * 4 + 1])
            let b = Float(rawBytes[i * 4 + 2])
            floats[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        return floats
    }
}
