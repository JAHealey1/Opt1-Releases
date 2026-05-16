import Foundation

// MARK: - ClueCorpus

/// Pre-computed clue corpus: the raw list plus normalised text and trigram
/// sets for trigram-gated Levenshtein matching. Built once per corpus (i.e.
/// once per `ClueDatabase.load()`) and passed into `FuzzyMatcher` so the
/// matcher itself stays stateless — this replaces an earlier static cache on
/// `FuzzyMatcher` that was keyed only on `clues.count` and could silently
/// serve one corpus's trigrams in response to another corpus's query.
public struct ClueCorpus {
    public struct Entry {
        public let clue: ClueSolution
        public let normalised: String
        public let trigrams: Set<String>
    }

    public let clues: [ClueSolution]
    public let entries: [Entry]
    public let anagrams: [Entry]
    public let coordinates: [Entry]

    public init(clues: [ClueSolution]) {
        self.clues = clues
        var entries = [Entry]()
        entries.reserveCapacity(clues.count)
        for clue in clues {
            let norm = clue.clue.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            entries.append(Entry(clue: clue, normalised: norm, trigrams: Self.makeTrigrams(norm)))
        }
        self.entries = entries
        self.anagrams = entries.filter { $0.clue.type == "anagram" }
        self.coordinates = entries.filter { $0.clue.type == "coordinate" }
    }

    public static func makeTrigrams(_ s: String) -> Set<String> {
        guard s.count >= 3 else { return [] }
        var result = Set<String>()
        let chars = Array(s)
        for i in 0...(chars.count - 3) {
            result.insert(String(chars[i..<(i + 3)]))
        }
        return result
    }
}

// MARK: - FuzzyMatcher

/// Fuzzy string matching for clue lookup using normalised Levenshtein edit distance.
/// Also applies a trigram pre-filter to skip obviously non-matching candidates.
public struct FuzzyMatcher {

    public init(confidenceThreshold: Double = 0.72) {
        self.confidenceThreshold = confidenceThreshold
    }

    /// Minimum similarity score [0, 1] to consider a match valid.
    public var confidenceThreshold: Double = 0.72

    // MARK: - Public API

