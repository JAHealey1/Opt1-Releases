import Vision
import CoreGraphics

/// A text observation with its position in the source image.
struct LocatedText {
    let text: String
    let confidence: Float
    /// Bounding rect in image-pixel coordinates (origin top-left).
    let bounds: CGRect
}

/// Extracts clue text from a preprocessed clue scroll image using Vision OCR.
/// Runs on a detached background task to avoid blocking the main actor.
struct ClueTextReader {

    /// Returns one string per Vision text observation (one per text block / line).
    /// Callers should try matching each observation individually — joining them into
    /// a single string dilutes similarity scores when noisy UI elements are present.
    ///
    /// - Parameter languageCorrection: Pass `true` when trying to read decorative /
    ///   stylised fonts (e.g. the RS3 compass region label). Defaults to `false` so
    ///   anagram text is not mangled by autocorrect.
    func readObservations(from image: CGImage, languageCorrection: Bool = false) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = languageCorrection
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            return (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { obs -> String? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Drop very short fragments — almost always noise
                    return text.count >= 3 ? text : nil
                }
        }.value
    }

    /// Like readObservations but also returns each text block's bounding rect
    /// in image-pixel coordinates (top-left origin).  Used to locate the clue
    /// scroll on screen from its readable content rather than from colour.
    ///
    /// - Parameter recognitionLevel: `.fast` for lightweight detection passes
    ///   (e.g. auto-detect at 2 fps), `.accurate` when precise text and bounds
    ///   matter (e.g. the one-shot pipeline).
    func readLocatedObservations(
        from image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        languageCorrection: Bool = false
    ) async throws -> [LocatedText] {
        let w = image.width, h = image.height
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = languageCorrection
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            return (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { obs -> LocatedText? in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 3 else { return nil }

                    let vb = obs.boundingBox
                    let px = vb.minX * CGFloat(w)
                    let py = (1 - vb.maxY) * CGFloat(h)
                    let pw = vb.width  * CGFloat(w)
                    let ph = vb.height * CGFloat(h)
                    return LocatedText(text: text,
                                       confidence: top.confidence,
                                       bounds: CGRect(x: px, y: py, width: pw, height: ph))
                }
        }.value
    }

    /// Convenience: joined text for display purposes.
    func readText(from image: CGImage) async throws -> String {
        try await readObservations(from: image).joined(separator: " ")
    }

    // MARK: - Dual-anchor centred read

    /// Approximate width of a single space in the centred RS3 clue body font
    /// at our typical preprocessed crop scale. Used as the offset for the
    /// secondary anchor in `readBestCenteredObservations`. Calibrated by eye —
    /// a half-space (~3 px) is too small to influence rasterisation, a full
    /// glyph (~14 px) loses the leading edge entirely on narrow scrolls.
    static let centredAnchorSpaceWidth: CGFloat = 7

    /// Runs Vision OCR `anchorOffsets.count` times — once per offset — over
    /// horizontally-translated copies of `image` and returns the observation
    /// set with the highest mean candidate confidence. The motivation is that
    /// the centred clue body sometimes drops its leading character at the
    /// canonical 0-px anchor due to sub-pixel rasterisation in the RS3 font;
    /// shifting the bitmap by ~one space-width gives Vision a different
    /// sampling grid and recovers the missing glyph on those captures.
    ///
    /// The translation pads the right edge with white (matches the
    /// black-on-white preprocessor output) so Vision doesn't pick up a dark
    /// stripe as a new glyph stroke.
    ///
    /// - Parameters:
    ///   - image: Preprocessed (binarised) clue-scroll body crop.
    ///   - anchorOffsets: Pixel offsets to apply, e.g. `[0, 7]`. An offset
    ///     of 0 reads the original image directly. An empty array falls
    ///     back to a single non-shifted read.
    ///   - languageCorrection: Forwarded to `VNRecognizeTextRequest`.
    /// - Returns: The strings from the highest mean-confidence pass.
    func readBestCenteredObservations(
        from image: CGImage,
        anchorOffsets: [CGFloat],
        languageCorrection: Bool = false
    ) async throws -> [String] {
        let offsets: [CGFloat] = anchorOffsets.isEmpty ? [0] : anchorOffsets

        return try await withThrowingTaskGroup(of: (offset: CGFloat, mean: Float, strings: [String]).self) { group in
            for offset in offsets {
                group.addTask {
                    let shifted: CGImage
                    if offset == 0 {
                        shifted = image
                    } else {
                        shifted = Self.shiftHorizontally(image, by: offset) ?? image
                    }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = languageCorrection
                    request.recognitionLanguages = ["en-US"]

                    let handler = VNImageRequestHandler(cgImage: shifted, options: [:])
                    try handler.perform([request])

                    let raw = (request.results as? [VNRecognizedTextObservation] ?? [])
                    var strings: [String] = []
                    var confidences: [Float] = []
                    for obs in raw {
                        guard let top = obs.topCandidates(1).first else { continue }
                        let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard text.count >= 3 else { continue }
                        strings.append(text)
                        confidences.append(top.confidence)
                    }
                    let mean: Float = confidences.isEmpty
                        ? 0
                        : confidences.reduce(0, +) / Float(confidences.count)
                    return (offset, mean, strings)
                }
            }

            var best: (offset: CGFloat, mean: Float, strings: [String]) = (0, -1, [])
            var attempts: [(offset: CGFloat, mean: Float, count: Int)] = []
            for try await result in group {
                attempts.append((result.offset, result.mean, result.strings.count))
                if result.mean > best.mean { best = result }
            }
            attempts.sort { $0.offset < $1.offset }
            let summary = attempts
                .map { "Δx=\(Int($0.offset)) mean=\(String(format: "%.2f", $0.mean)) n=\($0.count)" }
                .joined(separator: "  ")
            print("[ClueTextReader] dual-anchor OCR — \(summary) → picked Δx=\(Int(best.offset))")
            return best.strings
        }
    }

    /// Translates `image` horizontally by `dx` pixels (positive = right) and
    /// pads the exposed area with white so Vision's binarised input stays
    /// dominated by the parchment background tone after preprocessing.
    private static func shiftHorizontally(_ image: CGImage, by dx: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: dx, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
