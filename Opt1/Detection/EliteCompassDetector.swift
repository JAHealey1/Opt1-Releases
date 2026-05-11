import CoreGraphics
import Foundation
import ImageIO
import Opt1Detection
import Vision

/// Result of detecting an Elite compass clue scroll arrow.
///
/// The bearing is carried as an `UncertainAngle` so the rendering layer can
/// draw a beam (median ± epsilon) instead of a single ray. The renderer's
/// pixel-to-bearing mapping is non-linear, so a single-degree confidence
/// number would be misleading.
struct EliteCompassReading {
    /// Calibrated bearing with explicit ± uncertainty.
    let angle: UncertainAngle
    /// The raw pre-calibration angle (radians, math convention CCW from East).
    let rawAngleRadians: Double
    /// Whether MSAA was detected on the rendered arrow.
    let antialiasing: AntialiasingMode
    /// Number of arrow pixels collected by flood fill.
    let arrowPixelCount: Int
    /// Bounding box of the detected parchment scroll in image coordinates.
    let scrollBounds: CGRect
    /// True when the compass scroll's region label reads "EASTERN LANDS",
    /// indicating a master-tier Arc compass clue rather than an elite surface clue.
    let isEasternLands: Bool
}

/// Detects the black direction arrow on an Elite compass clue scroll and
/// extracts the bearing angle.
///
/// Detection strategy:
/// 1. Build a density grid to find parchment-coloured clusters.
/// 2. Expand each cluster's bounds to recover shadowed parchment on the left.
/// 3. Score each cluster with multiple signals: N-marker presence, warm-tone
///    dominance, aspect ratio, and pixel-count plausibility.
/// 4. Read the arrow angle by:
///    - flood-filling near-black pixels (`r,g,b < 5`) outward from the rose
///      centre, in the style of
///      [Leridon/cluetrainer](https://github.com/Leridon/cluetrainer)
///      (`CompassReader.ts :: floodFillScanDFSLine`),
///    - detecting MSAA from greyish pixels near centre,
///    - computing centre-of-mass and centre-of-area,
///    - taking a distance² weighted circular mean of per-pixel angles
///      (with tip/tail flip vs the initial centre-of-mass direction),
///    - applying the calibration LUT to get a calibrated `UncertainAngle`.
struct EliteCompassDetector: PuzzleDetector {

    private let cellSize       = 32

    /// Pixel-count windows from `CompassReader.ts` lines 218–241, valid at
    /// 100% NXT UI scale. Pixel counts scale with UI scale² (they're areas),
    /// so at runtime we scale these baselines by an estimate of the actual
    /// UI scale derived from the detected scroll height.
    private let aaOffPixelRange: ClosedRange<Int> = 2175...2275
    private let aaOnPixelRange:  ClosedRange<Int> = 1700...2300
    /// Below this we'd rather skip the candidate entirely (tiny smudges).
    private let minArrowPixels = 400

    /// Reference scroll height in pixels at 100% NXT UI scale.
    /// Source: `CapturedCompass.UI_SIZE.y` in ClueTrainer.
    private let referenceScrollH = 259.0
    /// Tolerance multiplier applied to scaled pixel-count windows to absorb
    /// ±1-cell (~32px) quantisation error in the cluster-derived scrollH.
    /// 1.20 → ±20% on each window edge after scaling.
    private let scaleTolerance = 1.20

    private static var debugDir: URL? {
        AppSettings.debugSubfolder(named: "EliteCompassDebug")
    }

    // MARK: - Debug info

    struct DebugInfo {
        var log: [String] = []
        var totalParchment = 0
        var gridW = 0, gridH = 0
        var densityGrid: [[Int]] = []
        var allClusters: [ParchmentLocator.Cluster] = []
        var chosenClusterIdx: Int?
        var scrollBounds: CGRect?
        var expandedBounds: CGRect?
        var centre: (x: Int, y: Int)?
        var arrowPixels: [(x: Int, y: Int)] = []
        var rawAngleDegrees: Double?
        var calibratedBearingDegrees: Double?
        var calibratedEpsilonDegrees: Double?
        var antialiasing: AntialiasingMode?
        var pixelCount: Int?
        var pixelCountWindow: ClosedRange<Int>?
        var centerOfMass: (x: Double, y: Double)?
        var centerOfArea: (x: Double, y: Double)?
        var candidateScores: [(idx: Int, score: Double, detail: String)] = []
        var failReason: String?
    }

    // MARK: - Public API

    func detect(in image: CGImage) async -> EliteCompassReading? {
        var dbg = DebugInfo()
        guard let base = detectInternal(in: image, dbg: &dbg) else {
            saveDebug(image: image, dbg: dbg, result: nil)
            return nil
        }
        let eastern = await detectEasternLandsLabel(image: image, scrollBounds: base.scrollBounds)
        let result = EliteCompassReading(
            angle:           base.angle,
            rawAngleRadians: base.rawAngleRadians,
            antialiasing:    base.antialiasing,
            arrowPixelCount: base.arrowPixelCount,
            scrollBounds:    base.scrollBounds,
            isEasternLands:  eastern
        )
        saveDebug(image: image, dbg: dbg, result: result)
        return result
    }

