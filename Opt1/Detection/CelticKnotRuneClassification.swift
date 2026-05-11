import CoreGraphics
import Foundation
import Opt1CelticKnot
import Opt1Detection

// MARK: - Rune classification

extension CelticKnotDetector {

    typealias SlotClassification = CelticKnotSlotClassification
    typealias SlotNilReason = CelticKnotSlotNilReason

    /// Controls whether intersection slots that are expected to be hidden in
    /// the assumed state get skipped (the historical optimisation) or
    /// classified anyway (needed by the two-hypothesis solver, which doesn't
    /// know which capture is normal vs inverted up-front).
    enum IntersectionMode {
        /// Skip slots whose `isOnTop` flag says they're hidden in this state.
        case skipHidden(isInverted: Bool)
        /// Classify every slot, even hidden ones. The caller decides per
        /// hypothesis which classifications to trust.
        case classifyAll
    }

    func extractRuneCrops(
        from image: CGImage,
        puzzleBounds: CGRect,
        layout: CelticKnotLayout,
        runeArea: CGRect? = nil
    ) -> [(trackIndex: Int, slotIndex: Int, position: CGPoint, image: CGImage)] {
        var crops: [(Int, Int, CGPoint, CGImage)] = []
        let diam = layout.estimatedRuneDiameter
        let cropSide = min(puzzleBounds.width, puzzleBounds.height) * diam
        let halfW = cropSide / 2
        let halfH = cropSide / 2

        for track in layout.tracks {
            for slot in track {
                let center = CGPoint(
                    x: puzzleBounds.minX + slot.x * puzzleBounds.width,
                    y: puzzleBounds.minY + slot.y * puzzleBounds.height
                )
                let rect = CGRect(
                    x: center.x - halfW,
                    y: center.y - halfH,
                    width: cropSide,
                    height: cropSide
                )

                let clipped = rect.intersection(
                    CGRect(x: 0, y: 0,
                           width: CGFloat(image.width),
                           height: CGFloat(image.height))
                )
                guard clipped.width > 4, clipped.height > 4,
                      let crop = image.cropping(to: clipped) else { continue }

                crops.append((slot.trackIndex, slot.slotIndex, center, crop))
            }
        }

        print("[CelticKnot] Extracted \(crops.count) rune crops from \(layout.type)")
        return crops
    }

    func classifyAllRunes(
        in image: CGImage,
        puzzleBounds: CGRect,
        layout: CelticKnotLayout,
        artifact: CelticKnotRuneModelArtifact,
        intersectionMode: IntersectionMode = .skipHidden(isInverted: false),
        runeArea: CGRect? = nil
    ) -> (labels: [[String?]], details: [[SlotClassification]]) {
        var labels = layout.tracks.map { track in
            [String?](repeating: nil, count: track.count)
        }
        var details = layout.tracks.map { track in
            [SlotClassification](repeating: SlotClassification(label: nil, confidence: nil, margin: nil, reason: .noCrop), count: track.count)
        }

        let crops = extractRuneCrops(
            from: image,
            puzzleBounds: puzzleBounds,
            layout: layout,
            runeArea: runeArea
        )
        for (trackIdx, slotIdx, _, crop) in crops {
            let slot = layout.tracks[trackIdx][slotIdx]
            if slot.intersectionPartner != nil,
               case .skipHidden(let isInverted) = intersectionMode {
                let visibleInThisState = isInverted ? !slot.isOnTop : slot.isOnTop
                guard visibleInThisState else {
                    details[trackIdx][slotIdx] = SlotClassification(label: nil, confidence: nil, margin: nil, reason: .hidden)
                    continue
                }
            }
            if let result = classifyRuneDetailed(
                crop,
                artifact: artifact,
                layoutType: layout.type,
                trackIdx: trackIdx,
                slotIdx: slotIdx
            ) {
                labels[trackIdx][slotIdx] = result.accepted ? result.label : nil
                details[trackIdx][slotIdx] = SlotClassification(
                    label: result.label,
                    confidence: result.confidence,
                    margin: result.margin,
                    reason: result.accepted ? nil : result.rejectReason
                )
            } else {
                details[trackIdx][slotIdx] = SlotClassification(label: nil, confidence: nil, margin: nil, reason: .embeddingFailed)
            }
        }

        return (labels, details)
    }

    private func classifyRuneDetailed(
        _ image: CGImage,
        artifact: CelticKnotRuneModelArtifact,
        layoutType: CelticKnotLayoutType,
        trackIdx: Int,
        slotIdx: Int
    ) -> (label: String, confidence: Float, margin: Float, accepted: Bool, rejectReason: SlotNilReason?)? {
        let embedding: [Float]?
        if artifact.embeddingVersion >= 3 {
            embedding = PuzzleEmbeddingExtractor.colorEmbeddingV3(for: image, side: 32)
        } else if artifact.embeddingVersion >= 2 {
            embedding = PuzzleEmbeddingExtractor.colorEmbedding(for: image, side: 32)
        } else {
            embedding = PuzzleEmbeddingExtractor.embedding(for: image, side: 32)
        }
        guard let emb = embedding else { return nil }

        if artifact.isKNN {
            return classifyKNN(
                emb,
                artifact: artifact,
                layoutType: layoutType,
                trackIdx: trackIdx,
                slotIdx: slotIdx
            )
        }
        return classifyCentroid(emb, artifact: artifact)
    }

