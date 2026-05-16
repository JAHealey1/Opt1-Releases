import CoreGraphics
import Foundation
import ImageIO
import Opt1Matching

// MARK: - ClueScrollPipeline

/// Stateless clue-scroll processing: crop → map match → OCR → fuzzy match.
/// Takes a pre-detected scroll rect in image-pixel coordinates and returns a
/// typed `Result` that the caller maps to the appropriate overlay. Also
/// exposes a stand-alone scan helper (`matchScanWithoutScroll`) for the case
/// where there's no parchment on screen — the player is mid-scan and the
/// OCR comes from the world map itself.
///
/// Splits clue-matching concerns out of `ClueOrchestrator` so the matching
/// pipeline is unit-testable without capture/banner/overlay mocks.
struct ClueScrollPipeline {

    enum Result {
        case cropFailed
        case mapClue(ClueSolution)
        case scan(region: String, scanRange: String, spots: [ClueSolution])
        case scanRegionUnknown(rawOCR: String)
        case solution(ClueSolution, confidence: Double)
        case ocrEmpty
        case corpusEmpty(rawOCR: String)
        case noMatch(rawOCR: String)
    }

    typealias StatusCallback = @MainActor (String) -> Void

    /// Matches a leading "Complete the action (<obj>): " header that Vision
    /// occasionally emits, so the stripped tail can go straight into the
    /// fuzzy matcher without that boilerplate dragging down the score.
    private static let actionPrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^complete\s+the\s+action[^:]*:\s*"#,
        options: .caseInsensitive
    )

    private let reader: ClueTextReader
    private let preprocessor: ImagePreprocessor
    private let matcher: FuzzyMatcher
    private let mapMatcher: MapClueMatcher

    init(
        reader: ClueTextReader = ClueTextReader(),
        preprocessor: ImagePreprocessor = ImagePreprocessor(),
        matcher: FuzzyMatcher = FuzzyMatcher(),
        mapMatcher: MapClueMatcher = MapClueMatcher()
    ) {
        self.reader = reader
        self.preprocessor = preprocessor
        self.matcher = matcher
        self.mapMatcher = mapMatcher
    }

    /// Process a detected clue-scroll region and return a typed match result.
    /// Never throws for business-logic failures (those become cases on
    /// `Result`); only OCR subsystem errors escape.
    func process(
        clueRect: CGRect,
        image: CGImage,
        clueProvider: any ClueProviding,
        status: StatusCallback? = nil
    ) async throws -> Result {
        guard let cropped = image.cropping(to: clueRect) else {
            return .cropFailed
        }

        let mapCandidates = clueProvider.clues.filter { $0.type == "map" }
        if !mapCandidates.isEmpty,
           let mapMatch = mapMatcher.matchMapClue(cropped, against: mapCandidates) {
            return .mapClue(mapMatch)
        }

        let processed = preprocessor.preprocess(cropped)
        // Dual-anchor read: the centred RS3 body font occasionally drops the
        // leading glyph at the canonical 0-px anchor due to sub-pixel
        // rasterisation; shifting by one space-width gives Vision a different
        // sampling grid. We keep whichever pass has the higher mean confidence.
        let rawObservations = try await reader.readBestCenteredObservations(
            from: processed,
            anchorOffsets: [0, ClueTextReader.centredAnchorSpaceWidth]
        )
        let observations = Self.stripActionPrefix(from: rawObservations)
        let joinedText = observations.joined(separator: " ")
        print("[Opt1] OCR \(observations.count) observations: '\(joinedText)'")

        if observations.isEmpty { return .ocrEmpty }
        if clueProvider.clues.isEmpty { return .corpusEmpty(rawOCR: joinedText) }

        await status?("Matching clue…")

        if Self.containsScanPhrase(observations) {
            if let scan = matchScan(observations: observations, clues: clueProvider.clues) {
                print("[Opt1] Scan clue via scroll detector — region: '\(scan.region)', \(scan.spots.count) spots")
                return .scan(region: scan.region, scanRange: scan.scanRange, spots: scan.spots)
            }
            return .scanRegionUnknown(rawOCR: observations.joined(separator: " "))
        }

        if let (solution, confidence) = matcher.bestMatch(forAny: observations, in: clueProvider.textCorpus) {
            print("[Opt1] Match: '\(solution.clue)' (\(Int(confidence * 100))%)")
            return .solution(solution, confidence: confidence)
        }

        return .noMatch(rawOCR: joinedText)
    }

    /// Looks for scan clues when there's no parchment — the player is
    /// already mid-scan and the OCR target is the small sticky scan UI.
    ///
    /// Uses `ParchmentLocator` to crop the image to the compact scroll area
    /// before running OCR, which is significantly more reliable than OCR on
    /// the full frame. Falls back to the full frame if no parchment is found.
    ///
    /// When debug mode is active, writes a crop PNG and structured OCR report
    /// to `ScanDetectionDebug/` for analysis.
    func matchScanWithoutScroll(
        in image: CGImage,
        clues: [ClueSolution]
    ) async -> (spots: [ClueSolution], region: String, scanRange: String)? {
        // ── Locate the compact scan parchment ──
        let locator = ParchmentLocator()
        let parchmentRect = locator.bestCompactScrollRect(in: image)
        let ocrTarget: CGImage
        if let rect = parchmentRect {
            // Expand by a small margin so tight parchment clips don't swallow
            // leading characters of the region name (e.g. "V" of "Varrock").
            let pad: CGFloat = 16
            let paddedRect = CGRect(
                x:      max(0,                      rect.minX - pad),
                y:      max(0,                      rect.minY - pad),
                width:  min(CGFloat(image.width),   rect.maxX + pad) - max(0, rect.minX - pad),
                height: min(CGFloat(image.height),  rect.maxY + pad) - max(0, rect.minY - pad)
            )
            ocrTarget = image.cropping(to: paddedRect) ?? image
        } else {
            ocrTarget = image
        }

        // ── OCR the target (located observations carry confidence scores for debug) ──
        guard let locatedObs = try? await reader.readLocatedObservations(from: ocrTarget) else {
            saveScanDebug(image: image, parchmentRect: parchmentRect, ocrTarget: ocrTarget,
                          locatedObs: [], observations: [], phraseFound: false,
                          match: nil, failReason: "readLocatedObservations threw")
            return nil
        }
        let rawStrings = locatedObs.map { $0.text }
        let observations = Self.clean(rawStrings)
        let joined = observations.joined(separator: " ").lowercased()

        let phraseFound = joined.contains("orb scan range")
            || joined.contains("scan range")
            || joined.contains("nothing scans")
            || joined.contains("orb glows as you scan")
            || joined.contains("scanning a different")

        guard phraseFound else {
            saveScanDebug(image: image, parchmentRect: parchmentRect, ocrTarget: ocrTarget,
                          locatedObs: locatedObs, observations: observations, phraseFound: false,
                          match: nil, failReason: "trigger phrase not found")
            return nil
        }

        print("[Opt1] Scan clue — trigger phrase found, matching region…")
        let scan = matchScan(observations: observations, clues: clues)

        saveScanDebug(image: image, parchmentRect: parchmentRect, ocrTarget: ocrTarget,
                      locatedObs: locatedObs, observations: observations, phraseFound: true,
                      match: scan, failReason: scan == nil ? "no region matched" : nil)

        guard let scan else {
            print("[Opt1] Scan — no region matched")
            return nil
        }
        print("[Opt1] Scan — region: '\(scan.region)', range: \(scan.scanRange) paces, \(scan.spots.count) spots")
        return scan
    }

    // MARK: - Scan Debug Output

    private func saveScanDebug(
        image: CGImage,
        parchmentRect: CGRect?,
        ocrTarget: CGImage,
        locatedObs: [LocatedText],
        observations: [String],
        phraseFound: Bool,
        match: (spots: [ClueSolution], region: String, scanRange: String)?,
        failReason: String?
    ) {
        guard let dir = AppSettings.debugSubfolder(named: "ScanDetectionDebug") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = Int(Date().timeIntervalSince1970)

        // 1. Parchment crop (or full frame if crop failed)
        let cropLabel = parchmentRect != nil ? "parchment_crop" : "full_frame_fallback"
        savePNG(ocrTarget, to: dir.appendingPathComponent("\(cropLabel)_\(ts).png"))

        // 2. Structured OCR report
        var lines: [String] = [
            "Scan Detection Debug — \(Date())",
            "Full image: \(image.width)×\(image.height)",
            "",
            "--- Parchment Detection ---",
            parchmentRect.map {
                "Found: YES  rect=(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))"
            } ?? "Found: NO  (OCR ran on full frame as fallback)",
            "",
            "--- Raw OCR Observations (\(locatedObs.count)) ---",
        ]
        for (i, obs) in locatedObs.enumerated() {
            lines.append(String(format: "  [%02d] conf=%.2f  \"%@\"", i, obs.confidence, obs.text))
        }
        lines += [
            "",
            "--- Cleaned Observations (\(observations.count)) ---",
        ]
        for (i, obs) in observations.enumerated() {
            lines.append("  [\(i)] \"\(obs)\"")
        }
        lines += [
            "",
            "--- Phrase Gate ---",
            "Trigger phrase found: \(phraseFound ? "YES" : "NO")",
            "",
            "--- Match Outcome ---",
        ]
        if let m = match {
            lines += [
                "Result: MATCHED",
                "Region: \(m.region)",
                "Scan range: \(m.scanRange.isEmpty ? "(not parsed)" : m.scanRange) paces",
                "Spots: \(m.spots.count)",
            ]
        } else {
            lines.append("Result: FAILED  reason=\(failReason ?? "unknown")")
        }

        try? lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("ocr_report_\(ts).txt"),
            atomically: true, encoding: .utf8
        )

        print("[ScanDetection] Debug saved to ScanDetectionDebug/\(cropLabel)_\(ts).* + ocr_report_\(ts).txt")
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Helpers (exposed for tests)

    /// Filters OCR noise: drops strings shorter than 3 chars and those whose
    /// letter ratio is below 40% (catches pure numbers and symbol garbage
    /// that Vision occasionally emits from UI chrome).
    static func clean(_ observations: [String]) -> [String] {
        observations.filter { s in
            guard s.count >= 3 else { return false }
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return Double(letters) / Double(s.count) >= 0.40
        }
    }

    /// True when any OCR line contains a scan-clue phrase. Narrower than
    /// `matchScanWithoutScroll`'s phrase set — this gates scan matching
    /// inside an already-detected parchment where the full text is visible.
    static func containsScanPhrase(_ observations: [String]) -> Bool {
        let joined = observations.joined(separator: " ").lowercased()
        return joined.contains("orb scan range") || joined.contains("scan range")
    }

    // MARK: - Private

    private static func stripActionPrefix(from observations: [String]) -> [String] {
        let stripped: [String] = observations.map { obs in
            guard let re = actionPrefixRegex else { return obs }
            let range = NSRange(obs.startIndex..., in: obs)
            guard let match = re.firstMatch(in: obs, range: range),
                  let tailRange = Range(match.range, in: obs).map({ $0.upperBound..<obs.endIndex })
            else { return obs }
            let tail = String(obs[tailRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? obs : tail
        }
        return clean(stripped)
    }

    private func matchScan(
        observations: [String],
        clues: [ClueSolution]
    ) -> (spots: [ClueSolution], region: String, scanRange: String)? {
        let spots = matcher.scanMatches(forAny: observations, in: clues)
        guard !spots.isEmpty else { return nil }
        let region = spots.first!.location ?? "Unknown region"

        // Prefer the in-game displayed range (which already reflects meerkats and
        // other active bonuses) over the known base range. However, if OCR returns
        // a value that doesn't match known or known+5 (meerkats), assume OCR is
        // wrong and fall back to the known value from the database.
        // The reminder line reads: "The scan range of this orb is X paces."
        // Vision splits this across two observations, so we join before matching.
        let ocrRange = Self.extractOCRScanRange(from: observations)
        let knownRange: Int? = spots.first?.scanRange

        let scanRange = Self.reconcileScanRange(ocrRange: ocrRange, knownRange: knownRange)

        return (spots, region, scanRange)
    }

    // MARK: - Scan range reconciliation

    /// Combines OCR with the database `scanRange` (base paces). The only in-game
    /// variant we model is meerkats (+5). Trusts OCR when it matches base or
    /// base+5; when it disagrees, prefers the catalogue value whose *decimal
    /// digits* are within one Levenshtein edit — e.g. OCR `25` vs true `35`
    /// (30+5) would otherwise fall back to bare `30` and drop the buff.
    static func reconcileScanRange(ocrRange: String?, knownRange: Int?) -> String {
        guard let known = knownRange else {
            return ocrRange ?? ""
        }

        let buffed = known + 5
        let candidates: [Int] = (known == buffed) ? [known] : [known, buffed]

        guard let ocr = ocrRange, let ocrInt = Int(ocr) else {
            return ocrRange ?? String(known)
        }

        if candidates.contains(ocrInt) {
            return ocr
        }

        let ocrDigits = String(ocrInt)
        var best: Int?
        var bestDistance = Int.max
        for c in candidates {
            let d = LevenshteinDistance.unicodeScalars(ocrDigits, String(c))
            if d < bestDistance {
                bestDistance = d
                best = c
            } else if d == bestDistance, let b = best {
                if abs(c - ocrInt) < abs(b - ocrInt) {
                    best = c
                }
            }
        }

        if bestDistance <= 1, let pick = best {
            if pick != ocrInt {
                print("[Opt1] Scan — OCR range \(ocrInt) reconciled to \(pick) (≤1 digit edit from base \(known) or +meerkats)")
            }
            return String(pick)
        }

        print("[Opt1] Scan — OCR range \(ocrInt) differs from known \(known); using known value")
        return String(known)
    }

    /// Extracts the effective scan range from OCR observations by matching
    /// "is X paces" across the joined observation text (the in-game reminder
    /// line reads "The scan range of this orb is X paces." and Vision often
    /// splits it across two observations).
    private static let ocrScanRangeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\bis\s+(\d+)\s+paces"#,
        options: .caseInsensitive
    )

    static func extractOCRScanRange(from observations: [String]) -> String? {
        let joined = observations.joined(separator: " ")
        let nsStr = joined as NSString
        guard let re = ocrScanRangeRegex,
              let match = re.firstMatch(in: joined, range: NSRange(location: 0, length: nsStr.length)),
              match.numberOfRanges > 1
        else { return nil }
        let digitRange = match.range(at: 1)
        guard digitRange.location != NSNotFound else { return nil }
        return nsStr.substring(with: digitRange)
    }
}
