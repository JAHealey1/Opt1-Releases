import CoreGraphics
import Foundation
import ImageIO
import Opt1Matching
import Vision

/// Detects the clue scroll interface in a captured RuneScape frame.
///
/// Detection cascade (first success wins):
///  1. OCR title match - finds "MYSTERIOUS CLUE SCROLL" / "TREASURE MAP" via
///     Vision and derives bounds from title + body text observations.
///  2. Body-text anchor - when the title font is too garbled, looks for
///     well-known clue body phrases in the OCR output.
///  3. Close-button NCC - when OCR fails entirely (e.g. external monitors
///     with different colour profiles), locates the NXT modal close-X via
///     template matching and derives bounds from fixed chrome offsets, the
///     same approach used by Celtic Knot and Towers detection.
struct ClueScrollDetector {

    // MARK: - Proportional margin constants (tunable for calibration)

    /// Extra horizontal padding on each side, as a fraction of text-union width.
    private let horizontalMarginRatio: CGFloat = 0.10
    /// Extra vertical padding above the title, as a fraction of text-union width.
    private let topMarginRatio: CGFloat = 0.02
    /// Extra vertical padding below the lowest body text, as a fraction of text-union width.
    private let bottomMarginRatio: CGFloat = 0.06
    /// Minimum scroll height as a multiple of text-union width, so map clues
    /// with sparse text still get a tall-enough crop.
    private let minHeightToWidthRatio: CGFloat = 1.2
    /// Top extension used in the body-anchor fallback path (no title found).
    /// Measured as a fraction of the body-text union width.  Empirically the
    /// gap from the first body line to the scroll top (title bar + header) is
    /// ~47 % of the body width at all supported resolutions; 0.55 adds a
    /// comfortable safety margin on top of that.
    private let bodyTopMarginRatio: CGFloat = 0.55
    /// How far (as a fraction of title width) a body observation's horizontal
    /// centre can be from the title centre and still be included.
    private let bodyHorizontalTolerance: CGFloat = 1.5
    /// Maximum vertical gap (as a multiple of title height) allowed between
    /// consecutive body observations. Anything below a gap larger than this
    /// is rejected - prevents stray UI text (health bar, chat) from inflating
    /// the scroll bounds.
    private let maxBodyGapToTitleHeight: CGFloat = 12.0

    // MARK: - Parchment edge-scan constants

    /// Minimum brightness (0-1) for a pixel to be considered parchment.
    private let parchmentBrightnessMin: Float = 0.40
    /// Minimum fraction of pixels in a scan line that must be parchment
    /// to continue expanding the bounds in that direction.
    private let parchmentLineFraction: Float = 0.50
    /// Width of the perpendicular band (in px) sampled when scanning
    /// left/right/down.  Wider = more robust against small gaps.
    private let parchmentScanBandWidth: Int = 20
    /// Maximum distance (px) to scan in any direction from the title.
    /// Safety cap to avoid runaway scans in unusual layouts.
    private let parchmentMaxScanDistance: Int = 600

    // MARK: - Public API

    /// Returns the inner text rect of the clue scroll, or nil if not found.
    /// Uses `.accurate` OCR; intended for the one-shot pipeline trigger.
    func detectClueRect(in image: CGImage) async -> CGRect? {
        let reader = ClueTextReader()
        guard let observations = try? await reader.readLocatedObservations(
            from: image, recognitionLevel: .accurate
        ) else {
            print("[ClueScrollDetector] OCR failed - no observations")
            saveDebugOutput(image: image, observations: [], title: nil,
                            bodyObs: [], rejectedObs: [], clueRect: nil, accepted: false)
            return nil
        }

        if let title = findTitle(in: observations) {
            return detectClueRectFromTitle(title, observations: observations, image: image)
        }

        // Title-font OCR is too garbled to match - check for well-known clue
        // body phrases that can only appear inside an open clue scroll.
        print("[ClueScrollDetector] No title match in \(observations.count) observations "
              + "- attempting body-text anchor fallback")
        if let result = findScrollRectViaBodyAnchor(in: image, observations: observations) {
            let rejectedObs = observations.filter { obs in
                !result.bodyObs.contains { $0.text == obs.text && $0.bounds == obs.bounds }
            }
            print("[ClueScrollDetector] Body-anchor clueRect: \(result.clueRect.integral) "
                  + "from \(result.bodyObs.count) observations")
            saveDebugOutput(image: image, observations: observations, title: nil,
                            bodyObs: result.bodyObs, rejectedObs: rejectedObs,
                            clueRect: result.clueRect, accepted: true,
                            bodyAnchorFallback: true)
            return result.clueRect
        }

        // Title-font OCR and body-text corpus both failed - fall back to locating
        // the NXT modal close-X button via NCC template matching and deriving the
        // scroll rect from its position (same approach as Celtic Knot detection).
        if let clueRect = await findScrollRectViaCloseButton(in: image) {
            print("[ClueScrollDetector] Close-button clueRect: \(clueRect.integral)")
            saveDebugOutput(image: image, observations: observations, title: nil,
                            bodyObs: [], rejectedObs: observations,
                            clueRect: clueRect, accepted: true)
            return clueRect
        }

        print("[ClueScrollDetector] No title, body anchor, or close button found in \(observations.count) observations")
        saveDebugOutput(image: image, observations: observations, title: nil,
                        bodyObs: [], rejectedObs: observations, clueRect: nil, accepted: false)
        return nil
    }