    private func classifyKNN(
        _ emb: [Float],
        artifact: CelticKnotRuneModelArtifact,
        layoutType: CelticKnotLayoutType,
        trackIdx: Int,
        slotIdx: Int
    ) -> (label: String, confidence: Float, margin: Float, accepted: Bool, rejectReason: SlotNilReason?)? {
        guard let refs = artifact.referenceEmbeddings,
              let refLabels = artifact.referenceLabels,
              !refs.isEmpty, refs.count == refLabels.count else { return nil }
        let k = min(artifact.k ?? 5, refs.count)

        // Maintain top-k (similarity, index) pairs sorted descending in a single
        // streaming pass. For k≪N this is O(N·k) and avoids allocating an N-sized
        // similarities array plus a full O(N log N) sort. Both refs[i] and emb are
        // produced by L2-normalizing pipelines, so dotNormalized ≡ cosine here.
        var topSims = [Float](repeating: -.infinity, count: k)
        var topIdxs = [Int](repeating: -1, count: k)
        let n = refs.count
        for i in 0..<n {
            let sim = MathHelpers.dotNormalized(emb, refs[i])
            if sim <= topSims[k - 1] { continue }
            var pos = k - 1
            while pos > 0 && topSims[pos - 1] < sim {
                topSims[pos] = topSims[pos - 1]
                topIdxs[pos] = topIdxs[pos - 1]
                pos -= 1
            }
            topSims[pos] = sim
            topIdxs[pos] = i
        }

        var voteWeights: [String: Float] = [:]
        var voteCounts: [String: Int] = [:]
        var totalWeight: Float = 0
        for j in 0..<k {
            let idx = topIdxs[j]
            guard idx >= 0 else { continue }
            let w = max(0, topSims[j])
            voteWeights[refLabels[idx], default: 0] += w
            voteCounts[refLabels[idx], default: 0] += 1
            totalWeight += w
        }

        guard totalWeight > 0, let bestLabel = voteWeights.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        let winnerAvgSim: Float = {
            var sum: Float = 0
            var count: Float = 0
            for j in 0..<k {
                let idx = topIdxs[j]
                guard idx >= 0, refLabels[idx] == bestLabel else { continue }
                sum += topSims[j]
                count += 1
            }
            return count > 0 ? sum / count : 0
        }()

        let runnerUp = voteWeights.filter { $0.key != bestLabel }.max(by: { $0.value < $1.value })
        let runnerAvgSim: Float = {
            guard let runnerLabel = runnerUp?.key else { return 0 }
            var sum: Float = 0
            var count: Float = 0
            for j in 0..<k {
                let idx = topIdxs[j]
                guard idx >= 0, refLabels[idx] == runnerLabel else { continue }
                sum += topSims[j]
                count += 1
            }
            return count > 0 ? sum / count : 0
        }()

        let confidence = winnerAvgSim
        let margin = winnerAvgSim - runnerAvgSim

        let minConf = artifact.recommendedMinConfidence ?? 0
        let minMargin = artifact.recommendedMinMargin ?? 0

        if confidence < minConf {
            return (label: bestLabel, confidence: confidence, margin: margin, accepted: false, rejectReason: .belowConfidence)
        }
        if margin < minMargin {
            return (label: bestLabel, confidence: confidence, margin: margin, accepted: false, rejectReason: .belowMargin)
        }

        return (label: bestLabel, confidence: confidence, margin: margin, accepted: true, rejectReason: nil)
    }

    private func classifyCentroid(
        _ emb: [Float],
        artifact: CelticKnotRuneModelArtifact
    ) -> (label: String, confidence: Float, margin: Float, accepted: Bool, rejectReason: SlotNilReason?)? {
        guard let centroids = artifact.centroids else { return nil }
        let classes = artifact.indexToClass
        guard !centroids.isEmpty, centroids.count == classes.count else { return nil }

        var scores = [Float](repeating: 0, count: centroids.count)
        for i in 0..<centroids.count {
            scores[i] = MathHelpers.dotNormalized(emb, centroids[i])
        }

        let temperature = artifact.calibratedTemperature ?? 8.0
        let scaled = scores.map { $0 * temperature }
        let maxScaled = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - maxScaled) }
        let sumExp = exps.reduce(0, +)
        let probs = sumExp > 0 ? exps.map { $0 / sumExp } : exps

        guard let bestIdx = probs.indices.max(by: { probs[$0] < probs[$1] }) else {
            return nil
        }

        let topProb = probs[bestIdx]
        let sortedProbs = probs.sorted()
        let margin = sortedProbs.count >= 2
            ? sortedProbs[sortedProbs.count - 1] - sortedProbs[sortedProbs.count - 2]
            : topProb

        let minConf = artifact.recommendedMinConfidence ?? 0
        let minMargin = artifact.recommendedMinMargin ?? 0

        if topProb < minConf {
            return (label: classes[bestIdx], confidence: topProb, margin: margin, accepted: false, rejectReason: .belowConfidence)
        }
        if margin < minMargin {
            return (label: classes[bestIdx], confidence: topProb, margin: margin, accepted: false, rejectReason: .belowMargin)
        }

        return (label: classes[bestIdx], confidence: topProb, margin: margin, accepted: true, rejectReason: nil)
    }
}
