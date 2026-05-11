import AppKit
import CoreGraphics
import Vision
import Opt1Matching

/// Matches a captured map clue image against the library of reference PNGs
/// stored in the app bundle under MapImages/.
///
/// The orchestrator uses `ClueScrollDetector.detectClueRect` to obtain the
/// parchment crop, then calls `matchMapClue(_:against:)` which computes a
/// Vision FeaturePrint (neural-network image embedding) for the query and
/// for each reference and picks the one with the smallest distance.
///
/// Reference images are wiki screenshots stored as
/// Matching/Resources/MapImages/<imageRef>.png and included in the bundle
/// as a folder reference.
struct MapClueMatcher {

    /// Maximum FeaturePrint distance to accept a match (lower = more similar,
    /// 0 = identical).  Observatory calibration: correct = 0.484,
    /// next-best wrong = 0.627 → threshold set at the midpoint (0.56).
    private let matchThreshold: Float = 0.68

    /// Minimum gap (best.dist + margin ≤ second-best.dist) required to accept
    /// a match. Calibrated from the Observatory pair (correct 0.484 vs runner-up
    /// 0.627 → 0.143 gap); 0.05 leaves room for normal scene variation while
    /// rejecting genuinely confusable pairs. If there is no runner-up the gate
    /// is bypassed (single-candidate corpus).
    private let runnerUpMargin: Float = 0.05

    // MARK: - Matching

    /// Returns the best-matching `ClueSolution` for `query`, or nil if no
    /// reference falls within `matchThreshold`.
    ///
    /// The query is the inner-parchment crop produced by ClueScrollDetector
    /// (no title bar, no decorative border).  Each reference image may include
    /// the old-style "TREASURE MAP" title and rolled-parchment border;
    /// `innerParchmentCrop` removes those before comparison so both sides
    /// represent the same content.  FeaturePrint handles any remaining scale
    /// or rendering differences automatically.
    func matchMapClue(_ query: CGImage, against candidates: [ClueSolution]) -> ClueSolution? {
        // Remove any dark game-background rows that ClueScrollDetector
        // sometimes captures below the parchment.
        let cleanQuery = trimNonParchmentBottom(from: query)

        let debugDir = AppSettings.debugSubfolder(named: "MapClueDebug")
        if let dir = debugDir {
            savePNG(cleanQuery, to: dir.appendingPathComponent("clean_query_full.png"))
        }

        guard let queryFP = VisionHelpers.featurePrint(of: cleanQuery) else { return nil }

        var scores: [(ref: String, dist: Float, candidate: ClueSolution)] = []
        var checked = Set<String>()

        for candidate in candidates {
            guard let ref = candidate.imageRef, !checked.contains(ref) else { continue }
            checked.insert(ref)

            guard let refFull = loadReferenceImage(named: ref) else { continue }

            // Strip decorative border from old-style reference images.
            let refContent = innerParchmentCrop(refFull) ?? refFull

            guard let refFP = VisionHelpers.featurePrint(of: refContent) else { continue }

            var dist: Float = 0
            try? queryFP.computeDistance(&dist, to: refFP)
            print("[MapClueMatcher] dist=\(String(format:"%.3f",dist))  \(ref)")
            scores.append((ref, dist, candidate))
        }

        scores.sort { $0.dist < $1.dist }   // lower distance = better match

        print("[MapClueMatcher] Top matches (query \(cleanQuery.width)×\(cleanQuery.height)):")
        for entry in scores.prefix(3) {
            print("  dist=\(String(format:"%.3f", entry.dist))  \(entry.ref)")
        }

        if let best = scores.first, let dir = debugDir,
           let refFull = loadReferenceImage(named: best.ref) {
            savePNG(cleanQuery,                             to: dir.appendingPathComponent("query_thumb.png"))
            savePNG(innerParchmentCrop(refFull) ?? refFull, to: dir.appendingPathComponent("best_ref_thumb.png"))
        }

        guard let best = scores.first, best.dist <= matchThreshold else {
            print("[MapClueMatcher] No match below distance threshold \(matchThreshold)")
            return nil
        }

        // Runner-up gate: reject if the second-best is within `runnerUpMargin`
        // of the best (genuinely confusable pair). One-candidate corpora skip
        // this check.
        if scores.count >= 2 {
            let runnerUp = scores[1]
            if best.dist + runnerUpMargin > runnerUp.dist {
                print("[MapClueMatcher] ✗ Rejected '\(best.candidate.location ?? best.ref)' "
                      + "dist=\(String(format:"%.3f",best.dist)) - runner-up "
                      + "'\(runnerUp.candidate.location ?? runnerUp.ref)' too close "
                      + "dist=\(String(format:"%.3f",runnerUp.dist)) "
                      + "(margin \(String(format:"%.3f", runnerUp.dist - best.dist)) < \(runnerUpMargin))")
                return nil
            }
        }

        print("[MapClueMatcher] ✓ Match '\(best.candidate.location ?? best.ref)' dist=\(String(format:"%.3f",best.dist))")
        return best.candidate
    }

