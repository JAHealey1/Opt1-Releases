import CoreGraphics
import CoreML
import Foundation
import Vision
import Opt1Solvers
import Opt1Detection

struct TileMatchResult {
    let tiles: [Int]
    let emptyIndex: Int
    let confidence: Float
    let ambiguityCount: Int
}

private struct AssignmentEvaluation {
    let result: TileMatchResult
    let blankTileSimilarity: Float
}

final class TileMatcher {
    private var embedModel: VNCoreMLModel?
    private let tileKnnArtifact: PuzzleTileKnnArtifact?
    /// Per-puzzle slot library: `puzzleKey -> slotIndex -> [embeddings]`.
    /// Each puzzle's embeddings may live in a different embedding-version
    /// space (see `embeddingVersionByPuzzle`).
    private let knnByPuzzleBySlot: [String: [Int: [[Float]]]]
    /// Per-puzzle ambiguity margin override derived at training time.
    private let ambiguityMarginByPuzzle: [String: Float]
    /// Per-puzzle embedding-version override. Keys are puzzleIds whose
    /// artifact entry specified a per-puzzle version different from the
    /// artifact-level default. Observed cells for these puzzles are encoded
    /// with this version so they share the same embedding space as the
    /// stored references.
    private let embeddingVersionByPuzzle: [String: Int]
    private let defaultAmbiguityMargin: Float
    private let tileKnnK: Int
    private let tileKnnEmbeddingVersion: Int

    init() {
        self.embedModel = Self.loadModel(named: "PuzzleTileEmbedding")
        let artifact = PuzzleTileKnnArtifact.loadFromBundle()
        self.tileKnnArtifact = artifact
        var bySlotMap: [String: [Int: [[Float]]]] = [:]
        var marginMap: [String: Float] = [:]
        var versionMap: [String: Int] = [:]
        if let artifact {
            for puzzle in artifact.puzzles {
                var byslot: [Int: [[Float]]] = [:]
                for slot in puzzle.slots {
                    byslot[slot.slot] = slot.embeddings
                }
                bySlotMap[puzzle.puzzleId] = byslot
                marginMap[puzzle.puzzleId] = puzzle.ambiguityMargin ?? artifact.defaultAmbiguityMargin
                if let perPuzzleVersion = puzzle.embeddingVersion,
                   perPuzzleVersion != artifact.embeddingVersion {
                    versionMap[puzzle.puzzleId] = perPuzzleVersion
                }
            }
        }
        self.knnByPuzzleBySlot = bySlotMap
        self.ambiguityMarginByPuzzle = marginMap
        self.embeddingVersionByPuzzle = versionMap
        self.defaultAmbiguityMargin = artifact?.defaultAmbiguityMargin ?? 0.02
        self.tileKnnK = max(1, artifact?.k ?? 3)
        self.tileKnnEmbeddingVersion = artifact?.embeddingVersion ?? PuzzleEmbeddingExtractor.version
    }