    /// Returns ALL scan clue spots whose region best matches any observation.
    ///
    /// Scan texts share heavy boilerplate ("This scroll will work in … Orb scan
    /// range: … paces.") that dominates a naïve Levenshtein comparison and causes
    /// wrong-region matches.  We therefore strip the common prefix/suffix first and
    /// compare only the region-specific portion.
    public func scanMatches(forAny observations: [String], in clues: [ClueSolution]) -> [ClueSolution] {
        let scanClues = clues.filter { $0.type == "scan" }
        guard !scanClues.isEmpty else { return [] }

        var queries = observations
        for i in 0..<(observations.count - 1) {
            queries.append(observations[i] + " " + observations[i + 1])
        }
        if observations.count > 2 {
            queries.append(observations.joined(separator: " "))
        }

        let queryRegions: [String] = queries.compactMap { q in
            let r = normalise(scanRegionPart(q))
            return r.isEmpty ? nil : r
        }

        // Build the location→group dictionary once; all strategies below reuse it.
        let locationGroups = Dictionary(grouping: scanClues) { $0.location ?? "" }

        // Strategy 0: explicit small-scroll alias match.
        //
        // The compact scan parchment (small scroll) uses different wording than
        // the full large scroll clue text (e.g. "The crater in the Wilderness"
        // vs "This scroll will work in the crater of the Wilderness volcano.").
        // `scanRegionPart` can only strip the large-scroll boilerplate, so the
        // compact text falls through to fuzzy strategies with poor results.
        // Entries that carry `scanTextAliases` opt in to exact-containment
        // matching here before any fuzzy comparison runs.
        let aliasGroups: [String: [ClueSolution]] = {
            var map: [String: [ClueSolution]] = [:]
            for (location, group) in locationGroups {
                guard !location.isEmpty else { continue }
                for entry in group {
                    for alias in entry.scanTextAliases ?? [] {
                        let normAlias = normalise(alias)
                        guard !normAlias.isEmpty else { continue }
                        map[normAlias] = group
                    }
                }
            }
            return map
        }()
        for qr in queryRegions {
            for (normAlias, group) in aliasGroups {
                if qr.contains(normAlias) || normAlias.contains(qr) {
                    let loc = group.first?.location ?? "?"
                    print("[FuzzyMatcher] Scan alias match: '\(loc)' via alias '\(normAlias)' in '\(qr)'")
                    return group
                }
            }
        }

        // Strategy 1: location-name containment (both directions)
        //
        // Forward:  query contains the full location name  → e.g. query has "zanaris" in it
        // Reverse:  location name contains the query       → e.g. OCR captured only "Grand
        //           Exchange" or only "Varrock" but the full location is "Varrock and the
        //           Grand Exchange". Guard on query length ≥ 7 to avoid matching common words.
        for (location, group) in locationGroups {
            guard !location.isEmpty else { continue }
            let normLocation = normalise(location)
            for qr in queryRegions {
                if qr.contains(normLocation) {
                    print("[FuzzyMatcher] Scan location match: '\(location)' found in '\(qr)'")
                    return group
                }
                if qr.count >= 7, qr.contains(" "), normLocation.contains(qr) {
                    print("[FuzzyMatcher] Scan reverse-containment match: '\(location)' contains '\(qr)'")
                    return group
                }
            }
        }

        // Strategy 1b: fuzzy location-name match.
        //
        // Handles OCR errors in the region name itself (e.g. "Zanars" → "Zanaris").
        // Strategy 1 requires strict containment, which fails when a character is
        // dropped or corrupted. Strategy 2 compares against the full stripped clue
        // text (which may include extra words beyond the region name), so a short
        // single-word OCR fragment scores poorly even when it's only one edit away
        // from the correct location name.
        //
        // This step directly measures how similar each query region is to each
        // known location name, catching one-character OCR mistakes without
        // relying on the clue text length.
        var bestLocScore  = 0.0
        var bestLocGroup: [ClueSolution]?
        for (location, group) in locationGroups {
            guard !location.isEmpty else { continue }
            let normLocation = normalise(location)
            for qr in queryRegions {
                let score = levenshteinSimilarity(qr, normLocation)
                if score > bestLocScore { bestLocScore = score; bestLocGroup = group }
            }
        }
        // Threshold: allow up to 2 character edits regardless of name length, but
        // never drop below 0.65. For a 7-char name like "Zanaris" this gives ~0.70,
        // which accepts "Zanans" (2 edits, score ≈ 0.714) while still rejecting
        // unrelated short names that score well below 0.70.
        // For longer names the threshold rises (e.g. 0.79 at 10 chars, 0.87 at 15)
        // because there is more room to accumulate a high score legitimately.
        if let group = bestLocGroup {
            let refLen = Double(max(group.first?.location?.count ?? 0, 1))
            let dynamicThreshold = max(0.65, 1.0 - 2.1 / refLen)
            if bestLocScore > dynamicThreshold {
                let name = group.first?.location ?? "?"
                print("[FuzzyMatcher] Scan location fuzzy match: '\(name)' score=\(String(format: "%.2f", bestLocScore)) threshold=\(String(format: "%.2f", dynamicThreshold))")
                return group
            }
        }

        // Strategy 2: region-text Levenshtein similarity (fallback)
        let uniqueTexts = Array(Set(scanClues.compactMap { $0.clue }))
        var bestText: String?
        var bestScore = 0.0
        for text in uniqueTexts {
            let normText = normalise(scanRegionPart(text))
            guard !normText.isEmpty else { continue }
            for qr in queryRegions {
                let score = levenshteinSimilarity(qr, normText)
                if score > bestScore { bestScore = score; bestText = text }
            }
        }
        guard let text = bestText, bestScore > 0.55 else { return [] }
        print("[FuzzyMatcher] Scan text match '\(text.prefix(60))' score=\(String(format: "%.2f", bestScore))")
        return scanClues.filter { $0.clue == text }
    }

