import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Result type

struct SliderLocation {
    /// Rect of the 5×5 puzzle grid in the original (full-resolution) CGImage
    /// coordinate space.
    let puzzleRectInImage: CGRect
    /// The anchor key that produced this match (e.g. "eoc_120").
    let anchorKey: String
    /// Normalised cross-correlation peak score in [0, 1]. Higher is better.
    let confidence: Float
}

// MARK: - Locator

/// Finds a slide-puzzle interface in a captured RS window image by
/// template-matching a set of pre-collected close-X needle PNGs and then
/// applying per-uiScale offsets to derive the 5×5 board rect.
///
/// Needles and the offset table live in
///   `Matching/Resources/SliderAnchors/anchors/<key>.png`
///   `Matching/Resources/SliderAnchors/anchor_offsets.json`
///
/// Keys are `scale_<N>` for NXT UI scales
/// 70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 225, 250, 275, 300.
/// The same needle works for both Modern and Classic interfaces.
///
/// The locator normalises the captured image before searching by dividing out
/// the device-pixel-ratio, so a needle captured at 100% NXT on a 1× display
/// matches correctly on both 1× and Retina (2×) displays.
///
/// All work is synchronous and runs in well under 50 ms on Apple Silicon for
/// a typical RS window.
final class SliderInterfaceLocator {

    // MARK: - Minimum NCC score to accept a match
    //
    // Two thresholds because the locator runs in two effective modes:
    //   * Bracketed (default) — the user has pinned an RS UI scale in
    //     Settings, so we only accept matches from a 3-anchor bracket
    //     centred on that scale. False positives from off-scale lookalikes
    //     are excluded *by construction*, so the threshold can be lower.
    //   * Open — bracketing is bypassed (e.g. the bracket itself fails to
    //     find anything plausible). The full 13-anchor pool gates a wider
    //     class of false positives, hence the stricter bar.

    static let confidenceThreshold: Float = 0.92
    static let bracketedConfidenceThreshold: Float = 0.70

    /// Fraction of the puzzle's width/height to add as padding on every side
    /// of the returned crop rect.
    ///
    /// The downstream rails localiser (`GridLocalizer.detectRails`) computes
    /// |Sobel| in the interior pixels only — column 0 and column W-1 are zero.
    /// When the crop is *exactly* the puzzle rect, the leftmost and rightmost
    /// rails fall on those zeroed columns and the peak fitter only sees four
    /// of the six rails, picking up internal tile gradients instead. A small
    /// margin pushes the outer rails inward where Sobel can resolve them and
    /// gives the fitter the standard "6 peaks" geometry it expects.
    static let cropPaddingFraction: CGFloat = 0.05

    // MARK: - Public API

    /// Returns a `SliderLocation` when a slider modal is detected in `image`,
    /// or `nil` if no anchor clears the confidence threshold.
    ///
    /// - Parameter image:     The captured RS window image (any resolution).
    /// - Parameter logicalWindowWidth: The logical (point) width of the RS window,
    ///   used to compute the device-pixel-ratio for Retina rescaling. Pass the
    ///   `SCWindow.frame.width` value. If nil the image is used as-is.
    func locate(in image: CGImage, logicalWindowWidth: CGFloat? = nil) -> SliderLocation? {
        guard let match = PuzzleModalLocator().locateCloseButton(
            in: image,
            logicalWindowWidth: logicalWindowWidth,
            bracketedConfidenceThreshold: Self.bracketedConfidenceThreshold,
            onNoMatchCandidate: { candidate in
                print("[SliderInterfaceLocator] Saving no-match debug candidate '\(candidate.anchorKey)' conf=\(String(format: "%.3f", candidate.confidence))")
                let diagnostic = self.buildDiagnosticLocation(candidate: candidate, image: image)
                self.saveDebug(
                    image: image,
                    match: candidate.xMatchInImage,
                    puzzle: diagnostic.rect,
                    anchorKey: candidate.anchorKey,
                    geometryAnchorKey: candidate.pinnedAnchor.key,
                    confidence: candidate.confidence,
                    prefix: "nomatch"
                )
            },
            logPrefix: "SliderInterfaceLocator"
        ) else {
            return nil
        }

        let location = buildLocation(match: match, image: image)
        print("[SliderInterfaceLocator] Puzzle rect=(\(Int(location.rect.minX)),\(Int(location.rect.minY)) \(Int(location.rect.width))×\(Int(location.rect.height)))")
        saveDebug(
            image: image,
            match: match.xMatchInImage,
            puzzle: location.rect,
            anchorKey: match.matchedAnchorKey,
            confidence: match.confidence
        )
        return SliderLocation(
            puzzleRectInImage: location.rect,
            anchorKey: match.matchedAnchorKey,
            confidence: match.confidence
        )
    }