    // MARK: - Vision FeaturePrint

    /// Computes a `VNFeaturePrintObservation` for `image` synchronously.

    /// Crops the dark decorative border from old-style "TREASURE MAP" reference
    /// images.  Scans inward from each edge in a 128-px-wide thumbnail until
    /// the row/column average brightness exceeds 0.45, which reliably separates
    /// the very-dark title bar and rolled-parchment border from the cream
    /// interior without ever cutting into map-content rows.
    /// Returns nil if the crop would be empty.
    private func innerParchmentCrop(_ image: CGImage) -> CGImage? {
        let iw = image.width, ih = image.height
        let tw = 128, th = max(1, Int((128.0 * Double(ih) / Double(iw)).rounded()))
        guard let thumb = thumbnail(of: image, size: CGSize(width: tw, height: th)),
              let grey  = toGreyscale(thumb) else { return nil }

        let pb = parchmentBounds(grey, w: tw, h: th, light: 0.45)
        guard pb.w > 4 && pb.h > 4 else { return nil }

        let sx = Double(iw) / Double(tw), sy = Double(ih) / Double(th)
        let cropRect = CGRect(
            x: (Double(pb.x0) * sx).rounded(),
            y: (Double(pb.y0) * sy).rounded(),
            width:  (Double(pb.w) * sx).rounded(),
            height: (Double(pb.h) * sy).rounded()
        )
        return image.cropping(to: cropRect)
    }

    // MARK: - Captured Image Cleanup