    private func scanRegionPart(_ text: String) -> String {
        var s = text.lowercased()
        let prefixes = [
            "this scroll will work within the walls of ",
            "this scroll will work on the faraway island of ",
            "this scroll will work in the ",
            "this scroll will work in ",
            "this scroll will work ",
        ]
        for prefix in prefixes {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        if let rangeMark = s.range(of: "orb scan range") {
            s = String(s[..<rangeMark.lowerBound])
        }
        let result = s.trimmingCharacters(in: .whitespacesAndNewlines)
                      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                      .trimmingCharacters(in: .whitespaces)
        return result == text.lowercased() ? text : result
    }

    /// Tries every observation as a separate query and returns the overall best match.
    /// Individual observations are tried first (fast path), then sliding windows
    /// and a full-join are tried as fallbacks for clue text that spans multiple OCR lines.
    public func bestMatch(forAny observations: [String], in corpus: ClueCorpus) -> (clue: ClueSolution, confidence: Double)? {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Filter to prose-like observations for window/join queries.
        // Excludes garbled title text, health numbers, etc.
        let proseObs = observations.filter { isProse($0) }
        let maxObsLen = proseObs.map(\.count).max() ?? 0

        // Length-coverage penalty: a short clue (e.g. "Prifddinas") can score
        // 0.91 against a short OCR fragment even when the scroll text is actually
        // a long emote clue that merely mentions the place name. Penalise any
        // candidate whose clue text is much shorter than the longest observation;
        // used only for comparison/selection, not for the returned confidence value.
        func effectiveConf(_ r: (clue: ClueSolution, confidence: Double)) -> Double {
            let ratio = Double(r.clue.clue.count) / Double(max(maxObsLen, 1))
            guard ratio < 0.5 else { return r.confidence }
            return r.confidence * (0.6 + 0.4 * ratio)
        }

        // Try each observation individually — fast and usually sufficient.
        let singleBest = proseObs
            .compactMap { bestMatchUnclamped(for: $0, corpus: corpus) }
            .max(by: { effectiveConf($0) < effectiveConf($1) })

        if let result = singleBest, effectiveConf(result) >= 0.90 {
            logTiming(startTime, label: "individual (high-conf early exit)")
            return result
        }

        // Full join of all prose observations — catches clues whose text spans
        // many OCR lines (emote clues, long cryptics).
        var joinBest: (clue: ClueSolution, confidence: Double)?
        if proseObs.count >= 2 {
            let fullJoin = proseObs.joined(separator: " ")
            joinBest = bestMatchUnclamped(for: fullJoin, corpus: corpus)
            if let result = joinBest, effectiveConf(result) >= 0.90 {
                logTiming(startTime, label: "full-join (high-conf early exit)")
                return result
            }
        }

        // Sliding windows of 2-4 consecutive prose observations.
        var windowBest: (clue: ClueSolution, confidence: Double)?
        let maxWindow = min(4, proseObs.count)
        if maxWindow >= 2 {
            outer: for windowSize in 2...maxWindow {
                for start in 0...(proseObs.count - windowSize) {
                    let joined = proseObs[start ..< (start + windowSize)].joined(separator: " ")
                    if let result = bestMatchUnclamped(for: joined, corpus: corpus) {
                        if windowBest == nil || effectiveConf(result) > effectiveConf(windowBest!) {
                            windowBest = result
                        }
                        if effectiveConf(result) >= 0.90 { break outer }
                    }
                }
            }
        }

        let best = [singleBest, joinBest, windowBest]
            .compactMap { $0 }
            .max(by: { effectiveConf($0) < effectiveConf($1) })

        if best == nil {
            print("[FuzzyMatcher] No match after individual + join + window search (threshold \(Int(confidenceThreshold * 100))%)")
        }
        logTiming(startTime, label: "bestMatch total")
        return best
    }

    private func logTiming(_ start: CFAbsoluteTime, label: String) {
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[FuzzyMatcher] \(label): \(String(format: "%.0f", ms)) ms")
    }

    private func isProse(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return Double(letters) / Double(max(s.count, 1)) >= 0.55
    }

    // MARK: - Core Matching (uses corpus)

    private func bestMatchUnclamped(for query: String, corpus: ClueCorpus) -> (clue: ClueSolution, confidence: Double)? {
        guard !query.isEmpty, !corpus.entries.isEmpty else { return nil }
        let normQuery = normalise(query)

        // ── Anagram letter-sort matching ──
        let anagramPrefix = "this anagram reveals who to speak to next:"
        if normQuery.contains(anagramPrefix), !corpus.anagrams.isEmpty {
            // Pre-compute corpus anagram sorted letters once.
            let corpusAnagramLetters: [(entry: ClueCorpus.Entry, letters: String)] = corpus.anagrams.compactMap { entry in
                let letters = sortedLetters(after: anagramPrefix, in: entry.normalised)
                return letters.isEmpty ? nil : (entry, letters)
            }

            // Build a list of candidate anagram texts to try.
            // Full suffix is tried first because some clues include the entire
            // post-colon phrase as the anagram key (e.g. "HE DO POSE. IT IS CULTRRL, MK?").
            // A perfect letter-sort hit on the full suffix exits immediately.
            // Shorter trailing windows follow as fallbacks for clues where OCR
            // noise or extra lines appear after the actual answer word(s).
            let fullSuffix = String(normQuery[normQuery.range(of: anagramPrefix)!.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let suffixWords = fullSuffix.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // If there are no answer words at all, this observation is only the
            // prefix line with no answer — we cannot identify which anagram it is,
            // so bail out rather than falling through to standard Levenshtein
            // (which would spuriously match the shortest anagram in the corpus).
            guard !suffixWords.isEmpty else { return nil }

            var anagramCandidates: [String] = []
            // Full suffix first — exact match for extended clues
            anagramCandidates.append(fullSuffix)
            // Last 1…5 words as fallback (shorter = tighter signal for simple clues)
            for n in 1...min(5, suffixWords.count) {
                let candidate = suffixWords.suffix(n).joined(separator: " ")
                if candidate != fullSuffix {
                    anagramCandidates.append(candidate)
                }
            }

            var bestClue: ClueSolution?
            var bestScore = 0.0
            var bestCandidateUsed = ""

            for candidate in anagramCandidates {
                let queryLetters = anagramLettersSorted(candidate)
                guard !queryLetters.isEmpty else { continue }
                for (entry, clueLetters) in corpusAnagramLetters {
                    if queryLetters == clueLetters {
                        print("[FuzzyMatcher] Anagram letter match '\(entry.clue.clue.prefix(60))' (sorted: '\(queryLetters)' from '\(candidate)')")
                        var result = entry.clue; result.confidence = 1.0
                        return (result, 1.0)
                    }
                    let score = levenshteinSimilarity(queryLetters, clueLetters)
                    if score > bestScore { bestScore = score; bestClue = entry.clue; bestCandidateUsed = candidate }
                }
                // Early exit: if a short suffix already gives a strong match, don't
                // keep trying longer (noisier) candidates which might demote it.
                if bestScore >= 0.80 { break }
            }

            if let match = bestClue, bestScore >= 0.80 {
                print("[FuzzyMatcher] Anagram partial letter match '\(match.clue.prefix(60))' score=\(String(format: "%.2f", bestScore)) from '\(bestCandidateUsed)'")
                var result = match; result.confidence = bestScore
                return (result, bestScore)
            }
            // Anagram letter-sort didn't produce a strong match —
            // fall through to standard Levenshtein so garbled OCR
            // still has a chance via whole-text similarity.
            print("[FuzzyMatcher] Anagram letter-sort inconclusive (best=\(String(format: "%.2f", bestScore))) — trying standard match")
        }

        // ── Coordinate clue matching ──
        if let queryCoord = parseCoordinate(from: normQuery) {
            guard !corpus.coordinates.isEmpty else { return nil }
            var bestClue: ClueSolution?
            var bestScore = 0.0
            for entry in corpus.coordinates {
                guard let clueCoord = parseCoordinate(from: entry.normalised) else { continue }
                let score = coordinateSimilarity(queryCoord, clueCoord)
                if score > bestScore { bestScore = score; bestClue = entry.clue }
            }
            if let match = bestClue, bestScore >= 0.80 {
                print("[FuzzyMatcher] Coord match '\(match.clue.prefix(60))' score=\(String(format: "%.2f", bestScore))")
                var result = match; result.confidence = bestScore
                return (result, bestScore)
            }
            return nil
        }

        // ── Standard Levenshtein matching (with trigram pre-filter) ──
        let queryTrigrams = ClueCorpus.makeTrigrams(normQuery)
        var bestClue: ClueSolution?
        var bestScore = 0.0
        for entry in corpus.entries {
            guard !queryTrigrams.isEmpty, !entry.trigrams.isEmpty else { continue }
            var intersectionCount = 0
            for tg in queryTrigrams { if entry.trigrams.contains(tg) { intersectionCount += 1 } }
            let trigramScore = Double(intersectionCount * 2) / Double(queryTrigrams.count + entry.trigrams.count)
            guard trigramScore > 0.15 else { continue }
            let score = levenshteinSimilarity(normQuery, entry.normalised)
            if score > bestScore {
                bestScore = score; bestClue = entry.clue
                if bestScore >= 0.99 { break }
            }
        }
        if let match = bestClue, bestScore >= confidenceThreshold {
            print("[FuzzyMatcher] Match '\(match.clue.prefix(60))' score=\(String(format: "%.2f", bestScore))")
            var result = match; result.confidence = bestScore
            return (result, bestScore)
        }

        // ── Suffix window matching ──
        let queryLen = normQuery.count
        if queryLen >= 30 {
            var bestSuffixClue: ClueSolution?
            var bestSuffixScore = 0.0
            for entry in corpus.entries {
                guard entry.normalised.count > queryLen + 8 else { continue }
                // Trigram pre-filter — same gate as the standard path above.
                guard !queryTrigrams.isEmpty, !entry.trigrams.isEmpty else { continue }
                var intersectionCount = 0
                for tg in queryTrigrams { if entry.trigrams.contains(tg) { intersectionCount += 1 } }
                let trigramScore = Double(intersectionCount * 2) / Double(queryTrigrams.count + entry.trigrams.count)
                guard trigramScore > 0.10 else { continue }
                let slack = 20
                let windowSize = min(entry.normalised.count, queryLen + slack)
                let startOffset = entry.normalised.count - windowSize
                let startIdx = entry.normalised.index(entry.normalised.startIndex, offsetBy: startOffset)
                let window = String(entry.normalised[startIdx...])
                let score = levenshteinSimilarity(normQuery, window)
                if score > bestSuffixScore { bestSuffixScore = score; bestSuffixClue = entry.clue }
                if bestSuffixScore >= 0.90 { break }
            }
            if let match = bestSuffixClue, bestSuffixScore >= 0.82 {
                print("[FuzzyMatcher] Suffix match '\(match.clue.prefix(60))' score=\(String(format: "%.2f", bestSuffixScore))")
                var result = match; result.confidence = bestSuffixScore
                return (result, bestSuffixScore)
            }
        }

        return nil
    }

    // MARK: - Coordinate Helpers

    private struct CoordTokens {
        let latDeg: Int; let latMin: Int; let latDir: String
        let lonDeg: Int; let lonMin: Int; let lonDir: String
        var key: String { "\(latDeg)°\(latMin)'\(latDir.first!.uppercased()) \(lonDeg)°\(lonMin)'\(lonDir.first!.uppercased())" }
    }

    private static let coordRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\d{1,3})\s+degrees?\s+(\d{1,2})\s+minutes?\s+(north|south)[,\s]+(\d{1,3})\s+degrees?\s+(\d{1,2})\s+minutes?\s+(east|west)"#,
        options: .caseInsensitive
    )

    private func parseCoordinate(from text: String) -> CoordTokens? {
        guard let regex = Self.coordRegex,
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let r3 = Range(m.range(at: 3), in: text),
              let r4 = Range(m.range(at: 4), in: text),
              let r5 = Range(m.range(at: 5), in: text),
              let r6 = Range(m.range(at: 6), in: text),
              let latDeg = Int(text[r1]),
              let latMin = Int(text[r2]),
              let lonDeg = Int(text[r4]),
              let lonMin = Int(text[r5]) else { return nil }
        return CoordTokens(latDeg: latDeg, latMin: latMin, latDir: String(text[r3]).lowercased(),
                           lonDeg: lonDeg, lonMin: lonMin, lonDir: String(text[r6]).lowercased())
    }

    private func coordinateSimilarity(_ a: CoordTokens, _ b: CoordTokens) -> Double {
        guard a.latDir == b.latDir, a.lonDir == b.lonDir else { return 0 }
        let aKey = String(format: "%02d%02d%02d%02d", a.latDeg, a.latMin, a.lonDeg, a.lonMin)
        let bKey = String(format: "%02d%02d%02d%02d", b.latDeg, b.latMin, b.lonDeg, b.lonMin)
        return levenshteinSimilarity(aKey, bKey)
    }

    /// Returns the sorted letters of the text found after `prefix` in `text`.
    /// Used for corpus entries where the prefix is always present.
    private func sortedLetters(after prefix: String, in text: String) -> String {
        guard let range = text.range(of: prefix) else { return "" }
        let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return anagramLettersSorted(tail)
    }

    /// Sorts and returns only the letters of `text` after applying common OCR
    /// digit-to-letter substitutions. Used to produce a canonical anagram key
    /// from an already-extracted anagram candidate string.
    private func anagramLettersSorted(_ text: String) -> String {
        var s = text
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
        let ocrSubs: [(Character, Character)] = [
            ("5", "s"), ("0", "o"), ("1", "i"), ("8", "b"),
        ]
        for (digit, letter) in ocrSubs {
            s = s.map { $0 == digit ? letter : $0 }.map(String.init).joined()
        }
        return String(s.filter { $0.isLetter }.sorted())
    }

    // MARK: - Normalisation

    private func normalise(_ s: String) -> String {
        // Replace apostrophes (straight and curly) with spaces before splitting
        // so OCR observations that drop apostrophes ("Mos Le Harmless") still
        // match corpus entries that contain them ("Mos Le'Harmless").
        s.folding(options: .diacriticInsensitive, locale: .current)
         .lowercased()
         .replacingOccurrences(of: "'",       with: " ")
         .replacingOccurrences(of: "\u{2019}", with: " ")
         .components(separatedBy: .whitespacesAndNewlines)
         .filter { !$0.isEmpty }
         .joined(separator: " ")
    }

    // MARK: - Levenshtein Similarity

    func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        // Use Unicode scalars, not UTF-8 bytes. Multi-byte OCR substitutions such
        // as dotless-ı (U+0131, 2 bytes) for plain i (1 byte) would be counted as
        // distance 2 on bytes but are correctly counted as distance 1 on scalars,
        // preventing artificially low scores for non-ASCII OCR artefacts.
        let aScalars = Array(a.unicodeScalars)
        let bScalars = Array(b.unicodeScalars)
        let maxLen = max(aScalars.count, bScalars.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - Double(LevenshteinDistance.unicodeScalars(aScalars, bScalars)) / Double(maxLen)
    }
}