    /// Builds the accepted puzzle rect (with rails-localiser padding). The
    /// matched-needle debug rect comes directly from the shared modal locator.
    ///
    /// - `geometryAnchor` provides `tlOffsetFromX` and `puzzleSize` — i.e.
    ///   how far from the X glyph the puzzle TL lives, and how large the
    ///   puzzle is. Always the pinned scale.
    private func buildLocation(match: PuzzleModalAnchorMatch, image: CGImage) -> (rect: CGRect, matchRectInImage: CGRect) {
        let geometryAnchor = match.pinnedAnchor
        let imageScale = match.searchToImageScale
        let puzzleTLInImage = CGPoint(
            x: match.xMatchInImage.minX + CGFloat(geometryAnchor.offset.tlOffsetFromX[0]) * imageScale,
            y: match.xMatchInImage.minY + CGFloat(geometryAnchor.offset.tlOffsetFromX[1]) * imageScale
        )
        let exactPuzzleRectInImage = CGRect(
            x: puzzleTLInImage.x,
            y: puzzleTLInImage.y,
            width: CGFloat(geometryAnchor.offset.puzzleSize[0]) * imageScale,
            height: CGFloat(geometryAnchor.offset.puzzleSize[1]) * imageScale
        )
        let pad = max(8.0, exactPuzzleRectInImage.width * Self.cropPaddingFraction)
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let puzzleRectInImage = exactPuzzleRectInImage
            .insetBy(dx: -pad, dy: -pad)
            .intersection(imageBounds)
            .integral
        return (puzzleRectInImage, match.xMatchInImage)
    }

    private func buildDiagnosticLocation(
        candidate: PuzzleModalAnchorCandidate,
        image: CGImage
    ) -> (rect: CGRect, matchRectInImage: CGRect) {
        let geometryAnchor = candidate.pinnedAnchor
        let imageScale = candidate.searchToImageScale
        let puzzleTLInImage = CGPoint(
            x: candidate.xMatchInImage.minX + CGFloat(geometryAnchor.offset.tlOffsetFromX[0]) * imageScale,
            y: candidate.xMatchInImage.minY + CGFloat(geometryAnchor.offset.tlOffsetFromX[1]) * imageScale
        )
        let puzzleRectInImage = CGRect(
            x: puzzleTLInImage.x,
            y: puzzleTLInImage.y,
            width: CGFloat(geometryAnchor.offset.puzzleSize[0]) * imageScale,
            height: CGFloat(geometryAnchor.offset.puzzleSize[1]) * imageScale
        )
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        .integral

        return (puzzleRectInImage, candidate.xMatchInImage)
    }

    // MARK: - Debug image dump