    /// Handles the normal title-found detection path.
    private func detectClueRectFromTitle(
        _ title: LocatedText,
        observations: [LocatedText],
        image: CGImage
    ) -> CGRect? {
        let titleCentreX = title.bounds.midX
        let titleHalfSpan = title.bounds.width * bodyHorizontalTolerance
        let titleBottom = title.bounds.maxY
        let maxGap = title.bounds.height * maxBodyGapToTitleHeight

        var candidates: [LocatedText] = []
        var rejectedObs: [LocatedText] = []

        for obs in observations {
            if obs.text == title.text && obs.bounds == title.bounds { continue }

            let isBelow = obs.bounds.minY >= titleBottom - 2
            let horizClose = abs(obs.bounds.midX - titleCentreX) < titleHalfSpan

            if isBelow && horizClose {
                candidates.append(obs)
            } else {
                rejectedObs.append(obs)
            }
        }

        // Sort by Y and cut off after a large vertical gap to exclude distant
        // UI elements (health bar, chat) that happen to be horizontally centred.
        candidates.sort { $0.bounds.minY < $1.bounds.minY }
        var bodyObs: [LocatedText] = []
        var previousBottom = titleBottom
        for obs in candidates {
            let gap = obs.bounds.minY - previousBottom
            if gap > maxGap {
                rejectedObs.append(contentsOf: candidates[bodyObs.count...])
                break
            }
            bodyObs.append(obs)
            previousBottom = obs.bounds.maxY
        }

        let clueRect: CGRect
        var usedParchmentFallback = false

        if bodyObs.isEmpty, let parchRect = findParchmentExtent(in: image, around: title.bounds) {
            usedParchmentFallback = true
            clueRect = parchRect
            print("[ClueScrollDetector] OCR: \(observations.count) observations, "
                  + "title: '\(title.text)' at \(title.bounds.integral), "
                  + "no body text - parchment fallback: \(clueRect.integral)")
        } else {
            let imgW = CGFloat(image.width)
            let imgH = CGFloat(image.height)

            let allScrollObs = [title] + bodyObs
            let unionRect = allScrollObs.map(\.bounds).reduce(allScrollObs[0].bounds) { $0.union($1) }

            let marginH = unionRect.width * horizontalMarginRatio
            let marginTop = unionRect.width * topMarginRatio
            let marginBot = unionRect.width * bottomMarginRatio

            let rawLeft = unionRect.minX - marginH
            let rawRight = unionRect.maxX + marginH
            let rawTop = unionRect.minY - marginTop
            let rawWidth = rawRight - rawLeft

            let minBottom = rawTop + rawWidth * minHeightToWidthRatio
            let rawBottom = max(unionRect.maxY + marginBot, minBottom)

            clueRect = CGRect(
                x: max(0, rawLeft),
                y: max(0, rawTop),
                width: min(rawRight, imgW) - max(0, rawLeft),
                height: min(rawBottom, imgH) - max(0, rawTop)
            )

            print("[ClueScrollDetector] OCR: \(observations.count) observations, "
                  + "title: '\(title.text)' at \(title.bounds.integral), "
                  + "\(bodyObs.count) body lines")
            print("[ClueScrollDetector] Computed clueRect: \(clueRect.integral) "
                  + "from \(bodyObs.count) body observations")
        }

        saveDebugOutput(image: image, observations: observations, title: title,
                        bodyObs: bodyObs, rejectedObs: rejectedObs,
                        clueRect: clueRect, accepted: true,
                        parchmentFallback: usedParchmentFallback)

        return clueRect
    }

