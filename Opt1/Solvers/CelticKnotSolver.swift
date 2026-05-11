import CoreGraphics
import Foundation
import Opt1Core
import Opt1CelticKnot

// MARK: - Solution types

struct CelticKnotSolution {
    let rotations: [Int]
    let clockwiseRotationSigns: [Int]
    let arrowScreenPositions: [CelticKnotArrowPositions.ArrowPair]?
    let puzzleBoundsOnScreen: CGRect?
    var totalClicks: Int { rotations.map { abs($0) }.reduce(0, +) }

    init(rotations: [Int],
         clockwiseRotationSigns: [Int]? = nil,
         arrowScreenPositions: [CelticKnotArrowPositions.ArrowPair]? = nil,
         puzzleBoundsOnScreen: CGRect? = nil) {
        self.rotations = rotations
        self.clockwiseRotationSigns = clockwiseRotationSigns ?? Array(repeating: 1, count: rotations.count)
        self.arrowScreenPositions = arrowScreenPositions
        self.puzzleBoundsOnScreen = puzzleBoundsOnScreen
    }

    func physicalRotation(at index: Int) -> Int {
        guard rotations.indices.contains(index) else { return 0 }
        let sign = clockwiseRotationSigns.indices.contains(index) ? clockwiseRotationSigns[index] : 1
        return rotations[index] * sign
    }
}

struct CelticKnotArrowPositions {
    struct ArrowPair {
        let cwPosition: CGPoint
        let ccwPosition: CGPoint
    }