    func matchTiles(
        canonicalGrid: CGImage,
        reference: PuzzleDetectionPipeline.ReferenceEntry
    ) -> TileMatchResult? {
        let cellImages = extractCells(from: canonicalGrid)
        guard cellImages.count == 25 else { return nil }
        let refCellImages = extractCells(from: reference.image)
        guard refCellImages.count == 25 else { return nil }
        let slotKnn = (reference.hintAssisted ? nil : knnByPuzzleBySlot[reference.key])
        let useKnn = PuzzleDetectorRollout.tileKnnEnabled && slotKnn != nil
        var refEmbeddings = [[Float]?](repeating: nil, count: 25)
        var refPatches = [[Float]?](repeating: nil, count: 25)
        for idx in 0..<25 where idx != 24 {
            refEmbeddings[idx] = reference.tileEmbeddings[idx]
            refPatches[idx] = normalizedPatch(for: refCellImages[idx], side: 28)
        }

        let emptyCandidates = detectEmptyCandidates(cells: cellImages, hintAssisted: reference.hintAssisted)
        var best: TileMatchResult?
        var bestScore = -Float.greatestFiniteMagnitude
        var bestHintAmbiguity = Int.max
        var bestHintSolvable = false
        var bestHintValid = false
        var bestHintBlankSimilarity = Float.greatestFiniteMagnitude

        for emptyIdx in emptyCandidates {
            guard let evaluation = evaluateAssignment(
                emptyIdx: emptyIdx,
                cellImages: cellImages,
                refEmbeddings: refEmbeddings,
                refPatches: refPatches,
                hintAssisted: reference.hintAssisted,
                slotKnn: slotKnn,
                useKnn: useKnn,
                puzzleKey: reference.key
            ) else { continue }
            let candidate = evaluation.result
            let blankTileSimilarity = evaluation.blankTileSimilarity

            let solvable = SlidingPuzzleSolver.isSolvable(candidate.tiles)
            let valid = SlidingPuzzleSolver.isValidTileSet(candidate.tiles)
            if reference.hintAssisted {
                // Reject implausible blanks that still look strongly tile-like.
                if blankTileSimilarity > 0.90 {
                    print("[TileMatcher] Reject blank candidate idx=\(emptyIdx) sim=\(String(format: "%.3f", Double(blankTileSimilarity))) (too tile-like)")
                    continue
                }

                print(
                    "[TileMatcher] Hint candidate empty=\(emptyIdx) blankSim=\(String(format: "%.3f", Double(blankTileSimilarity))) " +
                    "amb=\(candidate.ambiguityCount) conf=\(String(format: "%.3f", Double(candidate.confidence))) " +
                    "solvable=\(solvable) valid=\(valid)"
                )

                // In hint-assisted mode, ambiguity reduction is the primary objective.
                let better =
                    (solvable && !bestHintSolvable) ||
                    (solvable == bestHintSolvable && valid && !bestHintValid) ||
                    (solvable == bestHintSolvable && valid == bestHintValid && blankTileSimilarity + 0.005 < bestHintBlankSimilarity) ||
                    (solvable == bestHintSolvable && valid == bestHintValid && abs(blankTileSimilarity - bestHintBlankSimilarity) <= 0.005 && candidate.ambiguityCount < bestHintAmbiguity) ||
                    (solvable == bestHintSolvable && valid == bestHintValid && candidate.ambiguityCount == bestHintAmbiguity && abs(blankTileSimilarity - bestHintBlankSimilarity) <= 0.005 && candidate.confidence > bestScore)
                if best == nil || better {
                    best = candidate
                    bestScore = candidate.confidence
                    bestHintAmbiguity = candidate.ambiguityCount
                    bestHintSolvable = solvable
                    bestHintValid = valid
                    bestHintBlankSimilarity = blankTileSimilarity
                }
            } else {
                var score = candidate.confidence - (Float(candidate.ambiguityCount) * 0.02)
                if valid { score += 0.25 }
                if solvable { score += 0.35 }
                if candidate.emptyIndex == 24 { score += 0.02 }
                // Prefer candidates whose "blank" looks least like any real tile.
                score -= (blankTileSimilarity * 0.45)
                if best == nil || score > bestScore {
                    best = candidate
                    bestScore = score
                }
            }
        }

        return best
    }