    /// Renders the captured image with the matched needle (cyan) and the
    /// inferred puzzle rect (yellow) drawn on top, so we can inspect whether
    /// the X anchor matched a real slider close button and whether the
    /// derived puzzle rect actually frames the 5×5 board.
    private func saveDebug(image: CGImage,
                           match: CGRect,
                           puzzle: CGRect,
                           anchorKey: String,
                           geometryAnchorKey: String? = nil,
                           confidence: Float,
                           prefix: String = "match") {
        guard let dir = AppSettings.debugSubfolder(named: "SliderLocatorDebug") else {
            print("[SliderInterfaceLocator] Debug image skipped for '\(prefix)' because debug mode is off (isDebugEnabled=\(AppSettings.isDebugEnabled))")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let W = image.width, H = image.height
        guard let ctx = CGContext(
            data: nil, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw the captured image right-side up in default CG y-up coords.
        // (Same convention used by PuzzleBoxCoordinator's debug renderer.)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Convert an image-space (y-down) rect to CG user-space (y-up).
        func userRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height)
        }

        // Inferred puzzle rect (yellow).
        let puzzleR = userRect(puzzle)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.95))
        ctx.setLineWidth(3)
        ctx.stroke(puzzleR)

        // Tick marks at the puzzle rect's TOP edge (image-space top = high y in
        // CG user-space) so vertical orientation is unambiguous in the saved
        // PNG even when the picture is otherwise rotationally symmetric.
        let tickLen: CGFloat = 14
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.6, blue: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: puzzleR.minX, y: puzzleR.maxY))
        ctx.addLine(to: CGPoint(x: puzzleR.minX, y: puzzleR.maxY + tickLen))
        ctx.move(to: CGPoint(x: puzzleR.maxX, y: puzzleR.maxY))
        ctx.addLine(to: CGPoint(x: puzzleR.maxX, y: puzzleR.maxY + tickLen))
        ctx.strokePath()

        // Matched needle rect (cyan).
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(2)
        ctx.stroke(userRect(match))

        guard let annotated = ctx.makeImage() else { return }
        let ts = Int(Date().timeIntervalSince1970)

        @discardableResult
        func writePNG(_ cgImage: CGImage, to fileURL: URL) -> Bool {
            guard let dest = CGImageDestinationCreateWithURL(
                fileURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                print("[SliderInterfaceLocator] Failed to create debug PNG destination: \(fileURL.path)")
                return false
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            let ok = CGImageDestinationFinalize(dest)
            if !ok {
                print("[SliderInterfaceLocator] Failed to write debug PNG: \(fileURL.path)")
            }
            return ok
        }

        writePNG(annotated, to: dir.appendingPathComponent("\(prefix)_\(ts).png"))

        // Raw slider crop — same pixels we hand off to the downstream pipeline
        // for successful matches; for `nomatch` cases this is the patch the
        // (sub-threshold) best anchor *thought* the puzzle was at, which is
        // exactly what we want to inspect to debug a desert-area failure.
        if let crop = image.cropping(to: puzzle.integral) {
            writePNG(crop, to: dir.appendingPathComponent("\(prefix)_\(ts)_crop.png"))
        }

        // Crop of the matched-needle area (25×25 in 100% UI scale) so we can
        // diff it pixel-for-pixel against the bundle-loaded anchor PNG when a
        // capture-time vs runtime mismatch is suspected.
        if let needleCrop = image.cropping(to: match.integral) {
            writePNG(needleCrop, to: dir.appendingPathComponent("\(prefix)_\(ts)_needle.png"))
        }

        // Side-car text summary so we can grep numbers without opening the PNG.
        let kind = prefix == "match" ? "match" : "no-match (best sub-threshold candidate)"
        let summary = """
        Slider locator \(kind) — \(Date())
        Image: \(W)×\(H)
        Anchor: \(anchorKey)  confidence: \(String(format: "%.3f", confidence))  threshold: \(Self.confidenceThreshold)
        Geometry anchor: \(geometryAnchorKey ?? anchorKey)
        Needle match rect (image-space): (\(Int(match.minX)), \(Int(match.minY))) \(Int(match.width))×\(Int(match.height))
        Inferred puzzle rect (image-space): (\(Int(puzzle.minX)), \(Int(puzzle.minY))) \(Int(puzzle.width))×\(Int(puzzle.height))
        """
        try? summary.write(to: dir.appendingPathComponent("\(prefix)_\(ts).txt"),
                           atomically: true, encoding: .utf8)

        print("[SliderInterfaceLocator] Debug saved to SliderLocatorDebug/\(prefix)_\(ts).png")
    }
}