    /// OCR-checks the bottom ~28 % of the detected scroll for the "EASTERN LANDS"
    /// region label that appears only on master-tier Arc compass clues.
    /// Returns `true` when the label is found, `false` on any failure or absence.
    private func detectEasternLandsLabel(image: CGImage, scrollBounds: CGRect) async -> Bool {
        let labelH = scrollBounds.height * 0.28
        let cropRect = CGRect(
            x:      scrollBounds.minX,
            y:      scrollBounds.maxY - labelH,
            width:  scrollBounds.width,
            height: labelH
        ).integral
        let clampedCrop = cropRect.intersection(
            CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        guard !clampedCrop.isNull, clampedCrop.width > 4, clampedCrop.height > 4,
              let crop = image.cropping(to: clampedCrop) else { return false }

        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: crop, options: [:])
            guard (try? handler.perform([request])) != nil else { return false }
            let texts = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let found = texts.contains { $0.range(of: "EASTERN", options: .caseInsensitive) != nil }
            if found {
                print("[EliteCompass] Eastern Lands label detected via OCR: \(texts)")
            }
            return found
        }.value
    }

    // MARK: - Core detection

    private func detectInternal(in image: CGImage, dbg: inout DebugInfo) -> EliteCompassReading? {
        let locator = ParchmentLocator()
        guard let pixels = locator.renderToRGBA(image) else {
            dbg.failReason = "renderToRGBA failed"
            return nil
        }
        let w = image.width, h = image.height

        let scanResult = locator.scan(pixels: pixels, width: w, height: h, cellSize: cellSize)
        let allClusters = scanResult.clusters

        dbg.gridW = scanResult.gridW
        dbg.gridH = scanResult.gridH
        dbg.totalParchment = scanResult.totalParchmentPixels
        dbg.densityGrid = scanResult.densityGrid
        dbg.allClusters = allClusters
        dbg.log.append("\(scanResult.totalParchmentPixels) parchment pixels in \(w)×\(h) image (\(scanResult.gridW)×\(scanResult.gridH) grid)")

        guard scanResult.totalParchmentPixels >= 200 else {
            dbg.failReason = "Too few parchment pixels: \(scanResult.totalParchmentPixels)"
            print("[EliteCompass] \(dbg.failReason!)")
            return nil
        }

        dbg.log.append("Found \(allClusters.count) parchment clusters (≥25% density cells)")
        print("[EliteCompass] \(allClusters.count) parchment clusters")

        // ── Evaluate each cluster with composite scoring ──
        struct Candidate {
            let clusterIdx: Int
            let initialBounds: CGRect
            let expandedBounds: CGRect
            let cx: Double, cy: Double
            let arrow: ArrowReadResult
            let compositeScore: Double
            let scoreDetail: String
        }

        var candidates: [Candidate] = []

        for (ci, cluster) in allClusters.enumerated() {
            if cluster.cellCount < 6 { continue }

            let scrollMinX = Int(cluster.bounds.minX)
            let scrollMaxX = Int(cluster.bounds.maxX)
            let scrollMinY = Int(cluster.bounds.minY)
            let scrollMaxY = Int(cluster.bounds.maxY)
            let scrollW = scrollMaxX - scrollMinX
            let scrollH = scrollMaxY - scrollMinY

            if scrollW < 40 || scrollH < 40 { continue }

            // ── Scale-aware size caps ──
            // Derive maximum expected scroll dimensions from the user's
            // configured NXT UI scale (AppSettings.puzzleUIScalePercent).
            // A ±20% tolerance absorbs grid quantisation (±1 cell ≈ 12%)
            // and minor render-size variation across machines.
            // `expandBoundsForShadow` can add up to scrollH×0.20 top and
            // bottom, so the expanded-height cap uses a 1.40× multiplier.
            let uiScale    = Double(AppSettings.puzzleUIScalePercent) / 100.0
            let tolerance  = 1.20
            let maxScrollH = Int((referenceScrollH * uiScale * tolerance).rounded(.up))
            let maxExpH    = Int((referenceScrollH * uiScale * 1.40 * tolerance).rounded(.up))
            if scrollW > w / 5 || scrollH > maxScrollH {
                dbg.log.append("  Cluster \(ci): skipped — size \(scrollW)×\(scrollH) exceeds cap \(w / 5)×\(maxScrollH) (uiScale=\(Int(uiScale * 100))%)")
                continue
            }

            // ── Expand bounds to recover shadowed left-third of scroll ──
            let expanded = expandBoundsForShadow(
                pixels: pixels, w: w, h: h,
                scrollMinX: scrollMinX, scrollMaxX: scrollMaxX,
                scrollMinY: scrollMinY, scrollMaxY: scrollMaxY
            )
            let expW = expanded.maxX - expanded.minX
            let expH = expanded.maxY - expanded.minY

            if expW > w / 4 || expH > maxExpH {
                dbg.log.append("  Cluster \(ci): skipped — expanded size \(expW)×\(expH) exceeds cap \(w / 4)×\(maxExpH) (uiScale=\(Int(uiScale * 100))%)")
                continue
            }

            let aspect = Double(expW) / Double(expH)
            if aspect < 0.30 || aspect > 0.85 { continue }

            // The compass rose sits in the centre of the *initial* parchment
            // bounds — using expanded bounds shifts this into the shadow zone.
            let cx = Double(scrollMinX + scrollMaxX) / 2.0
            let cy = Double(scrollMinY + scrollMaxY) / 2.0

            // ── Read the arrow ──
            // Pass un-expanded scrollH for UI-scale estimation. It tracks the
            // parchment cluster height directly (no shadow extension) which
            // gives a cleaner scale signal than the expanded bounds.
            let read = readArrowAngle(
                pixels: pixels, w: w, h: h,
                roseCx: cx, roseCy: cy,
                bounds: expanded,
                clusterScrollH: scrollH
            )

            switch read {
            case .failure(let reason):
                dbg.log.append("  Cluster \(ci): rejected — \(reason)")
                continue
            case .success(let arrow):
                // ── Cluster-quality scoring ──
                let nScore = nMarkerScore(
                    pixels: pixels, w: w, h: h,
                    scrollMinX: expanded.minX, scrollMaxX: expanded.maxX,
                    scrollMinY: expanded.minY, scrollMaxY: expanded.maxY
                )
                let warmScore = warmToneDominance(
                    pixels: pixels, w: w, h: h,
                    scrollMinX: expanded.minX, scrollMaxX: expanded.maxX,
                    scrollMinY: expanded.minY, scrollMaxY: expanded.maxY
                )
                let aspectScore = max(0.0, 1.0 - abs(aspect - 0.5) * 4.0)
                let pcQuality   = pixelCountQuality(
                    arrow.pixelCount, aa: arrow.antialiasing, scrollH: scrollH
                )
                let sizeBonus   = min(1.0, Double(arrow.pixelCount) / 2000.0)

                let composite = nScore * 3.0 + warmScore + aspectScore + pcQuality + sizeBonus
                let detail = String(
                    format: "N=%.1f warm=%.2f asp=%.2f px=%d(%@,q=%.2f) raw=%.1f° → %@ → %.2f",
                    nScore, warmScore, aspectScore, arrow.pixelCount,
                    arrow.antialiasing == .msaa ? "MSAA" : "noAA",
                    pcQuality,
                    arrow.rawAngleRadians * 180 / .pi,
                    arrow.uncertainAngle.formatted(decimals: 1),
                    composite
                )

                let initialBounds = CGRect(x: scrollMinX, y: scrollMinY, width: scrollW, height: scrollH)
                let expandedRect  = CGRect(x: expanded.minX, y: expanded.minY, width: expW, height: expH)

                candidates.append(Candidate(
                    clusterIdx: ci,
                    initialBounds: initialBounds,
                    expandedBounds: expandedRect,
                    cx: cx, cy: cy,
                    arrow: arrow,
                    compositeScore: composite,
                    scoreDetail: detail
                ))

                dbg.log.append("  Cluster \(ci): \(cluster.cellCount) cells, \(scrollW)→\(expW)×\(scrollH)→\(expH), \(detail)")
                dbg.candidateScores.append((ci, composite, detail))
            }
        }

        dbg.log.append("\(candidates.count) candidate clusters with viable arrows")
        print("[EliteCompass] \(candidates.count) candidates with arrows")

        guard !candidates.isEmpty else {
            dbg.failReason = "No parchment cluster contained a viable arrow (\(allClusters.count) clusters checked)"
            print("[EliteCompass] \(dbg.failReason!)")
            return nil
        }

        let best = candidates.max(by: { $0.compositeScore < $1.compositeScore })!

        guard best.compositeScore >= 2.0 else {
            dbg.failReason = "Best candidate score \(String(format: "%.2f", best.compositeScore)) below threshold 2.0"
            print("[EliteCompass] \(dbg.failReason!)")
            return nil
        }

        let arrow = best.arrow

        dbg.chosenClusterIdx = best.clusterIdx
        dbg.scrollBounds = best.initialBounds
        dbg.expandedBounds = best.expandedBounds
        dbg.centre = (Int(best.cx), Int(best.cy))
        dbg.arrowPixels = arrow.arrowPixels
        dbg.rawAngleDegrees = arrow.rawAngleRadians * 180 / .pi
        dbg.calibratedBearingDegrees = arrow.uncertainAngle.bearingDegrees
        dbg.calibratedEpsilonDegrees = arrow.uncertainAngle.epsilonDegrees
        dbg.antialiasing = arrow.antialiasing
        dbg.pixelCount = arrow.pixelCount
        // Report the SCALED window so debug logs reflect what the gate
        // actually used at the user's UI scale.
        let bestScrollH = Int(best.initialBounds.height)
        dbg.pixelCountWindow = scaledPixelCountRange(for: arrow.antialiasing, scrollH: bestScrollH)
        dbg.centerOfMass = arrow.centerOfMass
        dbg.centerOfArea = arrow.centerOfArea

        dbg.log.append("Chosen cluster \(best.clusterIdx): score \(String(format: "%.2f", best.compositeScore)), \(best.scoreDetail)")
        print("[EliteCompass] Chose cluster \(best.clusterIdx): score \(String(format: "%.2f", best.compositeScore)), \(arrow.uncertainAngle.formatted())")

        return EliteCompassReading(
            angle: arrow.uncertainAngle,
            rawAngleRadians: arrow.rawAngleRadians,
            antialiasing: arrow.antialiasing,
            arrowPixelCount: arrow.pixelCount,
            scrollBounds: best.expandedBounds,
            isEasternLands: false
        )
    }

    // MARK: - Bounds Expansion

    /// Scans outward from the initial parchment cluster bounds to recover the
    /// scroll's shadowed left-third (which fails the strict `isParchment` check).
    /// Columns/rows must contain genuinely warm pixels (not just dark) — this
    /// catches shadow parchment (dark but R > B, brightness > 60) while stopping
    /// at the dark scroll border and game background (which are too dark to be warm).
    private func expandBoundsForShadow(
        pixels: [UInt8], w: Int, h: Int,
        scrollMinX: Int, scrollMaxX: Int, scrollMinY: Int, scrollMaxY: Int
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let scrollW = scrollMaxX - scrollMinX
        let scrollH = scrollMaxY - scrollMinY
        let maxExpandH = Int(Double(scrollW) * 0.40)
        let maxExpandV = Int(Double(scrollH) * 0.20)
        let threshold = 0.15

        func isWarm(r: UInt8, g: UInt8, b: UInt8) -> Bool {
            let maxC = max(r, max(g, b))
            if maxC < 60 { return false }
            if Int(b) > Int(r) { return false }
            if Int(g) > Int(r) + 20 && Int(g) > Int(b) + 20 { return false }
            return true
        }

        func columnWarmRatio(x: Int, yMin: Int, yMax: Int) -> Double {
            guard x >= 0, x < w, yMin <= yMax else { return 0 }
            var warm = 0, total = 0
            for y in max(0, yMin)...min(h - 1, yMax) {
                let i = y * w * 4 + x * 4
                total += 1
                if isWarm(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]) {
                    warm += 1
                }
            }
            return total > 0 ? Double(warm) / Double(total) : 0
        }

        func rowWarmRatio(y: Int, xMin: Int, xMax: Int) -> Double {
            guard y >= 0, y < h, xMin <= xMax else { return 0 }
            var warm = 0, total = 0
            let row = y * w * 4
            for x in max(0, xMin)...min(w - 1, xMax) {
                let i = row + x * 4
                total += 1
                if isWarm(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]) {
                    warm += 1
                }
            }
            return total > 0 ? Double(warm) / Double(total) : 0
        }

        var newMinX = scrollMinX
        for step in 1...maxExpandH {
            let x = scrollMinX - step
            guard x >= 0 else { break }
            if columnWarmRatio(x: x, yMin: scrollMinY, yMax: scrollMaxY) < threshold { break }
            newMinX = x
        }

        var newMaxX = scrollMaxX
        for step in 1...maxExpandH {
            let x = scrollMaxX + step
            guard x < w else { break }
            if columnWarmRatio(x: x, yMin: scrollMinY, yMax: scrollMaxY) < threshold { break }
            newMaxX = x
        }

        var newMinY = scrollMinY
        for step in 1...maxExpandV {
            let y = scrollMinY - step
            guard y >= 0 else { break }
            if rowWarmRatio(y: y, xMin: newMinX, xMax: newMaxX) < threshold { break }
            newMinY = y
        }

        var newMaxY = scrollMaxY
        for step in 1...maxExpandV {
            let y = scrollMaxY + step
            guard y < h else { break }
            if rowWarmRatio(y: y, xMin: newMinX, xMax: newMaxX) < threshold { break }
            newMaxY = y
        }

        return (newMinX, newMaxX, newMinY, newMaxY)
    }

    // MARK: - Arrow read pipeline (port of ClueTrainer's CompassReader inner loop)

    private struct ArrowReadResult {
        let uncertainAngle: UncertainAngle
        let rawAngleRadians: Double
        let antialiasing: AntialiasingMode
        let pixelCount: Int
        let centerOfMass: (x: Double, y: Double)
        let centerOfArea: (x: Double, y: Double)
        let arrowPixels: [(x: Int, y: Int)]
    }

    private enum ArrowReadFailure: Error, Equatable {
        case seedNotFound
        case tooFewPixels(Int)
        case likelyConcealed(count: Int, aa: AntialiasingMode)
        case nan
    }

    /// Reads the arrow bearing from the image.
    ///
    /// - Parameters:
    ///   - pixels: RGBA pixel buffer.
    ///   - roseCx, roseCy: Estimated centre of the compass rose, in image pixels.
    ///   - bounds: Search box (the expanded parchment bounds).
    private func readArrowAngle(
        pixels: [UInt8], w: Int, h: Int,
        roseCx: Double, roseCy: Double,
        bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int),
        clusterScrollH: Int
    ) -> Result<ArrowReadResult, ArrowReadFailure> {

        // Restrict flood-fill region to the scroll's interior (small safety
        // margin), so we don't accidentally walk off into game terrain.
        let topInset    = max(8, Int(Double(bounds.maxY - bounds.minY) * 0.15))
        let bottomInset = max(6, Int(Double(bounds.maxY - bounds.minY) * 0.10))
        let regionMinX  = max(0, bounds.minX)
        let regionMaxX  = min(w - 1, bounds.maxX)
        let regionMinY  = max(0, bounds.minY + topInset)
        let regionMaxY  = min(h - 1, bounds.maxY - bottomInset)
        guard regionMinX < regionMaxX, regionMinY < regionMaxY else {
            return .failure(.seedNotFound)
        }

        @inline(__always) func pix(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = y * w * 4 + x * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        @inline(__always) func isArrow(_ x: Int, _ y: Int) -> Bool {
            let p = pix(x, y)
            return p.0 < 5 && p.1 < 5 && p.2 < 5
        }

        // ── Find a black seed near (roseCx, roseCy) ──
        let cxI = Int(roseCx.rounded()), cyI = Int(roseCy.rounded())
        var seed: (Int, Int)? = nil
        let seedRadius = 20
        seedSearch: for r in 0...seedRadius {
            if r == 0 {
                if cxI >= regionMinX, cxI <= regionMaxX,
                   cyI >= regionMinY, cyI <= regionMaxY,
                   isArrow(cxI, cyI) {
                    seed = (cxI, cyI); break seedSearch
                }
            } else {
                for dy in -r...r {
                    for dx in -r...r {
                        if max(abs(dx), abs(dy)) != r { continue }
                        let x = cxI + dx, y = cyI + dy
                        guard x >= regionMinX, x <= regionMaxX,
                              y >= regionMinY, y <= regionMaxY else { continue }
                        if isArrow(x, y) { seed = (x, y); break seedSearch }
                    }
                }
            }
        }
        guard let seedPx = seed else { return .failure(.seedNotFound) }

        // ── Flood-fill (BFS, 8-connected). Detect MSAA on greyish near-centre pixels. ──
        // Visited cells use a packed bitmap keyed on the local (region) frame to keep memory bounded.
        let regionW = regionMaxX - regionMinX + 1
        let regionH = regionMaxY - regionMinY + 1
        var visited = [Bool](repeating: false, count: regionW * regionH)

        var arrowPx: [(x: Int, y: Int)] = []
        var aa: AntialiasingMode = .off
        var queue: [(Int, Int)] = [seedPx]

        @inline(__always) func key(_ x: Int, _ y: Int) -> Int {
            (y - regionMinY) * regionW + (x - regionMinX)
        }
        visited[key(seedPx.0, seedPx.1)] = true

        while let (x, y) = queue.popLast() {
            if isArrow(x, y) {
                arrowPx.append((x, y))
            } else {
                // ClueTrainer: r+g+b < 250 within ±15 of centre → AA-on
                let dxc = abs(x - cxI), dyc = abs(y - cyI)
                if aa == .off, max(dxc, dyc) < 15 {
                    let p = pix(x, y)
                    let sum = Int(p.0) + Int(p.1) + Int(p.2)
                    if sum < 250 { aa = .msaa }
                }
                continue
            }

            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = x + dx, ny = y + dy
                    guard nx >= regionMinX, nx <= regionMaxX,
                          ny >= regionMinY, ny <= regionMaxY else { continue }
                    let k = key(nx, ny)
                    if visited[k] { continue }
                    visited[k] = true
                    queue.append((nx, ny))
                }
            }
        }

        let count = arrowPx.count

        // Scale CT's 100% pixel-count windows by the user's estimated UI
        // scale². Without this, anything other than 100% NXT scale fails the
        // gate even on a perfectly readable compass.
        let scaledMinPixels = scaledMin(minArrowPixels, scrollH: clusterScrollH)
        guard count >= scaledMinPixels else {
            return .failure(.tooFewPixels(count))
        }

        let window = scaledPixelCountRange(for: aa, scrollH: clusterScrollH)
        if !window.contains(count) {
            // Outside the scaled empirical window → likely concealed
            // (UI overlays the compass). Fail soft so the user can recapture.
            return .failure(.likelyConcealed(count: count, aa: aa))
        }

        // ── Compute centres ──
        let n = Double(count)
        var sumX = 0.0, sumY = 0.0
        var minX = arrowPx[0].x, maxX = arrowPx[0].x
        var minY = arrowPx[0].y, maxY = arrowPx[0].y
        for p in arrowPx {
            sumX += Double(p.x); sumY += Double(p.y)
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        let comX = sumX / n, comY = sumY / n
        let caX  = (Double(minX) + Double(maxX)) / 2
        let caY  = (Double(minY) + Double(maxY)) / 2

        // ── Initial angle (centre-of-area → centre-of-mass) ──
        // Math convention: 0 = East, π/2 = North, +y in screen is "down" so we negate.
        let initialAngle = atan2(-(comY - caY), comX - caX)

        // ── Per-pixel circular weighted mean ──
        var sumSin = 0.0, sumCos = 0.0
        for p in arrowPx {
            let dx = Double(p.x) - caX
            let dy = Double(p.y) - caY
            let len2 = dx * dx + dy * dy
            if len2 < 1e-9 { continue }
            var ang = atan2(-dy, dx)
            // Flip if more than π/2 away from initial direction (tail pixels).
            if angleDifferenceUnsigned(ang, initialAngle) > .pi / 2 {
                ang = normalizeAngle(ang - .pi)
            }
            sumSin += len2 * sin(ang)
            sumCos += len2 * cos(ang)
        }

        if sumSin == 0 && sumCos == 0 {
            return .failure(.nan)
        }
        let rawAngle = normalizeAngle(atan2(sumSin, sumCos))
        if rawAngle.isNaN { return .failure(.nan) }

        // ── Apply calibration LUT ──
        let calibrated = CompassCalibration.apply(rawAngleRadians: rawAngle, aa: aa)

        return .success(ArrowReadResult(
            uncertainAngle: calibrated,
            rawAngleRadians: rawAngle,
            antialiasing: aa,
            pixelCount: count,
            centerOfMass: (comX, comY),
            centerOfArea: (caX, caY),
            arrowPixels: arrowPx
        ))
    }

    /// Maps a flood-fill pixel count to a `[0, 1]` quality score relative to
    /// the UI-scale-adjusted expected window. Highest at the centre of the
    /// window, 0 if the count is outside altogether.
    private func pixelCountQuality(_ count: Int, aa: AntialiasingMode, scrollH: Int) -> Double {
        let range = scaledPixelCountRange(for: aa, scrollH: scrollH)
        guard range.contains(count) else { return 0 }
        let mid = Double(range.lowerBound + range.upperBound) / 2
        let half = Double(range.upperBound - range.lowerBound) / 2
        return max(0, 1 - abs(Double(count) - mid) / half)
    }

    // MARK: - UI-Scale Adjustment

    /// Estimates the runtime UI scale² (area scale) from the cluster-derived
    /// scroll height. CT's 100% NXT reference height is `referenceScrollH`.
    /// The cluster height is grid-quantised to `cellSize`, so this estimate
    /// has ~12% error — `scaleTolerance` widens the windows to compensate.
    private func areaScale(scrollH: Int) -> Double {
        let s = max(0.5, Double(scrollH) / referenceScrollH)
        return s * s
    }

    /// Returns the AA-on / AA-off pixel-count window, scaled by the estimated
    /// UI area scale and widened by `scaleTolerance` on each edge.
    private func scaledPixelCountRange(for aa: AntialiasingMode, scrollH: Int) -> ClosedRange<Int> {
        let base = aa == .msaa ? aaOnPixelRange : aaOffPixelRange
        let s2 = areaScale(scrollH: scrollH)
        let lo = Int((Double(base.lowerBound) * s2 / scaleTolerance).rounded(.down))
        let hi = Int((Double(base.upperBound) * s2 * scaleTolerance).rounded(.up))
        return lo...hi
    }

    private func scaledMin(_ value: Int, scrollH: Int) -> Int {
        let s2 = areaScale(scrollH: scrollH)
        return Int((Double(value) * s2 / scaleTolerance).rounded(.down))
    }

    // MARK: - N-Marker Detection

    /// Checks the top portion of the scroll for a compact cluster of dark pixels
    /// (the "N" glyph). Returns 1.0 if found, 0.0 otherwise.
    private func nMarkerScore(
        pixels: [UInt8], w: Int, h: Int,
        scrollMinX: Int, scrollMaxX: Int, scrollMinY: Int, scrollMaxY: Int
    ) -> Double {
        let scrollW = scrollMaxX - scrollMinX
        let scrollH = scrollMaxY - scrollMinY
        guard scrollH > 60 else { return 0 }

        let checkTop    = scrollMinY
        let checkBottom = min(h, scrollMinY + max(10, Int(Double(scrollH) * 0.15)))
        let checkLeft   = max(0, scrollMinX + Int(Double(scrollW) * 0.30))
        let checkRight  = min(w, scrollMaxX - Int(Double(scrollW) * 0.30))

        guard checkLeft < checkRight, checkTop < checkBottom else { return 0 }

        let regionArea = (checkRight - checkLeft) * (checkBottom - checkTop)
        guard regionArea > 0 else { return 0 }

        var darkCount = 0
        var sumX = 0.0
        var sumXSq = 0.0
        for y in checkTop..<checkBottom {
            let row = y * w * 4
            for x in checkLeft..<checkRight {
                let i = row + x * 4
                if pixels[i] < 80 && pixels[i + 1] < 80 && pixels[i + 2] < 80 {
                    darkCount += 1
                    let xd = Double(x)
                    sumX += xd
                    sumXSq += xd * xd
                }
            }
        }

        guard darkCount >= 40 else { return 0 }
        let density = Double(darkCount) / Double(regionArea)
        guard density >= 0.03 else { return 0 }

        let meanX = sumX / Double(darkCount)
        let variance = sumXSq / Double(darkCount) - meanX * meanX
        let stdDev = sqrt(max(0, variance))
        if stdDev > Double(scrollW) * 0.15 { return 0 }

        return 1.0
    }

    // MARK: - Warm-Tone Dominance

    private func warmToneDominance(
        pixels: [UInt8], w: Int, h: Int,
        scrollMinX: Int, scrollMaxX: Int, scrollMinY: Int, scrollMaxY: Int
    ) -> Double {
        let scrollH = scrollMaxY - scrollMinY
        let topInset = max(8, Int(Double(scrollH) * 0.20))
        let bottomInset = max(6, Int(Double(scrollH) * 0.10))

        let checkTop = scrollMinY + topInset
        let checkBottom = scrollMaxY - bottomInset

        var totalSampled = 0
        var coldCount = 0

        let step = 2
        for y in stride(from: checkTop, to: min(h, checkBottom), by: step) {
            let row = y * w * 4
            for x in stride(from: max(0, scrollMinX), to: min(w, scrollMaxX), by: step) {
                let i = row + x * 4
                let r = Int(pixels[i])
                let g = Int(pixels[i + 1])
                let b = Int(pixels[i + 2])

                if max(r, max(g, b)) < 60 { continue }

                totalSampled += 1

                if b > r || (g > r + 20 && g > b + 20) {
                    coldCount += 1
                }
            }
        }

        guard totalSampled > 0 else { return 0 }
        let coldRatio = Double(coldCount) / Double(totalSampled)
        return max(0.0, 1.0 - coldRatio * 10.0)
    }

    // MARK: - Debug Output

    private func saveDebug(image: CGImage, dbg: DebugInfo, result: EliteCompassReading?) {
        guard let dir = Self.debugDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = Int(Date().timeIntervalSince1970)
        let W = image.width, H = image.height

        // 1. Annotated full image
        if let ctx = CGContext(
            data: nil, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(H))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()
            ctx.translateBy(x: 0, y: CGFloat(H))
            ctx.scaleBy(x: 1, y: -1)

            let cs = cellSize
            let cellArea = Double(cs * cs)

            // Density heatmap
            if !dbg.densityGrid.isEmpty {
                var peak = 0.01
                for row in dbg.densityGrid { for c in row { peak = max(peak, Double(c) / cellArea) } }
                for gy in 0..<dbg.gridH {
                    for gx in 0..<dbg.gridW {
                        let d = Double(dbg.densityGrid[gy][gx]) / cellArea
                        if d < 0.01 { continue }
                        let t = min(1.0, d / peak)
                        let r: CGFloat, g: CGFloat, b: CGFloat
                        if t < 0.5 {
                            let s = t / 0.5
                            r = s; g = s; b = CGFloat(1.0 - s)
                        } else {
                            let s = (t - 0.5) / 0.5
                            r = 1.0; g = CGFloat(1.0 - s); b = 0
                        }
                        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 0.25))
                        ctx.fill(CGRect(x: gx * cs, y: gy * cs, width: cs, height: cs))
                    }
                }
            }

            // Cluster outlines
            let clusterColors: [CGColor] = [
                CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.6),
                CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 0.6),
                CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 0.6),
                CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.6),
                CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.6),
            ]
            for (ci, cluster) in dbg.allClusters.enumerated() {
                let isChosen = ci == dbg.chosenClusterIdx
                let color = isChosen
                    ? CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.9)
                    : clusterColors[ci % clusterColors.count]
                ctx.setStrokeColor(color)
                ctx.setLineWidth(isChosen ? 3 : 1)
                for cell in cluster.cells {
                    ctx.stroke(CGRect(x: cell.gx * cs, y: cell.gy * cs, width: cs, height: cs))
                }
            }

            // Arrow pixels (red dots)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.7))
            for p in dbg.arrowPixels {
                ctx.fill(CGRect(x: p.x, y: p.y, width: 2, height: 2))
            }

            // Initial scroll bounds (cyan rect)
            if let sb = dbg.scrollBounds {
                ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.9))
                ctx.setLineWidth(2)
                ctx.stroke(CGRect(x: Int(sb.minX), y: Int(sb.minY),
                                  width: Int(sb.width), height: Int(sb.height)))
            }

            // Expanded bounds (yellow rect)
            if let eb = dbg.expandedBounds {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.9))
                ctx.setLineWidth(2)
                let dashes: [CGFloat] = [6, 4]
                ctx.setLineDash(phase: 0, lengths: dashes)
                ctx.stroke(CGRect(x: Int(eb.minX), y: Int(eb.minY),
                                  width: Int(eb.width), height: Int(eb.height)))
                ctx.setLineDash(phase: 0, lengths: [])
            }

            // Centre-of-area (cyan cross), centre-of-mass (magenta cross)
            if let ca = dbg.centerOfArea {
                drawCross(ctx: ctx, x: Int(ca.x.rounded()), y: Int(ca.y.rounded()),
                          size: 16, color: CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
                          lineWidth: 3)
            }
            if let cm = dbg.centerOfMass {
                drawCross(ctx: ctx, x: Int(cm.x.rounded()), y: Int(cm.y.rounded()),
                          size: 12, color: CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                          lineWidth: 2)
            }

            // Calibrated bearing line/beam (green) + raw bearing line (orange) for A/B comparison.
            if let ca = dbg.centerOfArea {
                let extent = Double(max(W, H))
                let cx = ca.x, cy = ca.y

                // Raw (pre-calibration) line — orange dashed.
                if let rawDeg = dbg.rawAngleDegrees {
                    let bearingRad = .pi / 2 - rawDeg * .pi / 180
                    let dx = sin(bearingRad), dy = -cos(bearingRad)
                    ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 0.8))
                    ctx.setLineWidth(1.5)
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    ctx.move(to: CGPoint(x: cx - dx * extent, y: cy - dy * extent))
                    ctx.addLine(to: CGPoint(x: cx + dx * extent, y: cy + dy * extent))
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }

                // Calibrated bearing — green solid + green wedge (median ± epsilon).
                if let bDeg = dbg.calibratedBearingDegrees,
                   let eDeg = dbg.calibratedEpsilonDegrees {
                    let bearingRad = bDeg * .pi / 180
                    let lo = bearingRad - eDeg * .pi / 180
                    let hi = bearingRad + eDeg * .pi / 180
                    let lod = (sin(lo), -cos(lo))
                    let hid = (sin(hi), -cos(hi))

                    // Wedge fill
                    ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.18))
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: cx, y: cy))
                    ctx.addLine(to: CGPoint(x: cx + lod.0 * extent, y: cy + lod.1 * extent))
                    ctx.addLine(to: CGPoint(x: cx + hid.0 * extent, y: cy + hid.1 * extent))
                    ctx.closePath()
                    ctx.fillPath()

                    // Centerline
                    let dx = sin(bearingRad), dy = -cos(bearingRad)
                    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.95))
                    ctx.setLineWidth(2)
                    ctx.move(to: CGPoint(x: cx - dx * extent, y: cy - dy * extent))
                    ctx.addLine(to: CGPoint(x: cx + dx * extent, y: cy + dy * extent))
                    ctx.strokePath()

                    // Arrow-direction indicator (thicker, shorter segment)
                    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                    ctx.setLineWidth(4)
                    ctx.move(to: CGPoint(x: cx, y: cy))
                    ctx.addLine(to: CGPoint(x: cx + dx * 60, y: cy + dy * 60))
                    ctx.strokePath()
                }
            }

            if let annotated = ctx.makeImage() {
                savePNG(annotated, to: dir.appendingPathComponent("debug_\(ts).png"))
            }
        }

        // 2. Scroll crop (using expanded bounds if available)
        let cropBounds = dbg.expandedBounds ?? dbg.scrollBounds
        if let sb = cropBounds {
            let pad = 10
            let cropRect = CGRect(
                x: max(0, Int(sb.minX) - pad),
                y: max(0, Int(sb.minY) - pad),
                width: min(W - max(0, Int(sb.minX) - pad), Int(sb.width) + pad * 2),
                height: min(H - max(0, Int(sb.minY) - pad), Int(sb.height) + pad * 2)
            )
            if let crop = image.cropping(to: cropRect) {
                savePNG(crop, to: dir.appendingPathComponent("scroll_crop_\(ts).png"))
            }
        }

        // 3. Text summary
        let pcWindow = dbg.pixelCountWindow.map { "\($0.lowerBound)..\($0.upperBound)" } ?? "n/a"
        let aaStr = dbg.antialiasing.map { $0 == .msaa ? "MSAA" : "noAA" } ?? "n/a"
        var lines = [
            "Elite Compass Debug — \(Date())",
            "Image: \(W)×\(H)",
            "Result: \(result != nil ? "DETECTED" : "FAILED")",
            "Fail reason: \(dbg.failReason ?? "n/a")",
            "",
            "Total parchment pixels: \(dbg.totalParchment)",
            "Grid: \(dbg.gridW)×\(dbg.gridH) cells of \(cellSize)px",
            "Total clusters found: \(dbg.allClusters.count)",
            "Chosen cluster: \(dbg.chosenClusterIdx.map { "\($0)" } ?? "none")",
            "Initial bounds: \(dbg.scrollBounds.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))" } ?? "n/a")",
            "Expanded bounds: \(dbg.expandedBounds.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))" } ?? "n/a")",
            "Rose centre: \(dbg.centre.map { "(\($0.x),\($0.y))" } ?? "n/a")",
            "Centre-of-mass: \(dbg.centerOfMass.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) } ?? "n/a")",
            "Centre-of-area: \(dbg.centerOfArea.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) } ?? "n/a")",
            "Antialiasing: \(aaStr)",
            "Arrow pixel count: \(dbg.pixelCount.map { "\($0)" } ?? "n/a")  (window \(pcWindow))",
            "Raw angle: \(dbg.rawAngleDegrees.map { String(format: "%.2f° (math, CCW from East)", $0) } ?? "n/a")",
            "Calibrated bearing: \(dbg.calibratedBearingDegrees.map { String(format: "%.2f°", $0) } ?? "n/a") ±\(dbg.calibratedEpsilonDegrees.map { String(format: "%.2f°", $0) } ?? "n/a")",
            "",
            "--- Candidate Scores ---",
        ]
        for cs in dbg.candidateScores {
            lines.append("  Cluster \(cs.idx): \(String(format: "%.2f", cs.score)) — \(cs.detail)")
        }
        lines.append("")
        lines.append("--- Log ---")
        lines.append(contentsOf: dbg.log)
        try? lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("debug_\(ts).txt"),
            atomically: true, encoding: .utf8)

        print("[EliteCompass] Debug saved to EliteCompassDebug/debug_\(ts).*")
    }

    private func drawCross(ctx: CGContext, x: Int, y: Int, size: Int, color: CGColor, lineWidth: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: x - size, y: y))
        ctx.addLine(to: CGPoint(x: x + size, y: y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: x, y: y - size))
        ctx.addLine(to: CGPoint(x: x, y: y + size))
        ctx.strokePath()
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

}

// MARK: - small radian helpers (file-private to avoid colliding with future Angles.swift)

private func normalizeAngle(_ rad: Double) -> Double {
    var x = rad.truncatingRemainder(dividingBy: 2 * .pi)
    if x < 0 { x += 2 * .pi }
    return x
}

private func angleDifferenceUnsigned(_ a: Double, _ b: Double) -> Double {
    let two = 2 * Double.pi
    var x = (b - a + .pi).truncatingRemainder(dividingBy: two)
    if x < 0 { x += two }
    return abs(x - .pi)
}