    /// Normalized arrow positions (0-1) within puzzleBounds for each track.
    static func normalized(for layoutType: CelticKnotLayoutType) -> [ArrowPair] {
        switch layoutType {
        case .sixSpot:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.05, y: 0.43), ccwPosition: CGPoint(x: 0.05, y: 0.58)),
                ArrowPair(cwPosition: CGPoint(x: 0.95, y: 0.58), ccwPosition: CGPoint(x: 0.95, y: 0.43)),
                ArrowPair(cwPosition: CGPoint(x: 0.42, y: 0.95), ccwPosition: CGPoint(x: 0.59, y: 0.95)),
            ]
        case .eightSpot:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.18, y: 0.21), ccwPosition: CGPoint(x: 0.11, y: 0.41)),
                ArrowPair(cwPosition: CGPoint(x: 0.39, y: 0.95), ccwPosition: CGPoint(x: 0.51, y: 0.95)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.58), ccwPosition: CGPoint(x: 0.87, y: 0.43)),
            ]
        case .eightSpotLinked:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.16, y: 0.78), ccwPosition: CGPoint(x: 0.42, y: 0.93)),
                ArrowPair(cwPosition: CGPoint(x: 0.37, y: 0.06), ccwPosition: CGPoint(x: 0.16, y: 0.30)),
                ArrowPair(cwPosition: CGPoint(x: 0.65, y: 0.93), ccwPosition: CGPoint(x: 0.80, y: 0.75)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.33), ccwPosition: CGPoint(x: 0.68, y: 0.18)),
            ]
        case .eightSpotWrap:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.70, y: 0.08), ccwPosition: CGPoint(x: 0.30, y: 0.08)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.60), ccwPosition: CGPoint(x: 0.85, y: 0.47)),
                ArrowPair(cwPosition: CGPoint(x: 0.15, y: 0.42), ccwPosition: CGPoint(x: 0.15, y: 0.60)),
            ]
        case .tenSpot:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.600, y: 0.139), ccwPosition: CGPoint(x: 0.407, y: 0.139)),
                ArrowPair(cwPosition: CGPoint(x: 0.841, y: 0.598), ccwPosition: CGPoint(x: 0.841, y: 0.326)),
                ArrowPair(cwPosition: CGPoint(x: 0.164, y: 0.598), ccwPosition: CGPoint(x: 0.164, y: 0.734)),
            ]
        case .tenSpotLinked:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.150, y: 0.550), ccwPosition: CGPoint(x: 0.164, y: 0.734)),
                ArrowPair(cwPosition: CGPoint(x: 0.500, y: 0.930), ccwPosition: CGPoint(x: 0.600, y: 0.930)),
                ArrowPair(cwPosition: CGPoint(x: 0.850, y: 0.400), ccwPosition: CGPoint(x: 0.860, y: 0.300)),
            ]
        case .fourteenSpot:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.38, y: 0.95), ccwPosition: CGPoint(x: 0.53, y: 0.95)),
                ArrowPair(cwPosition: CGPoint(x: 0.16, y: 0.58), ccwPosition: CGPoint(x: 0.16, y: 0.73)),
                ArrowPair(cwPosition: CGPoint(x: 0.38, y: 0.10), ccwPosition: CGPoint(x: 0.20, y: 0.39)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.39), ccwPosition: CGPoint(x: 0.85, y: 0.25)),
            ]
        case .eightSpotL:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.80, y: 0.30), ccwPosition: CGPoint(x: 0.72, y: 0.17)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.70), ccwPosition: CGPoint(x: 0.85, y: 0.50)),
                ArrowPair(cwPosition: CGPoint(x: 0.15, y: 0.40), ccwPosition: CGPoint(x: 0.15, y: 0.55)),
            ]
        case .twelveSpot:
            return [
                ArrowPair(cwPosition: CGPoint(x: 0.18, y: 0.550), ccwPosition: CGPoint(x: 0.18, y: 0.734)),
                ArrowPair(cwPosition: CGPoint(x: 0.85, y: 0.72), ccwPosition: CGPoint(x: 0.85, y: 0.550)),
                ArrowPair(cwPosition: CGPoint(x: 0.45, y: 0.95), ccwPosition: CGPoint(x: 0.58, y: 0.95)),
            ]
        default:
            return []
        }
    }

    /// Convert normalized positions to CG screen coordinates given puzzle bounds in image space.
    static func screenPositions(
        for layoutType: CelticKnotLayoutType,
        puzzleBoundsInImage: CGRect,
        imageSize: CGSize,
        windowFrame: CGRect
    ) -> [ArrowPair] {
        let norms = normalized(for: layoutType)
        guard !norms.isEmpty else { return [] }

        let scaleX = windowFrame.width / imageSize.width
        let scaleY = windowFrame.height / imageSize.height

        let puzzleOnScreen = CGRect(
            x: windowFrame.minX + puzzleBoundsInImage.minX * scaleX,
            y: windowFrame.minY + puzzleBoundsInImage.minY * scaleY,
            width: puzzleBoundsInImage.width * scaleX,
            height: puzzleBoundsInImage.height * scaleY
        )

        return norms.map { pair in
            ArrowPair(
                cwPosition: CGPoint(
                    x: puzzleOnScreen.minX + pair.cwPosition.x * puzzleOnScreen.width,
                    y: puzzleOnScreen.minY + pair.cwPosition.y * puzzleOnScreen.height
                ),
                ccwPosition: CGPoint(
                    x: puzzleOnScreen.minX + pair.ccwPosition.x * puzzleOnScreen.width,
                    y: puzzleOnScreen.minY + pair.ccwPosition.y * puzzleOnScreen.height
                )
            )
        }
    }
}

/// Structured info about WHY the solver gave up, used by the coordinator to
/// show the user actionable advice ("rotate the Gold track and try again")
/// instead of a generic "try again". Populated only when the solver fails to
/// find any rotation combo that satisfies every intersection.
struct CelticKnotSolveDiagnostics {
    /// Global rotation combo that satisfies the most intersections. Used to
    /// pick which (track, slot) pairs are the suspects.
    let bestRotations: [Int]
    /// Total intersections defined by the layout.
    let totalIntersections: Int
    /// Intersections satisfied under `bestRotations`.
    let satisfiedIntersections: Int
    /// Intersections that still don't match under `bestRotations` — these are
    /// the slots whose rune labels probably disagree with reality.
    let failingIntersections: [FailingIntersection]

    struct FailingIntersection {
        let trackA: Int
        let slotA: Int
        let runeA: String?
        let trackB: Int
        let slotB: Int
        let runeB: String?
    }

