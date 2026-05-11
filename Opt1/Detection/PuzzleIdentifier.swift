import CoreGraphics
import CoreML
import Foundation
import Vision
import Opt1Detection

struct PuzzleIdentityCandidate {
    let key: String
    let name: String
    let confidence: Float
    let distance: Float
}

final class PuzzleIdentifier {
    private var model: VNCoreMLModel?
    private let classifierArtifact: PuzzleClassifierArtifact?
    private let learnedIdArtifact: PuzzleLearnedIdArtifact?
    private let log: ((String) -> Void)?

    enum IdentificationMode {
        case standard
        case hint
    }

    struct IdentifyResult {
        let candidates: [PuzzleIdentityCandidate]
        let usedLearnedModel: Bool
        let learnedTop: PuzzleIdentityCandidate?
        let learnedMargin: Float?
        let fallbackTop: PuzzleIdentityCandidate?
    }

    init(log: ((String) -> Void)? = nil) {
        self.log = log
        self.model = Self.loadModel(named: "PuzzleIdClassifier")
        self.classifierArtifact = PuzzleClassifierArtifact.loadFromBundle()
        self.learnedIdArtifact = PuzzleLearnedIdArtifact.loadFromBundle()
    }

    func identify(
        canonicalGrid: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry],
        preferredReferenceKey: String?,
        mode: IdentificationMode = .standard
    ) -> [PuzzleIdentityCandidate] {
        identifyDetailed(
            canonicalGrid: canonicalGrid,
            references: references,
            preferredReferenceKey: preferredReferenceKey,
            mode: mode
        ).candidates
    }

    func identifyDetailed(
        canonicalGrid: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry],
        preferredReferenceKey: String?,
        mode: IdentificationMode = .standard
    ) -> IdentifyResult {
        guard !references.isEmpty else {
            return IdentifyResult(
                candidates: [],
                usedLearnedModel: false,
                learnedTop: nil,
                learnedMargin: nil,
                fallbackTop: nil
            )
        }

        if let key = preferredReferenceKey,
           let forced = references.first(where: { $0.key == key }) {
            return IdentifyResult(
                candidates: [PuzzleIdentityCandidate(key: forced.key, name: forced.name, confidence: 0.999, distance: 0)],
                usedLearnedModel: false,
                learnedTop: nil,
                learnedMargin: nil,
                fallbackTop: nil
            )
        }

        let fallbackCandidates = identifyByFusion(canonicalGrid, references: references)
        let learnedCandidates = identifyViaLearnedIdArtifact(canonicalGrid, references: references)
        let learnedTop = learnedCandidates.first
        let learnedMargin = candidateMargin(learnedCandidates)
        let fallbackTop = fallbackCandidates.first
        let learnedEnabled = PuzzleDetectorRollout.learnedIdModelEnabled(for: mode)

        guard learnedEnabled else {
            return IdentifyResult(
                candidates: fallbackCandidates,
                usedLearnedModel: false,
                learnedTop: learnedTop,
                learnedMargin: learnedMargin,
                fallbackTop: fallbackTop
            )
        }

        guard let top = learnedTop else {
            log?("learned-id unavailable (artifact missing or no candidates); fallback=\(fallbackTop?.key ?? "none")")
            return IdentifyResult(
                candidates: fallbackCandidates,
                usedLearnedModel: false,
                learnedTop: nil,
                learnedMargin: nil,
                fallbackTop: fallbackTop
            )
        }

        let artifactMinConfidence = learnedIdArtifact?.recommendedMinConfidence
        let artifactMinMargin = learnedIdArtifact?.recommendedMinMargin
        let minConfidence = PuzzleDetectorRollout.learnedIdMinConfidenceOverride ??
            artifactMinConfidence ??
            PuzzleDetectorRollout.learnedIdMinConfidence
        let minMargin = PuzzleDetectorRollout.learnedIdMinMarginOverride ??
            artifactMinMargin ??
            PuzzleDetectorRollout.learnedIdMinMargin
        let thresholdSource: String = {
            if PuzzleDetectorRollout.learnedIdMinConfidenceOverride != nil ||
                PuzzleDetectorRollout.learnedIdMinMarginOverride != nil {
                return "user-defaults"
            }
            if artifactMinConfidence != nil || artifactMinMargin != nil {
                return "artifact-recommended"
            }
            return "static-defaults"
        }()
        let margin = learnedMargin ?? 0
        let accepted = top.confidence >= minConfidence && margin >= minMargin
        if accepted {
            log?("learned-id accepted top=\(top.key) conf=\(format(top.confidence)) margin=\(format(margin)) fallbackTop=\(fallbackTop?.key ?? "none") thresholdSource=\(thresholdSource)")
            return IdentifyResult(
                candidates: learnedCandidates,
                usedLearnedModel: true,
                learnedTop: top,
                learnedMargin: margin,
                fallbackTop: fallbackTop
            )
        }

        log?("learned-id fallback low-confidence top=\(top.key) conf=\(format(top.confidence)) margin=\(format(margin)) thresholds=(\(format(minConfidence)),\(format(minMargin))) fallbackTop=\(fallbackTop?.key ?? "none") thresholdSource=\(thresholdSource)")
        return IdentifyResult(
            candidates: fallbackCandidates,
            usedLearnedModel: false,
            learnedTop: top,
            learnedMargin: margin,
            fallbackTop: fallbackTop
        )
    }

    /// Fallback identification pipeline when the KNN/learned branch is rejected
    /// by the confidence/margin gate. Feature-print is the primary signal, with
    /// the old CoreML + v1-centroid artifacts kept as tie-breakers for one
    /// release. `identifyViaReferenceEmbeddings` has been retired in favour of
    /// the learned KNN model and is no longer fused here.
    private func identifyByFusion(
        _ canonicalGrid: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        var byKey: [String: PuzzleIdentityCandidate] = [:]

        let fpCandidates = identifyByFeaturePrint(canonicalGrid, references: references)
        for fp in fpCandidates {
            byKey[fp.key] = fp
        }

        let modelCandidates = classifyWithModel(canonicalGrid)
        for m in modelCandidates {
            guard let ref = references.first(where: { $0.key == m.key || $0.name == m.name }) else { continue }
            if let existing = byKey[ref.key] {
                let fused = 0.65 * existing.confidence + 0.35 * m.confidence
                byKey[ref.key] = PuzzleIdentityCandidate(
                    key: existing.key,
                    name: existing.name,
                    confidence: fused,
                    distance: min(existing.distance, 1.0 - m.confidence)
                )
            } else {
                byKey[ref.key] = PuzzleIdentityCandidate(
                    key: ref.key,
                    name: ref.name,
                    confidence: m.confidence,
                    distance: 1.0 - m.confidence
                )
            }
        }

        let artifactCandidates = identifyViaClassifierArtifact(canonicalGrid, references: references)
        for cand in artifactCandidates {
            if let existing = byKey[cand.key] {
                let fused = 0.70 * existing.confidence + 0.30 * cand.confidence
                byKey[cand.key] = PuzzleIdentityCandidate(
                    key: existing.key,
                    name: existing.name,
                    confidence: fused,
                    distance: min(existing.distance, cand.distance)
                )
            } else {
                byKey[cand.key] = cand
            }
        }

        let ranked = byKey.values.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.distance < rhs.distance }
            return lhs.confidence > rhs.confidence
        }
        return Array(ranked.prefix(5))
    }

    private func identifyViaLearnedIdArtifact(
        _ image: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        guard let artifact = learnedIdArtifact else { return [] }
        guard let query = embedding(for: image, version: artifact.embeddingVersion, side: 48) else { return [] }

        if artifact.isKNN {
            return knnCandidates(query: query, artifact: artifact, references: references)
        }
        return centroidCandidates(query: query, artifact: artifact, references: references)
    }

    private func embedding(for image: CGImage, version: Int, side: Int) -> [Float]? {
        switch version {
        case PuzzleEmbeddingExtractor.versionV4:
            return PuzzleEmbeddingExtractor.colorEmbeddingV4(for: image, side: side)
        case PuzzleEmbeddingExtractor.versionV3:
            return PuzzleEmbeddingExtractor.colorEmbeddingV3(for: image, side: side)
        case PuzzleEmbeddingExtractor.versionV2:
            return PuzzleEmbeddingExtractor.colorEmbedding(for: image, side: side)
        case PuzzleEmbeddingExtractor.version:
            return PuzzleEmbeddingExtractor.embedding(for: image, side: side)
        default:
            return nil
        }
    }

    /// KNN branch: cosine-sim over every reference embedding in the artifact, then
    /// top-k weighted vote per class. Winner confidence is the mean cosine of its
    /// voting neighbours; margin is winner-avg-sim minus runner-avg-sim (matches
    /// the trainer's calibration in train_puzzle_id_knn_model.py).
    private func knnCandidates(
        query: [Float],
        artifact: PuzzleLearnedIdArtifact,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        guard let refEmbeddings = artifact.referenceEmbeddings,
              let refLabels = artifact.referenceLabels,
              refEmbeddings.count == refLabels.count,
              !refEmbeddings.isEmpty else {
            return centroidCandidates(query: query, artifact: artifact, references: references)
        }

        let k = max(1, min(artifact.k ?? 3, refEmbeddings.count))
        var sims = [Float](repeating: 0, count: refEmbeddings.count)
        for i in 0..<refEmbeddings.count {
            sims[i] = MathHelpers.cosine(query, refEmbeddings[i])
        }

        var indices = Array(0..<sims.count)
        indices.sort { sims[$0] > sims[$1] }
        let topIndices = indices.prefix(k)

        var voteSum: [String: Float] = [:]
        var voteCount: [String: Int] = [:]
        for idx in topIndices {
            let label = refLabels[idx]
            let sim = max(0, sims[idx])
            voteSum[label, default: 0] += sim
            voteCount[label, default: 0] += 1
        }

        let averages: [(key: String, score: Float)] = voteSum.map { key, total in
            let count = Float(voteCount[key] ?? 1)
            return (key, total / max(1, count))
        }.sorted { $0.score > $1.score }

        let refsByKey = Dictionary(uniqueKeysWithValues: references.map { ($0.key, $0) })
        var out: [PuzzleIdentityCandidate] = []
        out.reserveCapacity(averages.count)
        var droppedWinner: (key: String, score: Float)?
        for entry in averages {
            guard let ref = refsByKey[entry.key] else {
                if droppedWinner == nil {
                    droppedWinner = (entry.key, entry.score)
                }
                continue
            }
            out.append(PuzzleIdentityCandidate(
                key: ref.key,
                name: ref.name,
                confidence: entry.score,
                distance: max(0, 1 - entry.score)
            ))
        }
        if out.isEmpty, let dropped = droppedWinner {
            // The KNN winner isn't in the candidate reference list. This should
            // no longer happen with the auto-narrow fix but log loudly if it
            // regresses so we don't silently fall back to the old pipeline
            // again.
            log?("knn-candidates dropped winner=\(dropped.key) score=\(format(dropped.score)) (not in active references)")
        }
        return Array(out.prefix(5))
    }

    /// Centroid (legacy) branch: cosine vs per-class centroid, softmaxed over top-5.
    private func centroidCandidates(
        query: [Float],
        artifact: PuzzleLearnedIdArtifact,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        let refsByKey = Dictionary(uniqueKeysWithValues: references.map { ($0.key, $0) })
        var scored: [(ref: PuzzleDetectionPipeline.ReferenceEntry, score: Float)] = []
        scored.reserveCapacity(artifact.classToIndex.count)

        for (key, index) in artifact.classToIndex {
            guard index >= 0, index < artifact.centroids.count, let ref = refsByKey[key] else { continue }
            let centroid = artifact.centroids[index]
            let score = MathHelpers.cosine(query, centroid)
            scored.append((ref, score))
        }

        scored.sort { $0.score > $1.score }
        let top = Array(scored.prefix(5))
        guard !top.isEmpty else { return [] }
        let temperature = max(0.1, artifact.calibratedTemperature ?? 7.5)
        let probs = MathHelpers.softmax(top.map { $0.score * temperature })
        return zip(top, probs).map { pair in
            let (entry, p) = pair
            return PuzzleIdentityCandidate(
                key: entry.ref.key,
                name: entry.ref.name,
                confidence: p,
                distance: max(0, 1 - entry.score)
            )
        }
    }

    private func identifyViaClassifierArtifact(
        _ image: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        guard let artifact = classifierArtifact,
              artifact.embeddingVersion == PuzzleEmbeddingExtractor.version,
              let query = PuzzleEmbeddingExtractor.embedding(for: image, side: 48) else { return [] }

        let knownNames = Set(references.map { $0.key })
        var scored: [(key: String, score: Float)] = []

        if let prototypeSets = artifact.prototypes, !prototypeSets.isEmpty {
            for set in prototypeSets where knownNames.contains(set.key) {
                let sims = set.vectors.map { MathHelpers.cosine(query, $0) }.sorted(by: >)
                guard !sims.isEmpty else { continue }
                let k = min(3, sims.count)
                let topKMean = sims.prefix(k).reduce(Float(0), +) / Float(k)
                scored.append((set.key, topKMean))
            }
        }

        if scored.isEmpty, let centroids = artifact.centroids {
            scored = centroids.compactMap { c in
                guard knownNames.contains(c.key) else { return nil }
                return (c.key, MathHelpers.cosine(query, c.vector))
            }
        }

        scored.sort { $0.score > $1.score }
        let top = Array(scored.prefix(5))
        guard !top.isEmpty else { return [] }
        let probs = MathHelpers.softmax(top.map { $0.score * 6.0 })
        return zip(top, probs).compactMap { pair in
            let (entry, prob) = pair
            guard let ref = references.first(where: { $0.key == entry.key }) else { return nil }
            return PuzzleIdentityCandidate(
                key: ref.key,
                name: ref.name,
                confidence: prob,
                distance: max(0, 1 - entry.score)
            )
        }
    }

    private func classifyWithModel(_ image: CGImage) -> [PuzzleIdentityCandidate] {
        guard let model else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image)
        do { try handler.perform([request]) } catch { return [] }
        guard let obs = request.results as? [VNClassificationObservation], !obs.isEmpty else { return [] }
        return obs.prefix(5).map {
            PuzzleIdentityCandidate(key: $0.identifier, name: $0.identifier, confidence: $0.confidence, distance: 1 - $0.confidence)
        }
    }

    private func identifyByFeaturePrint(
        _ image: CGImage,
        references: [PuzzleDetectionPipeline.ReferenceEntry]
    ) -> [PuzzleIdentityCandidate] {
        guard let queryFP = VisionHelpers.featurePrint(of: image) else { return [] }
        var scored: [(ref: PuzzleDetectionPipeline.ReferenceEntry, dist: Float)] = []
        scored.reserveCapacity(references.count)

        for ref in references {
            if let fp = ref.featurePrint {
                var dist: Float = 1
                try? queryFP.computeDistance(&dist, to: fp)
                scored.append((ref, dist))
            } else {
                let sim = MathHelpers.cosine(VisionHelpers.rgbHistogram(image, bins: 16), ref.histogram)
                let pseudoDist = max(0, 1 - sim)
                scored.append((ref, pseudoDist))
            }
        }
        scored.sort { $0.dist < $1.dist }

        let temperatures = scored.map { -$0.dist * 4.0 }
        let probs = MathHelpers.softmax(temperatures)
        return zip(scored, probs).prefix(5).map { pair in
            let (entry, p) = pair
            return PuzzleIdentityCandidate(
                key: entry.ref.key,
                name: entry.ref.name,
                confidence: p,
                distance: entry.dist
            )
        }
    }

    private static func loadModel(named name: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        return vn
    }

    private func candidateMargin(_ candidates: [PuzzleIdentityCandidate]) -> Float? {
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return first.confidence }
        return first.confidence - candidates[1].confidence
    }

    private func format(_ value: Float) -> String {
        if !value.isFinite { return "nan" }
        return String(format: "%.3f", Double(value))
    }
}