    /// Scans the captured crop from both ends and removes dark rows that
    /// ClueScrollDetector sometimes captures outside the parchment area
    /// (e.g. game background grass below the scroll).
    ///
    /// Threshold is 0.30: game background (grass, UI chrome) averages ~0.10–0.20,
    /// while parchment rows - even those with dense dark building drawings - stay
    /// above 0.30.  The old threshold of 0.55 incorrectly trimmed bottom rows
    /// containing map building artwork.
    private func trimNonParchmentBottom(from image: CGImage) -> CGImage {
        let W = image.width, H = image.height
        guard H > 10 else { return image }

        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(
            data: &rgba, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

        func rowBrightness(_ row: Int) -> Float {
            var sum: Float = 0
            let base = row * W * 4
            for col in 0..<W {
                let i = base + col * 4
                let r = Float(rgba[i]), g = Float(rgba[i+1]), b = Float(rgba[i+2])
                sum += (0.299*r + 0.587*g + 0.114*b) / 255.0
            }
            return sum / Float(W)
        }

        let parchmentThreshold: Float = 0.30
        // Scan from the top looking for the first parchment row *after* any dark
        // section (title bar / decorative border).  A crop that starts with a
        // bright decorative border followed by a dark title bar followed by the
        // parchment body must not stop at the initial bright row - it must
        // continue past the dark gap to find where the parchment body begins.
        var top = 0
        var seenDark = false
        for row in 0..<(H / 2) {
            let isBright = rowBrightness(row) > parchmentThreshold
            if !isBright { seenDark = true }
            if seenDark && isBright { top = row; break }
        }
        var bottom = H - 1
        for row in stride(from: H - 1, through: H / 2, by: -1) {
            if rowBrightness(row) > parchmentThreshold { bottom = row; break }
        }

        guard top > 0 || bottom < H - 1 else { return image }

        let trimRect = CGRect(x: 0, y: CGFloat(top),
                              width: CGFloat(W), height: CGFloat(bottom - top + 1))
        let trimmed = image.cropping(to: trimRect) ?? image
        print("[MapClueMatcher] Trimmed query: \(W)×\(H) → \(W)×\(trimmed.height) (rows \(top)–\(bottom))")
        return trimmed
    }

    // MARK: - Image Loading

    /// Loads a reference PNG from the MapImages/ bundle subdirectory.
    /// No vertical flip is applied: both PNGs and screen-capture CGImages store
    /// row 0 at the top (y increases downward), so they are already in the same
    /// orientation.  We tell Vision about this via `orientation: .up` in
    /// `VisionHelpers.featurePrint(of:)`.
    private func loadReferenceImage(named ref: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: ref,
                                        withExtension: "png",
                                        subdirectory: "MapImages"),
              let provider = CGDataProvider(url: url as CFURL),
              let img = CGImage(pngDataProviderSource: provider,
                                decode: nil,
                                shouldInterpolate: true,
                                intent: .defaultIntent)
        else { return nil }
        return img
    }

    /// Flips a CGImage vertically by drawing it with a y-axis mirror transform.
    private func flipVertically(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    // MARK: - Image Helpers

    private func thumbnail(of image: CGImage, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Returns a flat Float array of greyscale pixel values in [0, 1].
    private func toGreyscale(_ image: CGImage) -> [Float]? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        var grey = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4])
            let g = Float(rgba[i * 4 + 1])
            let b = Float(rgba[i * 4 + 2])
            grey[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return grey
    }

    // MARK: - Parchment Bounds

    private struct BBox { let x0, y0, x1, y1, w, h: Int }

    /// Scans inward from each edge of a greyscale array until the row/column
    /// average brightness exceeds `light`, returning the bounding rect of the
    /// bright interior.  Used by `innerParchmentCrop` to locate the cream
    /// parchment area inside a reference image's decorative border.
    private func parchmentBounds(_ grey: [Float], w: Int, h: Int,
                                  light: Float = 0.72) -> BBox {
        var top = 0, bottom = h - 1, left = 0, right = w - 1
        for row in 0..<h {
            let avg = (0..<w).reduce(0.0) { $0 + grey[row * w + $1] } / Float(w)
            if avg > light { top = row; break }
        }
        for row in stride(from: h - 1, through: 0, by: -1) {
            let avg = (0..<w).reduce(0.0) { $0 + grey[row * w + $1] } / Float(w)
            if avg > light { bottom = row; break }
        }
        for col in 0..<w {
            let avg = (0..<h).reduce(0.0) { $0 + grey[$1 * w + col] } / Float(h)
            if avg > light { left = col; break }
        }
        for col in stride(from: w - 1, through: 0, by: -1) {
            let avg = (0..<h).reduce(0.0) { $0 + grey[$1 * w + col] } / Float(h)
            if avg > light { right = col; break }
        }
        let bw = max(1, right - left), bh = max(1, bottom - top)
        return BBox(x0: left, y0: top, x1: right, y1: bottom, w: bw, h: bh)
    }

    // MARK: - Debug

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            try? (data as Data).write(to: url)
        }
    }
}