    /// Set of track indices participating in any failing intersection. The
    /// coordinator turns these into human-readable track names.
    var suspectTrackIndices: Set<Int> {
        var out: Set<Int> = []
        for f in failingIntersections {
            out.insert(f.trackA)
            out.insert(f.trackB)
        }
        return out
    }
}

enum CelticKnotSolveResult {
    case solved(CelticKnotSolution)
    case ambiguous(candidateCount: Int)
    case noSolution(diagnostics: CelticKnotSolveDiagnostics?)
}

enum CelticKnotRuneAmbiguity {
    private static let interchangeableFireBlood: Set<String> = ["fire", "blood"]
    private static let acceptedFireBloodMarginThreshold: Float = 0.08

    static func candidates(
        label: String?,
        detail: CelticKnotDetector.SlotClassification?,
        allowingFireBloodAmbiguity: Bool
    ) -> Set<String>? {
        guard allowingFireBloodAmbiguity else {
            return label.map { Set([$0]) }
        }

        let bestLabel = label ?? detail?.label
        guard let bestLabel else { return nil }
        guard interchangeableFireBlood.contains(bestLabel) else {
            return label.map { Set([$0]) }
        }

        if shouldExpandFireBlood(label: label, detail: detail) {
            return interchangeableFireBlood
        }
        return label.map { Set([$0]) }
    }

    static func expandedSlots(in state: CelticKnotState) -> [String] {
        var slots: [String] = []
        for (trackIdx, track) in state.layout.tracks.enumerated() {
            for slotIdx in track.indices {
                let label = labelAt(state.runeLabels, track: trackIdx, slot: slotIdx)
                let detail = detailAt(state.classDetails, track: trackIdx, slot: slotIdx)
                let strict = candidates(
                    label: label,
                    detail: detail,
                    allowingFireBloodAmbiguity: false
                )
                let expanded = candidates(
                    label: label,
                    detail: detail,
                    allowingFireBloodAmbiguity: true
                )
                guard expanded == interchangeableFireBlood, strict != expanded else { continue }
                let best = label ?? detail?.label ?? "?"
                let conf = detail?.confidence.map { String(format: "%.3f", $0) } ?? "?"
                let margin = detail?.margin.map { String(format: "%.3f", $0) } ?? "?"
                let reason = detail?.reason?.rawValue ?? "accepted"
                slots.append("t\(trackIdx)s\(slotIdx)=\(best) c=\(conf) m=\(margin) \(reason)")
            }
        }
        return slots
    }

    private static func shouldExpandFireBlood(
        label: String?,
        detail: CelticKnotDetector.SlotClassification?
    ) -> Bool {
        switch detail?.reason {
        case .belowConfidence, .belowMargin:
            return true
        default:
            break
        }

        guard label != nil, let margin = detail?.margin else { return false }
        return margin < acceptedFireBloodMarginThreshold
    }

    private static func labelAt(_ labels: [[String?]], track: Int, slot: Int) -> String? {
        guard track < labels.count, slot < labels[track].count else { return nil }
        return labels[track][slot]
    }

    private static func detailAt(
        _ details: [[CelticKnotDetector.SlotClassification]],
        track: Int,
        slot: Int
    ) -> CelticKnotDetector.SlotClassification? {
        guard track < details.count, slot < details[track].count else { return nil }
        return details[track][slot]
    }
}

// MARK: - Solver

extension CelticKnotDetector: PuzzleSolver {

    func solve(_ state: CelticKnotState) -> CelticKnotSolveResult {
        solve(state, allowingFireBloodAmbiguity: false)
    }

    func solveAllowingFireBloodAmbiguity(_ state: CelticKnotState) -> CelticKnotSolveResult {
        let expandedSlots = CelticKnotRuneAmbiguity.expandedSlots(in: state)
        if expandedSlots.isEmpty {
            print("[CelticKnotSolver] Fire/blood ambiguity retry found no eligible slots")
        } else {
            print("[CelticKnotSolver] Fire/blood ambiguity retry expanding: \(expandedSlots.joined(separator: ", "))")
        }
        return solve(state, allowingFireBloodAmbiguity: true)
    }