    private func evaluateAssignment(
        emptyIdx: Int,
        cellImages: [CGImage],
        refEmbeddings: [[Float]?],
        refPatches: [[Float]?],
        hintAssisted: Bool,
        slotKnn: [Int: [[Float]]]?,
        useKnn: Bool,
        puzzleKey: String
    ) -> AssignmentEvaluation? {
        var observedEmbeddings = [[Float]?](repeating: nil, count: 25)
        var observedPatches = [[Float]?](repeating: nil, count: 25)
        for idx in 0..<25 where idx != emptyIdx {
            observedEmbeddings[idx] = useKnn ? observedKnnEmbedding(for: cellImages[idx], puzzleKey: puzzleKey) : embedding(for: cellImages[idx])
            observedPatches[idx] = normalizedPatch(for: cellImages[idx], side: 28)
        }

        var rowToCell: [Int] = []
        var colToTile: [Int] = []
        for idx in 0..<25 where idx != emptyIdx { rowToCell.append(idx) }
        for idx in 0..<25 where idx != 24 { colToTile.append(idx) }

        var weights = Array(repeating: Array(repeating: Float(0), count: 24), count: 24)
        var ambiguityCount = 0
        let ambiguityMargin: Float = resolveAmbiguityMargin(
            hintAssisted: hintAssisted,
            useKnn: useKnn,
            puzzleKey: puzzleKey
        )
        let embeddingWeight: Float
        if useKnn {
            embeddingWeight = 0.90
        } else {
            embeddingWeight = hintAssisted ? 0.60 : 0.85
        }
        let patchWeight: Float = 1.0 - embeddingWeight

        for r in 0..<24 {
            let cellIdx = rowToCell[r]
            guard let obs = observedEmbeddings[cellIdx] else { return nil }
            let obsPatch = observedPatches[cellIdx]
            var rowScores: [Float] = []
            rowScores.reserveCapacity(24)
            for c in 0..<24 {
                let tileIdx = colToTile[c]
                let embScore: Float
                if useKnn, let lib = slotKnn?[tileIdx], !lib.isEmpty {
                    embScore = knnMeanCosine(query: obs, refs: lib, k: tileKnnK)
                } else if let ref = refEmbeddings[tileIdx] {
                    embScore = MathHelpers.cosine(obs, ref)
                } else {
                    return nil
                }
                let patchScore = (obsPatch != nil && refPatches[tileIdx] != nil) ? zncc(obsPatch!, refPatches[tileIdx]!) : 0
                let score = (embeddingWeight * embScore) + (patchWeight * patchScore)
                rowScores.append(score)
                weights[r][c] = score
            }
            let sorted = rowScores.sorted(by: >)
            if sorted.count >= 2, (sorted[0] - sorted[1]) < ambiguityMargin {
                ambiguityCount += 1
            }
        }

        guard let assignment = hungarianMaxAssignment(weights: weights), assignment.count == 24 else { return nil }

        var tileState = Array(repeating: 0, count: 25)
        tileState[emptyIdx] = 0
        var confidenceSum: Float = 0
        for r in 0..<24 {
            let cellIdx = rowToCell[r]
            let col = assignment[r]
            let tileIdx = colToTile[col]
            tileState[cellIdx] = tileIdx + 1
            confidenceSum += weights[r][col]
        }
        let confidence = confidenceSum / 24.0
        let blankTileSimilarity = estimateBlankTileSimilarity(
            blankCell: cellImages[emptyIdx],
            refEmbeddings: refEmbeddings,
            refPatches: refPatches,
            hintAssisted: hintAssisted,
            slotKnn: slotKnn,
            useKnn: useKnn,
            puzzleKey: puzzleKey
        )
        return AssignmentEvaluation(
            result: TileMatchResult(
                tiles: tileState,
                emptyIndex: emptyIdx,
                confidence: confidence,
                ambiguityCount: ambiguityCount
            ),
            blankTileSimilarity: blankTileSimilarity
        )
    }