    // MARK: - Title Matching

    /// Canonical title strings plus a curated list of common OCR mis-reads
    /// observed against the decorative RS3 clue-scroll title font.  The
    /// synonyms are spaceless uppercase forms (matching the normalisation
    /// applied to OCR input below) and feed only the Tier-2 Levenshtein
    /// fallback - Tier-1 substring checks remain untouched so we don't widen
    /// false-positives on chat or UI text.
    private static let titleTargets: [String] = ([
        // Canonical
        "MYSTERIOUS CLUE SCROLL",
        "TREASURE MAP",
        "MYSTERIOUS CLUE",
        "MYSTERIOUSCLUE",
        "MYSTERIOUSSCROLL",
        "SANDY CLUE SCRO",
        "MYSHROUS CLUE SCROLL",
        "MVSNDOS CIR CCROI",
        "MVSNDOSCIRCCROI",
    ] as [String]).map { $0.replacingOccurrences(of: " ", with: "") }

    /// Maximum normalised edit distance (0-1) to accept as a title match.
    /// Tightened from 0.50 → 0.40 once the synonym list above absorbs the
    /// most common OCR corruptions; the looser ratio is no longer needed and
    /// it was the single biggest source of false-positive titles on chat lines.
    private static let maxEditDistanceRatio: Double = 0.40

    /// Maximum raw text length to consider as a title candidate.
    /// Real titles are ≤ 25 chars ("MYSTERIOUS CLUE SCROLL" = 22).
    /// OCR garbling adds at most a few extra chars.  Chat messages
    /// that mention "clue scroll" are always much longer.
    private static let maxTitleLength: Int = 35

    /// Words that only appear in chat/UI text about clue scrolls (e.g. the
    /// Charos' carrier notification "Sealed clue scroll (elite)"), never in
    /// the actual decorative title rendered inside the scroll modal.
    /// If any of these are present the observation is rejected as a title
    /// candidate before the keyword checks run.
    private static let titleDenyList: [String] = [
        "SEALED", "ELITE", "HARD", "MEDIUM", "EASY", "MASTER",
        "CARRIER", "BACKPACK", "TRAILS",
    ]

    /// Checks whether a single text observation looks like a clue scroll title.
    ///
    /// Uses two tiers:
    ///  1. Fast substring checks for clean/lightly-garbled OCR output.
    ///  2. Levenshtein edit-distance fallback for heavily mangled text
    ///     (e.g. "MYSHROUSCHUR SCKOIHI" for "MYSTERIOUS CLUE SCROLL").
    ///
    /// A hard length cap rejects long chat messages that happen to contain
    /// keywords like "clue" and "scroll" in different contexts.
    static func isScrollTitle(_ text: String) -> Bool {
        guard text.count <= maxTitleLength else { return false }

        let u = text.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "5", with: "S")
            .replacingOccurrences(of: "0", with: "O")

        // Reject chat/UI fragments that mention clue scrolls contextually
        // (e.g. "Sealed clue scroll (elite)" from the Charos carrier message,
        // or "Treasure Trails" from the scan overlay) — none of these words
        // ever appear in the actual decorative scroll title.
        for denied in titleDenyList where u.contains(denied) { return false }

        // Tier 1: substring checks (fast path for clean reads)
        let hasClue = u.contains("CLUE")
        let hasMysterious = u.contains("MYSTERIOUS") || u.contains("MYS")
        let hasScroll = u.contains("SCROLL")

        if hasClue && (hasMysterious || hasScroll) { return true }
        // Require TREASURE + MAP together — bare "TREASURE" is too broad
        // ("Treasure Trails" appears in the scan overlay and chat).
        if u.contains("TREASURE") && u.contains("MAP") { return true }

        // Tier 2: Levenshtein distance for heavily garbled title text.
        // The decorative font often causes OCR to merge/substitute multiple
        // characters, breaking substring checks entirely.
        guard u.count >= 10 else { return false }
        for target in titleTargets {
            let dist = LevenshteinDistance.unicodeScalars(u, target)
            let ratio = Double(dist) / Double(max(u.count, target.count))
            if ratio <= maxEditDistanceRatio { return true }
        }