    func solvePartialFirstCapture(_ state: CelticKnotState) -> CelticKnotSolveResult {
        let layout = state.layout
        let labels = state.runeLabels
        let intersections = layout.intersections
        guard !intersections.isEmpty else { return .noSolution(diagnostics: nil) }

        let trackCount = layout.tracks.count
        guard trackCount >= 2, trackCount <= 4 else { return .noSolution(diagnostics: nil) }

        let trackSizes = layout.tracks.map(\.count)
        guard labels.count == trackCount,
              labels.enumerated().allSatisfy({ $0.element.count == trackSizes[$0.offset] })
        else { return .noSolution(diagnostics: nil) }

        func runeAt(track: Int, slot: Int, rotation: Int) -> String? {
            let size = trackSizes[track]
            let actualSlot = ((slot - rotation) % size + size) % size
            return labels[track][actualSlot]
        }

        func score(rotations: [Int]) -> (known: Int, matched: Int) {
            var known = 0
            var matched = 0
            for inter in intersections {
                guard let a = runeAt(track: inter.trackA, slot: inter.slotA, rotation: rotations[inter.trackA]),
                      let b = runeAt(track: inter.trackB, slot: inter.slotB, rotation: rotations[inter.trackB])
                else { continue }

                known += 1
                if a == b { matched += 1 }
            }
            return (known, matched)
        }

        func optimizeRotations(_ rots: [Int]) -> [Int] {
            rots.enumerated().map { index, rotation in
                let size = trackSizes[index]
                if rotation == 0 { return 0 }
                return rotation <= size / 2 ? rotation : rotation - size
            }
        }

        let minimumKnown = max(3, Int(ceil(Double(intersections.count) * 0.5)))
        var validCandidates: [[Int]] = []
        var bestKnown = 0
        var bestMatched = 0

        func evaluate(_ rotations: [Int]) {
            if rotations.allSatisfy({ $0 == 0 }) { return }

            let result = score(rotations: rotations)
            if result.known > bestKnown || (result.known == bestKnown && result.matched > bestMatched) {
                bestKnown = result.known
                bestMatched = result.matched
            }

            guard result.known >= minimumKnown, result.known == result.matched else { return }
            validCandidates.append(rotations)
        }

        switch trackCount {
        case 2:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    evaluate([r0, r1])
                }
            }
        case 3:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    for r2 in 0..<trackSizes[2] {
                        evaluate([r0, r1, r2])
                    }
                }
            }
        case 4:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    for r2 in 0..<trackSizes[2] {
                        for r3 in 0..<trackSizes[3] {
                            evaluate([r0, r1, r2, r3])
                        }
                    }
                }
            }
        default:
            return .noSolution(diagnostics: nil)
        }

        print("[CelticKnotSolver] First-pass partial solve: \(validCandidates.count) candidate(s), minKnown=\(minimumKnown), bestKnown=\(bestKnown), bestMatched=\(bestMatched)")

        let uniqueOptimized = Set(validCandidates.map { optimizeRotations($0).map(String.init).joined(separator: ",") })
        guard uniqueOptimized.count == 1,
              let raw = validCandidates.first
        else {
            return validCandidates.isEmpty
                ? .noSolution(diagnostics: nil)
                : .ambiguous(candidateCount: uniqueOptimized.count)
        }

        let optimized = optimizeRotations(raw)
        print("[CelticKnotSolver] First-pass partial solve accepted: raw \(raw) → opt \(optimized)")
        return .solved(CelticKnotSolution(rotations: optimized))
    }

    private func solve(
        _ state: CelticKnotState,
        allowingFireBloodAmbiguity: Bool
    ) -> CelticKnotSolveResult {
        let layout = state.layout
        let labels = state.runeLabels
        let details = state.classDetails
        let intersections = layout.intersections
        
        guard !intersections.isEmpty else {
            print("[CelticKnotSolver] No intersections defined — cannot solve")
            return .noSolution(diagnostics: nil)
        }
        
        let trackCount = layout.tracks.count
        guard trackCount >= 2, trackCount <= 4 else { return .noSolution(diagnostics: nil) }
        
        let trackSizes = layout.tracks.map(\.count)
        guard labels.count == trackCount else { return .noSolution(diagnostics: nil) }
        guard labels.enumerated().allSatisfy({ $0.element.count == trackSizes[$0.offset] }) else {
            return .noSolution(diagnostics: nil)
        }
        
        func runeAt(track: Int, slot: Int, rotation: Int) -> String? {
            let size = trackSizes[track]
            let actualSlot = ((slot - rotation) % size + size) % size
            return labels[track][actualSlot]
        }

        func detailAt(track: Int, slot: Int, rotation: Int) -> CelticKnotDetector.SlotClassification? {
            let size = trackSizes[track]
            let actualSlot = ((slot - rotation) % size + size) % size
            guard track < details.count, actualSlot < details[track].count else { return nil }
            return details[track][actualSlot]
        }

        func candidatesAt(track: Int, slot: Int, rotation: Int) -> Set<String>? {
            CelticKnotRuneAmbiguity.candidates(
                label: runeAt(track: track, slot: slot, rotation: rotation),
                detail: detailAt(track: track, slot: slot, rotation: rotation),
                allowingFireBloodAmbiguity: allowingFireBloodAmbiguity
            )
        }

        func candidatesMatch(_ lhs: Set<String>?, _ rhs: Set<String>?) -> Bool {
            guard let lhs, let rhs else { return false }
            return !lhs.isDisjoint(with: rhs)
        }
        
        func checkIntersections(rotations: [Int]) -> Bool {
            for inter in intersections {
                // Missing OCR on either side means we cannot verify this constraint —
                // reject the rotation rather than accept it on faith.
                let a = candidatesAt(track: inter.trackA, slot: inter.slotA, rotation: rotations[inter.trackA])
                let b = candidatesAt(track: inter.trackB, slot: inter.slotB, rotation: rotations[inter.trackB])
                if !candidatesMatch(a, b) { return false }
            }
            return true
        }

        func ambiguousMatchCount(rotations: [Int]) -> Int {
            var count = 0
            for inter in intersections {
                let labelA = runeAt(track: inter.trackA, slot: inter.slotA, rotation: rotations[inter.trackA])
                let labelB = runeAt(track: inter.trackB, slot: inter.slotB, rotation: rotations[inter.trackB])
                if labelA != nil, labelA == labelB { continue }
                let a = candidatesAt(track: inter.trackA, slot: inter.slotA, rotation: rotations[inter.trackA])
                let b = candidatesAt(track: inter.trackB, slot: inter.slotB, rotation: rotations[inter.trackB])
                if candidatesMatch(a, b) { count += 1 }
            }
            return count
        }
        
        var solutions: [[Int]] = []
        
        switch trackCount {
        case 2:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    let rots = [r0, r1]
                    if checkIntersections(rotations: rots) {
                        solutions.append(rots)
                    }
                }
            }
        case 3:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    let partialRots = [r0, r1, 0]
                    var valid = true
                    for inter in intersections where
                    (inter.trackA <= 1 && inter.trackB <= 1) {
                        let a = candidatesAt(track: inter.trackA, slot: inter.slotA, rotation: partialRots[inter.trackA])
                        let b = candidatesAt(track: inter.trackB, slot: inter.slotB, rotation: partialRots[inter.trackB])
                        if a != nil, b != nil, !candidatesMatch(a, b) { valid = false; break }
                    }
                    guard valid else { continue }
                    for r2 in 0..<trackSizes[2] {
                        let rots = [r0, r1, r2]
                        if checkIntersections(rotations: rots) {
                            solutions.append(rots)
                        }
                    }
                }
            }
        case 4:
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    for r2 in 0..<trackSizes[2] {
                        for r3 in 0..<trackSizes[3] {
                            let rots = [r0, r1, r2, r3]
                            if checkIntersections(rotations: rots) {
                                solutions.append(rots)
                            }
                        }
                    }
                }
            }
        default:
            return .noSolution(diagnostics: nil)
        }
        
        solutions.removeAll { $0.allSatisfy { $0 == 0 } }
        
        print("[CelticKnotSolver] Found \(solutions.count) solutions")
        
        if solutions.isEmpty {
            let diagnostics = computeConstraintDiagnostics(
                labels: labels,
                trackSizes: trackSizes,
                intersections: intersections,
                runeAt: runeAt
            )
            return .noSolution(diagnostics: diagnostics)
        }
        
        func optimizeRotations(_ rots: [Int]) -> [Int] {
            rots.enumerated().map { (i, r) -> Int in
                let size = trackSizes[i]
                if r == 0 { return 0 }
                return r <= size / 2 ? r : r - size
            }
        }

        // Match ClueTrainer's behaviour: always pick a canonical answer by
        // minimising sum |optimised offsets| across every candidate. When the
        // fire/blood fallback is active, prefer candidates that needed fewer
        // ambiguous matches before lexicographic tie-breaking.
        let scored: [(raw: [Int], optimized: [Int], cost: Int, ambiguousMatches: Int)] = solutions.map { rots in
            let opt = optimizeRotations(rots)
            return (rots, opt, opt.reduce(0) { $0 + abs($1) }, ambiguousMatchCount(rotations: rots))
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            if lhs.ambiguousMatches != rhs.ambiguousMatches {
                return lhs.ambiguousMatches < rhs.ambiguousMatches
            }
            return lhs.optimized.lexicographicallyPrecedes(rhs.optimized)
        }
        let best = ranked[0]
        let minRankTies = ranked.prefix {
            $0.cost == best.cost && $0.ambiguousMatches == best.ambiguousMatches
        }.count

        if solutions.count > 1 {
            let ambiguityNote = best.ambiguousMatches > 0
                ? ", ambiguousMatches=\(best.ambiguousMatches)"
                : ""
            print("[CelticKnotSolver] \(solutions.count) candidate(s); "
                  + "picked min-|sum-offset| = \(best.cost)\(ambiguityNote) "
                  + (minRankTies > 1 ? "(\(minRankTies)-way tie, broken lexicographically)" : ""))
            for entry in ranked.prefix(min(3, ranked.count)) {
                let suffix = entry.ambiguousMatches > 0 ? ", ambiguousMatches=\(entry.ambiguousMatches)" : ""
                print("[CelticKnotSolver]   raw \(entry.raw) → opt \(entry.optimized) (\(entry.cost) clicks\(suffix))")
            }
        } else {
            print("[CelticKnotSolver] Raw rotations: \(best.raw)  →  adjusted: \(best.optimized)")
        }

        return .solved(CelticKnotSolution(rotations: best.optimized))
    }
    
    /// Runs the same diagnostic prints as before (per-pair best-fit, global
    /// near-miss, ✓/✗ list) and additionally returns the structured global
    /// near-miss so the coordinator can build a "rotate the X track" hint.
    /// Returns nil when no intersections exist or fewer than two tracks are
    /// defined — i.e. when there's nothing meaningful to diagnose.
    private func computeConstraintDiagnostics(
        labels: [[String?]],
        trackSizes: [Int],
        intersections: [(trackA: Int, slotA: Int, trackB: Int, slotB: Int)],
        runeAt: (Int, Int, Int) -> String?
    ) -> CelticKnotSolveDiagnostics? {
        let tNames = ["Gold", "Dark", "Blue", "Grey"]
        func name(_ t: Int) -> String { t < tNames.count ? tNames[t] : "T\(t)" }

        struct TrackPairKey: Hashable { let a: Int; let b: Int }
        var pairMap: [TrackPairKey: [(trackA: Int, slotA: Int, trackB: Int, slotB: Int)]] = [:]
        for inter in intersections {
            let key = TrackPairKey(a: inter.trackA, b: inter.trackB)
            pairMap[key, default: []].append(inter)
        }

        for key in pairMap.keys.sorted(by: { $0.a < $1.a || ($0.a == $1.a && $0.b < $1.b) }) {
            guard let inters = pairMap[key] else { continue }
            let tA = key.a
            let tB = key.b

            var bestRA = 0
            var bestRB = 0
            var bestMatched = 0
            var bestFails: [(aRune: String, bRune: String, slotA: Int, slotB: Int)] = []
            for rA in 0..<trackSizes[tA] {
                for rB in 0..<trackSizes[tB] {
                    var matched = 0
                    var fails: [(aRune: String, bRune: String, slotA: Int, slotB: Int)] = []
                    for inter in inters {
                        let a = runeAt(inter.trackA, inter.slotA, rA) ?? "?"
                        let b = runeAt(inter.trackB, inter.slotB, rB) ?? "?"
                        if a == b { matched += 1 }
                        else { fails.append((a, b, inter.slotA, inter.slotB)) }
                    }
                    if matched > bestMatched {
                        bestMatched = matched
                        bestRA = rA
                        bestRB = rB
                        bestFails = fails
                    }
                }
            }
            print("[CelticKnotSolver] \(name(tA))×\(name(tB)) best: r\(tA)=\(bestRA),r\(tB)=\(bestRB) satisfies \(bestMatched)/\(inters.count)")
            for f in bestFails {
                print("[CelticKnotSolver]   FAIL: \(name(tA))[\(f.slotA)]=\"\(f.aRune)\" vs \(name(tB))[\(f.slotB)]=\"\(f.bRune)\"")
            }
        }

        print("[CelticKnotSolver] Near-miss scan (best rotation combo):")
        let trackCount = labels.count
        guard trackCount >= 2 else { return nil }
        var bestTotal = 0
        var bestRots = [Int](repeating: 0, count: trackCount)
        let totalInter = intersections.count

        func scanCombo(_ rots: [Int]) {
            var m = 0
            for inter in intersections {
                let a = runeAt(inter.trackA, inter.slotA, rots[inter.trackA])
                let b = runeAt(inter.trackB, inter.slotB, rots[inter.trackB])
                if let a, let b, a == b { m += 1 }
            }
            if m > bestTotal { bestTotal = m; bestRots = rots }
        }

        if trackCount == 2 {
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    scanCombo([r0, r1])
                }
            }
        } else if trackCount == 3 {
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    for r2 in 0..<trackSizes[2] {
                        scanCombo([r0, r1, r2])
                    }
                }
            }
        } else if trackCount == 4 {
            for r0 in 0..<trackSizes[0] {
                for r1 in 0..<trackSizes[1] {
                    for r2 in 0..<trackSizes[2] {
                        for r3 in 0..<trackSizes[3] {
                            scanCombo([r0, r1, r2, r3])
                        }
                    }
                }
            }
        }

        print("[CelticKnotSolver] Best combo: rotations=\(bestRots) satisfies \(bestTotal)/\(totalInter)")
        var failing: [CelticKnotSolveDiagnostics.FailingIntersection] = []
        for inter in intersections {
            let a = runeAt(inter.trackA, inter.slotA, bestRots[inter.trackA])
            let b = runeAt(inter.trackB, inter.slotB, bestRots[inter.trackB])
            let matched = (a != nil && b != nil && a == b)
            let ok = matched ? "✓" : "✗"
            print("[CelticKnotSolver]   \(ok) \(name(inter.trackA))[\(inter.slotA)]=\"\(a ?? "nil")\" vs \(name(inter.trackB))[\(inter.slotB)]=\"\(b ?? "nil")\"")
            if !matched {
                failing.append(.init(
                    trackA: inter.trackA, slotA: inter.slotA, runeA: a,
                    trackB: inter.trackB, slotB: inter.slotB, runeB: b
                ))
            }
        }

        return CelticKnotSolveDiagnostics(
            bestRotations: bestRots,
            totalIntersections: totalInter,
            satisfiedIntersections: bestTotal,
            failingIntersections: failing
        )
    }
}