    private func estimateBlankTileSimilarity(
        blankCell: CGImage,
        refEmbeddings: [[Float]?],
        refPatches: [[Float]?],
        hintAssisted: Bool,
        slotKnn: [Int: [[Float]]]?,
        useKnn: Bool,
        puzzleKey: String
    ) -> Float {
        let blankEmb: [Float]? = useKnn ? observedKnnEmbedding(for: blankCell, puzzleKey: puzzleKey) : embedding(for: blankCell)
        guard let blankEmb else { return 1.0 }
        let blankPatch = normalizedPatch(for: blankCell, side: 28)
        let embeddingWeight: Float = useKnn ? 0.90 : (hintAssisted ? 0.60 : 0.85)
        let patchWeight: Float = 1.0 - embeddingWeight
        var maxSimilarity: Float = -1
        for idx in 0..<25 where idx != 24 {
            let embScore: Float
            if useKnn, let lib = slotKnn?[idx], !lib.isEmpty {
                embScore = knnMeanCosine(query: blankEmb, refs: lib, k: tileKnnK)
            } else if let refEmb = refEmbeddings[idx] {
                embScore = MathHelpers.cosine(blankEmb, refEmb)
            } else {
                continue
            }
            let patchScore: Float
            if let blankPatch, let refPatch = refPatches[idx] {
                patchScore = zncc(blankPatch, refPatch)
            } else {
                patchScore = 0
            }
            let sim = (embeddingWeight * embScore) + (patchWeight * patchScore)
            if sim > maxSimilarity { maxSimilarity = sim }
        }
        return max(0, maxSimilarity)
    }

    func precomputeReferenceEmbeddings(refImage: CGImage) -> [[Float]?] {
        let viaExtractor = PuzzleEmbeddingExtractor.tileEmbeddings(for: refImage)
        if viaExtractor.contains(where: { $0 != nil }) {
            return viaExtractor
        }
        let refCells = extractCells(from: refImage)
        var out = [[Float]?](repeating: nil, count: 25)
        for i in 0..<min(25, refCells.count) { out[i] = embedding(for: refCells[i]) }
        return out
    }

    private func extractCells(from image: CGImage, insetFraction: CGFloat = 0.16) -> [CGImage] {
        var cells: [CGImage] = []
        cells.reserveCapacity(25)
        for r in 0..<5 {
            for c in 0..<5 {
                let rect = cellRect(
                    row: r,
                    col: c,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    insetFraction: insetFraction
                )
                if let sub = image.cropping(to: rect) {
                    cells.append(sub)
                }
            }
        }
        return cells
    }