        return false
    }

    /// Returns the first observation that matches a scroll title, or nil.
    private func findTitle(in observations: [LocatedText]) -> LocatedText? {
        observations.first { Self.isScrollTitle($0.text) }
    }

    // MARK: - Body-text Anchor Fallback

    /// Returns true for text that is definitively part of a clue scroll body -
    /// phrases that essentially cannot appear outside an open clue scroll UI.
    /// Used when the decorative title font renders too small for Vision to
    /// produce a recognisable OCR result.
    private static func isBodyAnchorPhrase(_ text: String) -> Bool {
        let u = text.uppercased().replacingOccurrences(of: " ", with: "")
        // "Complete the action to solve the clue:" - printed on every
        // cryptic/anagram/coordinate/riddle clue step.
        if u.contains("COMPLETETHEACTIONTOSOLVE") || u.contains("COMPLETETHEACTION") {
            return true
        }
        // "Beware of double agents!" - printed on every emote clue step.
        // Emote clues don't show the "complete the action" header, so this
        // is the reliable anchor for that clue type.
        if u.contains("BEWAREOFDOUBLEAGENTS") { return true }

        if (u.contains("THISANAGRAMREVEALSWHO")) {
            return true
        }
        return false
    }

    /// Fallback for when the decorative title font produces OCR output too
    /// garbled for title matching.  Anchors on a well-known clue body phrase
    /// (e.g. "Complete the action to solve the clue:") and derives the scroll
    /// crop from the body-text union plus a generous upward margin that covers
    /// the title bar and the gap between it and the first body line.
    ///
    /// The top-margin ratio (`bodyTopMarginRatio`) was calibrated against 2560×1440
    /// captures where the gap from first-body-line to scroll top is ~47 % of the
    /// body-union width; 0.55 adds headroom for other resolutions.
    private func findScrollRectViaBodyAnchor(
        in image: CGImage,
        observations: [LocatedText]
    ) -> (clueRect: CGRect, bodyObs: [LocatedText])? {
        let anchors = observations.filter { Self.isBodyAnchorPhrase($0.text) }
        guard let firstAnchor = anchors.min(by: { $0.bounds.minY < $1.bounds.minY }) else {
            return nil
        }

        print("[ClueScrollDetector] Body-text anchor: '\(firstAnchor.text)' at \(firstAnchor.bounds.integral)")

        let anchorCentreX = firstAnchor.bounds.midX
        let anchorHalfSpan = firstAnchor.bounds.width * bodyHorizontalTolerance
        let maxGap = firstAnchor.bounds.height * maxBodyGapToTitleHeight

        var candidates = observations.filter { obs in
            abs(obs.bounds.midX - anchorCentreX) < anchorHalfSpan
                && obs.bounds.minY >= firstAnchor.bounds.minY - 2
        }
        candidates.sort { $0.bounds.minY < $1.bounds.minY }

        var bodyObs: [LocatedText] = []
        var previousBottom = firstAnchor.bounds.minY
        for obs in candidates {
            let gap = obs.bounds.minY - previousBottom
            if gap > maxGap { break }
            bodyObs.append(obs)
            previousBottom = obs.bounds.maxY
        }
        if bodyObs.isEmpty { bodyObs = [firstAnchor] }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let union = bodyObs.map(\.bounds).reduce(bodyObs[0].bounds) { $0.union($1) }

        let marginH   = union.width * horizontalMarginRatio
        let marginTop = union.width * bodyTopMarginRatio
        let marginBot = union.width * bottomMarginRatio

        let rawLeft  = union.minX - marginH
        let rawRight = union.maxX + marginH
        let rawTop   = union.minY - marginTop
        let rawWidth = rawRight - rawLeft

        let minBottom = rawTop + rawWidth * minHeightToWidthRatio
        let rawBottom = max(union.maxY + marginBot, minBottom)

        let clueRect = CGRect(
            x: max(0, rawLeft),
            y: max(0, rawTop),
            width: min(rawRight, imgW) - max(0, rawLeft),
            height: min(rawBottom, imgH) - max(0, rawTop)
        )

        return (clueRect, bodyObs)
    }

    // MARK: - Close-Button Fallback

    /// Locates the clue scroll modal using the NXT close-X button as a geometry
    /// anchor, reusing the same NCC template matcher and chrome-offset helpers
    /// that Celtic Knot and Towers detection use.
    ///
    /// This is the tertiary fallback: it fires when title OCR and body-text
    /// anchor both fail (decorative font on external monitors, novel clue text).
    /// Because it matches a single crisp pixel-art glyph rather than trying to
    /// segment cream-coloured parchment, it is robust across all screen sizes,
    /// colour profiles, and scroll types (treasure maps AND text clues).
    ///
    /// Returns the full scroll rect (top of dark chrome → bottom of dark chrome,
    /// left edge of title bar → right edge), or nil if the X isn't found.
    private func findScrollRectViaCloseButton(in image: CGImage) async -> CGRect? {
        guard let anchorMatch = PuzzleModalLocator().locateCloseButton(
            in: image,
            bracketedConfidenceThreshold: 0.70,
            logPrefix: "ClueScroll"
        ) else {
            print("[ClueScrollDetector] Close-button fallback: X not found")
            return nil
        }

        let uiScale = CGFloat(anchorMatch.pinnedAnchor.offset.uiScale) / 100.0
        let scale   = uiScale * anchorMatch.searchToImageScale
        let imageW  = CGFloat(image.width)
        let imageH  = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: imageW, height: imageH)

        print("[ClueScrollDetector] Close-button fallback: X at \(anchorMatch.xMatchInImage.integral) "
              + "scale=\(String(format: "%.3f", scale))")

        let titleBounds = scaledRectFromX(
            anchorMatch.xMatchInImage,
            offset: NXTModalOffsetsAt100.titleBarTopLeftFromX,
            size:   NXTModalOffsetsAt100.titleBarSize,
            scale:  scale
        ).intersection(imageBounds)

        guard titleBounds.width > 10, titleBounds.height > 2 else {
            print("[ClueScrollDetector] Close-button fallback: title rect out of bounds \(titleBounds)")
            return nil
        }

        guard let titleCrop = image.cropping(to: titleBounds.integral),
              let titleLines = try? await ClueTextReader().readObservations(from: titleCrop)
        else {
            print("[ClueScrollDetector] Close-button fallback: title crop/OCR failed - aborting")
            return nil
        }

        let titleText = titleLines.joined(separator: " ")
        let compact   = titleText.uppercased().filter { $0.isLetter }
        print("[ClueScrollDetector] Close-button fallback: title OCR '\(titleText)'")

        guard !compact.isEmpty else {
            print("[ClueScrollDetector] Close-button fallback: title OCR empty - cannot confirm clue scroll, aborting")
            return nil
        }

        if Self.isKnownNonScrollTitle(compact) {
            print("[ClueScrollDetector] Close-button fallback: title matched a non-scroll puzzle - aborting")
            return nil
        }

        print("[ClueScrollDetector] Close-button fallback: titleBounds \(titleBounds.integral)")

        let top: CGFloat
        if let detected = findDialogTopEdge(in: image, titleBounds: titleBounds) {
            top = detected
            print("[ClueScrollDetector] Close-button fallback: top edge y=\(String(format: "%.1f", detected))")
        } else {
            top = max(0, titleBounds.minY - 4 * scale)
            print("[ClueScrollDetector] Close-button fallback: top edge scan failed, using \(String(format: "%.1f", top))")
        }

        let bottom: CGFloat
        if let detected = findScrollContentBottom(in: image, titleBounds: titleBounds, scale: scale) {
            bottom = detected
            print("[ClueScrollDetector] Close-button fallback: bottom edge y=\(String(format: "%.1f", detected))")
        } else {
            bottom = min(imageH, titleBounds.maxY + 400 * scale)
            print("[ClueScrollDetector] Close-button fallback: bottom edge scan failed, using \(String(format: "%.1f", bottom))")
        }

        let clueRect = CGRect(
            x: titleBounds.minX,
            y: top,
            width: titleBounds.width,
            height: bottom - top
        ).intersection(imageBounds)

        print("[ClueScrollDetector] Close-button fallback accepted: \(clueRect.integral)")
        return clueRect
    }

    // MARK: - Parchment Edge Scan (map clue fallback)

    /// Scans outward from the title rect to find parchment edges.
    /// Returns the parchment extent (including title bar) as an image-pixel rect,
    /// or nil if the scan fails (e.g. couldn't read pixel data).
    ///
    /// The title sits in a dark header banner, so we can't scan left/right at
    /// the title Y - those pixels are dark.  Instead:
    ///  1. Scan downward from the title bottom to find the parchment entry point.
    ///  2. From within the parchment, scan left/right to find the width.
    ///  3. Continue scanning down to find the bottom edge.
    ///  4. Set the top to just above the title (the scroll's top is there).
    private func findParchmentExtent(in image: CGImage, around titleBounds: CGRect) -> CGRect? {
        let W = image.width, H = image.height
        guard W > 0, H > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(
            data: &rgba, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

        func brightness(x: Int, y: Int) -> Float {
            guard x >= 0, x < W, y >= 0, y < H else { return 0 }
            let i = (y * W + x) * 4
            let r = Float(rgba[i]), g = Float(rgba[i + 1]), b = Float(rgba[i + 2])
            return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }

        /// Fraction of pixels in a horizontal span [x0, x1) at row `y` that are bright.
        func hSpanBrightFraction(y: Int, x0: Int, x1: Int) -> Float {
            guard x1 > x0 else { return 0 }
            let cx0 = max(0, x0), cx1 = min(W, x1)
            guard cx1 > cx0 else { return 0 }
            var count = 0
            for x in cx0..<cx1 where brightness(x: x, y: y) >= parchmentBrightnessMin {
                count += 1
            }
            return Float(count) / Float(cx1 - cx0)
        }

        /// Fraction of pixels in a vertical span [y0, y1) at column `x` that are bright.
        func vSpanBrightFraction(x: Int, y0: Int, y1: Int) -> Float {
            guard y1 > y0 else { return 0 }
            let cy0 = max(0, y0), cy1 = min(H, y1)
            guard cy1 > cy0 else { return 0 }
            var count = 0
            for y in cy0..<cy1 where brightness(x: x, y: y) >= parchmentBrightnessMin {
                count += 1
            }
            return Float(count) / Float(cy1 - cy0)
        }

        let seedCX = Int(titleBounds.midX)
        let seedBot = Int(titleBounds.maxY)
        let bandW = parchmentScanBandWidth
        let maxDist = parchmentMaxScanDistance

        // Scan downward from the title bottom until we find a row where a
        // narrow horizontal band is mostly bright (parchment entry).
        let entryBandHalf = bandW / 2
        let entryBandX0 = seedCX - entryBandHalf
        let entryBandX1 = seedCX + entryBandHalf

        var parchmentEntryY: Int?
        for y in seedBot..<min(H, seedBot + 100) {
            if hSpanBrightFraction(y: y, x0: entryBandX0, x1: entryBandX1) >= parchmentLineFraction {
                parchmentEntryY = y
                break
            }
        }

        guard let entryY = parchmentEntryY else {
            print("[ClueScrollDetector] Parchment scan: no bright parchment found below title")
            return nil
        }

        let vBandY0 = entryY + 10
        let vBandY1 = entryY + 10 + bandW

        var left = seedCX
        for x in stride(from: seedCX, through: max(0, seedCX - maxDist), by: -1) {
            if vSpanBrightFraction(x: x, y0: vBandY0, y1: vBandY1) < parchmentLineFraction {
                left = x + 1
                break
            }
            left = x
        }

        var right = seedCX
        for x in seedCX..<min(W, seedCX + maxDist) {
            if vSpanBrightFraction(x: x, y0: vBandY0, y1: vBandY1) < parchmentLineFraction {
                right = x - 1
                break
            }
            right = x
        }

        var bottom = entryY
        for y in entryY..<min(H, entryY + maxDist) {
            if hSpanBrightFraction(y: y, x0: left, x1: right) < parchmentLineFraction {
                bottom = y - 1
                break
            }
            bottom = y
        }

        // Scan up through the dark title bar to find the scroll border.
        var top = entryY
        for y in stride(from: entryY, through: max(0, entryY - maxDist), by: -1) {
            if hSpanBrightFraction(y: y, x0: left, x1: right) < parchmentLineFraction {
                top = y + 1
                break
            }
            top = y
        }
        // Include the title bar: the top of the scroll is above the title text.
        let scrollTop = min(top, Int(titleBounds.minY) - 5)

        let pw = right - left
        let ph = bottom - scrollTop
        guard pw > 20, ph > 20 else {
            print("[ClueScrollDetector] Parchment scan too small: \(pw)x\(ph) - skipping fallback")
            return nil
        }

        let rect = CGRect(x: CGFloat(left), y: CGFloat(scrollTop),
                          width: CGFloat(pw), height: CGFloat(ph))
        print("[ClueScrollDetector] Parchment edge scan: \(rect.integral) "
              + "(entry at y=\(entryY), parchment left=\(left) right=\(right) "
              + "top=\(top) bottom=\(bottom))")
        return rect
    }

    // MARK: - Non-Scroll Puzzle Title Check

    /// Returns true when the compact (letters-only, uppercased) title text
    /// unambiguously identifies a non-scroll NXT puzzle modal.  Used by the
    /// close-button fallback to prevent false positives when the X button of
    /// a puzzle is matched while the clue scroll is not open.
    private static func isKnownNonScrollTitle(_ compact: String) -> Bool {
        // Celtic Knot
        if compact.contains("CELTICKNOT")
            || (compact.contains("CELTIC") && compact.contains("KNOT")) { return true }
        // Towers of Damath / Towers puzzle
        if compact.contains("TOWERS") || compact.contains("DAMATH") { return true }
        // Slider / Light Box puzzle
        if compact.contains("LIGHTBOX") || compact.contains("SLIDEPUZZLE") { return true }
        // Lockbox puzzle
        if compact.contains("LOCKBOX") { return true }
        return false
    }

    // MARK: - Debug Output

    private func saveDebugOutput(
        image: CGImage,
        observations: [LocatedText],
        title: LocatedText?,
        bodyObs: [LocatedText],
        rejectedObs: [LocatedText],
        clueRect: CGRect?,
        accepted: Bool,
        parchmentFallback: Bool = false,
        bodyAnchorFallback: Bool = false
    ) {
        guard let debugDir = AppSettings.debugSubfolder(named: "ClueScrollDebug") else { return }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let thumbW = 640, thumbH = 360

        if let thumb = makeThumb(from: image, width: thumbW, height: thumbH) {
            savePNG(thumb, to: debugDir.appendingPathComponent("frame.png"))
        }

        if let thumb = makeThumb(from: image, width: thumbW, height: thumbH) {
            let scaleX = CGFloat(thumbW) / imgW
            let scaleY = CGFloat(thumbH) / imgH

            var pixels = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
            guard let ctx = CGContext(
                data: &pixels, width: thumbW, height: thumbH,
                bitsPerComponent: 8, bytesPerRow: thumbW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: CGFloat(thumbW), height: CGFloat(thumbH)))

            func drawRect(_ r: CGRect, color: (CGFloat, CGFloat, CGFloat), lineWidth: CGFloat = 1) {
                let scaled = CGRect(
                    x: r.minX * scaleX, y: r.minY * scaleY,
                    width: r.width * scaleX, height: r.height * scaleY
                )
                ctx.setStrokeColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                ctx.setLineWidth(lineWidth)
                ctx.stroke(scaled)
            }

            for obs in rejectedObs {
                drawRect(obs.bounds, color: (1, 0, 0))
            }
            for obs in bodyObs {
                drawRect(obs.bounds, color: (0, 0.5, 1))
            }
            if let t = title {
                drawRect(t.bounds, color: (0, 1, 0), lineWidth: 2)
            }
            if let cr = clueRect {
                drawRect(cr, color: (1, 1, 0), lineWidth: 2)
            }

            if let overlayImg = ctx.makeImage() {
                savePNG(overlayImg, to: debugDir.appendingPathComponent("ocr_overlay.png"))
            }
        }

        if let cr = clueRect, let crop = image.cropping(to: cr.integral) {
            let name = accepted ? "detected_accepted.png" : "detected_rejected.png"
            savePNG(crop, to: debugDir.appendingPathComponent(name))
        }

        var report = [String]()
        report.append("OCR Clue Scroll Detection Report")
        report.append("=================================")
        report.append("Image size: \(image.width)x\(image.height)")
        report.append("Observations: \(observations.count)")
        report.append("")

        if let t = title {
            let normalized = t.text.uppercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "5", with: "S")
                .replacingOccurrences(of: "0", with: "O")
            let distances = Self.titleTargets.map { target -> String in
                let dist = LevenshteinDistance.unicodeScalars(normalized, target)
                let ratio = Double(dist) / Double(max(normalized.count, target.count))
                return "\(target): dist=\(dist) ratio=\(String(format: "%.2f", ratio))"
            }
            report.append("TITLE MATCH:")
            report.append("  '\(t.text)' conf=\(String(format: "%.2f", t.confidence)) "
                          + "bounds=\(t.bounds.integral)")
            report.append("  normalized: '\(normalized)'")
            for d in distances { report.append("  vs \(d)") }
        } else {
            report.append("TITLE MATCH: none")
        }
        report.append("")

        report.append("BODY (included in bounds):")
        if bodyObs.isEmpty {
            report.append("  (none)")
        } else {
            for obs in bodyObs {
                report.append("  '\(obs.text)' conf=\(String(format: "%.2f", obs.confidence)) "
                              + "bounds=\(obs.bounds.integral)")
            }
        }
        report.append("")

        report.append("REJECTED (outside scroll):")
        if rejectedObs.isEmpty {
            report.append("  (none)")
        } else {
            for obs in rejectedObs {
                report.append("  '\(obs.text)' conf=\(String(format: "%.2f", obs.confidence)) "
                              + "bounds=\(obs.bounds.integral)")
            }
        }
        report.append("")

        if bodyAnchorFallback {
            let union = bodyObs.isEmpty ? CGRect.zero
                : bodyObs.map(\.bounds).reduce(bodyObs[0].bounds) { $0.union($1) }
            let marginTop = union.width * bodyTopMarginRatio
            let marginH   = union.width * horizontalMarginRatio
            let marginBot = union.width * bottomMarginRatio

            report.append("BODY-TEXT ANCHOR FALLBACK (title OCR too garbled):")
            report.append("  Body union: \(union.integral)")
            if let cr = clueRect {
                report.append("  Final clueRect: \(cr.integral)")
            }
            report.append("")
            report.append("MARGIN RATIOS (body-anchor path):")
            report.append("  Horizontal: \(horizontalMarginRatio) (\(String(format: "%.0f", marginH)) px)")
            report.append("  Top (body→scroll-top): \(bodyTopMarginRatio) (\(String(format: "%.0f", marginTop)) px)")
            report.append("  Bottom: \(bottomMarginRatio) (\(String(format: "%.0f", marginBot)) px)")
            report.append("  Min height/width ratio: \(minHeightToWidthRatio)")
        } else if let t = title {
            if parchmentFallback {
                report.append("PARCHMENT EDGE SCAN FALLBACK (no body text):")
                report.append("  Title seed: \(t.bounds.integral)")
                if let cr = clueRect {
                    report.append("  Parchment rect: \(cr.integral)")
                    report.append("  Size: \(Int(cr.width))x\(Int(cr.height))")
                }
                report.append("  Brightness threshold: \(parchmentBrightnessMin)")
                report.append("  Line fraction threshold: \(parchmentLineFraction)")
                report.append("  Scan band width: \(parchmentScanBandWidth) px")
            } else {
                let allScrollObs = [t] + bodyObs
                let union = allScrollObs.map(\.bounds).reduce(allScrollObs[0].bounds) { $0.union($1) }
                let marginH = union.width * horizontalMarginRatio
                let marginTop = union.width * topMarginRatio
                let marginBot = union.width * bottomMarginRatio
                let minApplied = clueRect.map { $0.height > union.height + marginTop + marginBot + 1 } ?? false

                report.append("COMPUTED BOUNDS:")
                report.append("  Title top: \(Int(t.bounds.minY))   "
                              + "Union left: \(Int(union.minX))   Union right: \(Int(union.maxX))")
                report.append("  Body bottom: \(Int(union.maxY))  Min height applied: \(minApplied ? "yes" : "no")")
                report.append("  Raw union: \(union.integral)")
                if let cr = clueRect {
                    report.append("  Final clueRect: \(cr.integral)")
                }
                report.append("")

                report.append("MARGIN RATIOS:")
                report.append("  Horizontal: \(horizontalMarginRatio) of union width (\(String(format: "%.0f", marginH)) px)")
                report.append("  Top: \(topMarginRatio) of union width (\(String(format: "%.0f", marginTop)) px)")
                report.append("  Bottom: \(bottomMarginRatio) of union width (\(String(format: "%.0f", marginBot)) px)")
                report.append("  Min height/width ratio: \(minHeightToWidthRatio)")
                report.append("  Max body gap: \(maxBodyGapToTitleHeight)x title height "
                              + "(\(String(format: "%.0f", t.bounds.height * maxBodyGapToTitleHeight)) px)")
            }
        }

        let text = report.joined(separator: "\n")
        try? text.write(to: debugDir.appendingPathComponent("ocr_report.txt"),
                        atomically: true, encoding: .utf8)

        print("[ClueScrollDetector] Debug images saved to ClueScrollDebug/")
    }

    // MARK: - Image Helpers

    private func makeThumb(from image: CGImage, width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