    private func cellRect(
        row: Int,
        col: Int,
        imageWidth: Int,
        imageHeight: Int,
        insetFraction: CGFloat
    ) -> CGRect {
        let x0 = CGFloat((col * imageWidth) / 5)
        let y0 = CGFloat((row * imageHeight) / 5)
        let x1 = CGFloat(((col + 1) * imageWidth) / 5)
        let y1 = CGFloat(((row + 1) * imageHeight) / 5)
        let baseW = max(1, x1 - x0)
        let baseH = max(1, y1 - y0)

        let edgeCount = (row == 0 || row == 4 ? 1 : 0) + (col == 0 || col == 4 ? 1 : 0)
        let localInset: CGFloat
        switch edgeCount {
        case 2: localInset = insetFraction + 0.08
        case 1: localInset = insetFraction + 0.04
        default: localInset = insetFraction
        }
        var adjustedInset = localInset
        if row == 4 { adjustedInset += 0.04 }
        if col == 4 { adjustedInset += 0.04 }
        let padX = min(max(1, Int(baseW * adjustedInset)), max(1, Int((baseW - 1) / 2)))
        let padY = min(max(1, Int(baseH * adjustedInset)), max(1, Int((baseH - 1) / 2)))
        let ix0 = x0 + CGFloat(padX)
        let iy0 = y0 + CGFloat(padY)
        let ix1 = x1 - CGFloat(padX)
        let iy1 = y1 - CGFloat(padY)
        if ix1 > ix0, iy1 > iy0 {
            return CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)
        }
        return CGRect(x: x0, y: y0, width: baseW, height: baseH)
    }

    private func detectEmptyCandidates(cells: [CGImage], hintAssisted: Bool) -> [Int] {
        var pairs: [(idx: Int, std: Float)] = []
        pairs.reserveCapacity(cells.count)
        for (idx, cell) in cells.enumerated() {
            pairs.append((idx, brightnessStdDev(cell)))
        }
        pairs.sort { $0.std < $1.std }
        let maxCount = hintAssisted ? 15 : 8
        let top = pairs.prefix(max(1, min(maxCount, pairs.count))).map(\.idx)
        return top.isEmpty ? [24] : top
    }

    private func brightnessStdDev(_ image: CGImage) -> Float {
        let side = 20
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1.0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return 1.0 }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var sum: Float = 0
        var sum2: Float = 0
        for i in 0..<(side * side) {
            let y = (0.299 * Float(raw[i * 4]) + 0.587 * Float(raw[i * 4 + 1]) + 0.114 * Float(raw[i * 4 + 2])) / 255
            sum += y
            sum2 += y * y
        }
        let n = Float(side * side)
        let mean = sum / n
        return sqrt(max(0, (sum2 / n) - mean * mean))
    }

    private func embedding(for image: CGImage) -> [Float]? {
        if let modelEmbedding = embeddingFromModel(image: image) {
            return l2normalize(modelEmbedding)
        }
        if let crafted = PuzzleEmbeddingExtractor.embedding(for: image, side: 32) {
            return crafted
        }
        guard let rgb = renderCenterCropRGB(image, size: 32, insetFrac: 0.17) else { return nil }
        return l2normalize(rgb.map { Float($0) / 255.0 })
    }
    
    private func observedKnnEmbedding(for image: CGImage, puzzleKey: String) -> [Float]? {
        let version = embeddingVersionByPuzzle[puzzleKey] ?? tileKnnEmbeddingVersion
        switch version {
        case PuzzleEmbeddingExtractor.versionV4:
            return PuzzleEmbeddingExtractor.colorEmbeddingV4(for: image, side: 32)
        case PuzzleEmbeddingExtractor.versionV3:
            return PuzzleEmbeddingExtractor.colorEmbeddingV3(for: image, side: 32)
        case PuzzleEmbeddingExtractor.versionV2:
            return PuzzleEmbeddingExtractor.colorEmbedding(for: image, side: 32)
        default:
            return PuzzleEmbeddingExtractor.embedding(for: image, side: 32)
        }
    }

    /// Top-k mean cosine similarity of the query against a per-slot reference
    /// library.  Replaces the single-reference cosine used by the legacy
    /// single-image tile matcher with a noise-robust KNN score.
    ///
    /// Streams the cosines and keeps only a small ascending buffer of the top-k
    /// values (so `top[0]` is the current eviction candidate). For typical k=3
    /// and per-slot libraries in the tens to hundreds of references this runs
    /// in O(refs.count · k) with a k-sized allocation instead of the previous
    /// O(n log n) full sort over an n-sized array.
    private func knnMeanCosine(query: [Float], refs: [[Float]], k: Int) -> Float {
        guard !refs.isEmpty else { return 0 }
        let kClamped = max(1, min(k, refs.count))

        if kClamped == refs.count {
            var sum: Float = 0
            for ref in refs { sum += MathHelpers.cosine(query, ref) }
            return sum / Float(kClamped)
        }

        var top = [Float](repeating: -.infinity, count: kClamped)
        for ref in refs {
            let s = MathHelpers.cosine(query, ref)
            if s <= top[0] { continue }
            top[0] = s
            var i = 0
            while i + 1 < kClamped && top[i] > top[i + 1] {
                top.swapAt(i, i + 1)
                i += 1
            }
        }

        var sum: Float = 0
        for v in top { sum += v }
        return sum / Float(kClamped)
    }

    /// Resolves the ambiguity threshold for the current match. In KNN mode it
    /// reads the per-puzzle override from the trained artifact (falling back
    /// to the artifact default). In legacy mode it keeps the old
    /// hint-vs-standard hard-coded thresholds.
    private func resolveAmbiguityMargin(hintAssisted: Bool, useKnn: Bool, puzzleKey: String) -> Float {
        if useKnn {
            if let perPuzzle = ambiguityMarginByPuzzle[puzzleKey] {
                return perPuzzle
            }
            return defaultAmbiguityMargin
        }
        return hintAssisted ? 0.015 : 0.035
    }

    private func embeddingFromModel(image: CGImage) -> [Float]? {
        guard let embedModel else { return nil }
        let request = VNCoreMLRequest(model: embedModel)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image)
        do { try handler.perform([request]) } catch { return nil }
        guard let first = request.results?.first else { return nil }
        if let obs = first as? VNCoreMLFeatureValueObservation {
            return featureValueToArray(obs.featureValue)
        }
        return nil
    }

    private func featureValueToArray(_ value: MLFeatureValue) -> [Float]? {
        if value.type == .multiArray, let m = value.multiArrayValue {
            return multiArrayToFloatArray(m)
        }
        return nil
    }

    private func multiArrayToFloatArray(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { out[i] = ptr[i] }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { out[i] = Float(ptr[i]) }
        default:
            print("[TileMatcher] ⚠ Unsupported MLMultiArray dataType: \(array.dataType.rawValue)")
        }
        return out
    }

    private func renderCenterCropRGB(_ image: CGImage, size: Int, insetFrac: CGFloat) -> [UInt8]? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ix = (w * insetFrac).rounded(), iy = (h * insetFrac).rounded()
        let cropRect = CGRect(x: ix, y: iy, width: w - 2 * ix, height: h - 2 * iy)
        let source = image.cropping(to: cropRect).flatMap { Optional($0) } ?? image
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: size * size * 3)
        for i in 0..<(size * size) {
            out[i * 3] = raw[i * 4]
            out[i * 3 + 1] = raw[i * 4 + 1]
            out[i * 3 + 2] = raw[i * 4 + 2]
        }
        return out
    }

    private func l2normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        for v in vector { norm += v * v }
        norm = sqrt(norm)
        guard norm > 1e-6 else { return vector }
        return vector.map { $0 / norm }
    }

    private func normalizedPatch(for image: CGImage, side: Int) -> [Float]? {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let insetX = srcW * 0.18
        let insetY = srcH * 0.18
        let cropRect = CGRect(x: insetX, y: insetY, width: srcW - 2 * insetX, height: srcH - 2 * insetY).integral
        let source = image.cropping(to: cropRect) ?? image
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Center-biased crop to avoid border artifacts.
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: side * side)
        var mean: Float = 0
        for i in 0..<(side * side) {
            let y = (0.299 * Float(raw[i * 4]) + 0.587 * Float(raw[i * 4 + 1]) + 0.114 * Float(raw[i * 4 + 2])) / 255
            out[i] = y
            mean += y
        }
        mean /= Float(side * side)
        var norm: Float = 0
        for i in 0..<out.count {
            out[i] -= mean
            norm += out[i] * out[i]
        }
        norm = sqrt(norm)
        if norm > 1e-6 {
            for i in 0..<out.count { out[i] /= norm }
        }
        return out
    }

    private func zncc(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<n { dot += a[i] * b[i] }
        return dot / Float(n)
    }

    private func hungarianMaxAssignment(weights: [[Float]]) -> [Int]? {
        let n = weights.count
        guard n > 0 else { return [] }
        let m = weights[0].count
        guard n <= m, weights.allSatisfy({ $0.count == m }) else { return nil }
        let maxW = weights.flatMap { $0 }.max() ?? 0

        var cost = Array(repeating: Array(repeating: Float(0), count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                cost[i][j] = maxW - weights[i][j]
            }
        }

        var u = Array(repeating: Float(0), count: n + 1)
        var v = Array(repeating: Float(0), count: m + 1)
        var p = Array(repeating: 0, count: m + 1)
        var way = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            p[0] = i
            var minv = Array(repeating: Float.greatestFiniteMagnitude, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            var j0 = 0
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Float.greatestFiniteMagnitude
                var j1 = 0
                for j in 1...m where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...m {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignment = Array(repeating: -1, count: n)
        for j in 1...m where p[j] != 0 {
            assignment[p[j] - 1] = j - 1
        }
        return assignment
    }

    private static func loadModel(named name: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        return vn
    }
}
