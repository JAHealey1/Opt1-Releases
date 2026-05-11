import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import Opt1Solvers
import Opt1Detection

final class PuzzleDetectionPipeline {
    enum InputMode {
        case fullFrame
        case snipCrop
    }

    struct ReferenceEntry {
        let key: String
        let name: String
        let image: CGImage
        let histogram: [Float]
        let featurePrint: VNFeaturePrintObservation?
        let puzzleEmbedding: [Float]?
        let tileEmbeddings: [[Float]?]
        let hintAssisted: Bool
    }

    struct Result {
        let state: PuzzleBoxState?
        let reason: String
        let confidence: Float
        let bestReference: PuzzleIdentityCandidate?
        /// Non-nil when we identified the puzzle confidently but the gate has
        /// flagged that puzzle key as intentionally unsupported. Lets callers
        /// surface a named "<puzzle> not supported" message instead of the
        /// generic hint-retry prompt.
        let unsupportedPuzzleName: String?

        init(
            state: PuzzleBoxState?,
            reason: String,
            confidence: Float,
            bestReference: PuzzleIdentityCandidate?,
            unsupportedPuzzleName: String? = nil
        ) {
            self.state = state
            self.reason = reason
            self.confidence = confidence
            self.bestReference = bestReference
            self.unsupportedPuzzleName = unsupportedPuzzleName
        }
    }

    typealias ProgressCallback = @Sendable (String) -> Void

    private let localizer = GridLocalizer()
    private lazy var identifier = PuzzleIdentifier(log: { [weak self] message in
        self?.log(message)
    })
    private let matcher = TileMatcher()
    private let gate = DetectionQualityGate()
    private let debugDir: URL?
    private lazy var logURL: URL? = debugDir?.appendingPathComponent("new_pipeline.log")
    /// Persistent handle for the pipeline log. Lazily opened on first write and
    /// reused across subsequent `log(_:)` calls (instead of open/seek/close per
    /// line) until the pipeline is deinitialised.
    private var logFileHandle: FileHandle?
    private let logLock = NSLock()
    /// Reused on every log line — ISO8601DateFormatter construction is expensive.
    private lazy var logTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    private static let cacheLock = NSLock()
    private static var _cachedRefs: [ReferenceEntry]?
    private static var cachedRefs: [ReferenceEntry]? {
        get { cacheLock.withLock { _cachedRefs } }
        set { cacheLock.withLock { _cachedRefs = newValue } }
    }

    init(debugDir: URL?) {
        self.debugDir = debugDir
    }

    deinit {
        logLock.withLock {
            try? logFileHandle?.close()
            logFileHandle = nil
        }
    }

    func detect(
        in image: CGImage,
        mode: InputMode,
        preferredReferenceKey: String?,
        hintReferenceImage: CGImage?,
        progress: ProgressCallback?
    ) -> Result {
        progress?("Loading puzzle references…")
        guard let refs = loadReferences(), !refs.isEmpty else {
            log("detect fail: reason=reference-load-failed")
            return Result(state: nil, reason: "reference-load-failed", confidence: 0, bestReference: nil)
        }
        let activeRefs: [ReferenceEntry]
        if let key = preferredReferenceKey {
            let narrowed = refs.filter { $0.key == key }
            activeRefs = narrowed.isEmpty ? refs : narrowed
        } else {
            let classifierKeys = classifierKeySubset()
            let learnedKeys = learnedIdKeySubset()
            let combinedKeys = classifierKeys.union(learnedKeys)
            if !combinedKeys.isEmpty, combinedKeys.count < refs.count {
                let narrowed = refs.filter { combinedKeys.contains($0.key) }
                activeRefs = narrowed.isEmpty ? refs : narrowed
                let source: String
                if !learnedKeys.isEmpty, !classifierKeys.isEmpty {
                    source = "learned+classifier"
                } else if !learnedKeys.isEmpty {
                    source = "learned"
                } else {
                    source = "classifier"
                }
                log("auto-narrow refs using \(source) subset: \(activeRefs.count)/\(refs.count)")
            } else {
                activeRefs = refs
            }
        }

        progress?("Localizing puzzle grid…")
        guard let localized = localizer.localizeGrid(in: image, mode: mode) else {
            log("detect fail: reason=inner-grid-localization-failed mode=\(modeText(mode))")
            return Result(state: nil, reason: "inner-grid-localization-failed", confidence: 0, bestReference: nil)
        }
        saveDebug(localized.canonicalGridImage, name: mode == .snipCrop ? "new_snip_canonical.png" : "new_opt1_canonical.png")
        log("localized mode=\(modeText(mode)) method=\(localized.method) rect=\(localized.gridRectInImage.integral) score=\(format(localized.localizationScore))")

        progress?("Identifying puzzle…")
        let identityResult = identifier.identifyDetailed(
            canonicalGrid: localized.canonicalGridImage,
            references: activeRefs,
            preferredReferenceKey: preferredReferenceKey,
            mode: .standard
        )
        let identity = identityResult.candidates
        guard let top = identity.first else {
            log("detect fail: reason=reference-identification-failed")
            return Result(state: nil, reason: "reference-identification-failed", confidence: 0, bestReference: nil)
        }
        let idSource = identityResult.usedLearnedModel ? "learned" : "fallback"
        log("identify top=\(top.key) conf=\(format(top.confidence)) dist=\(format(top.distance)) source=\(idSource)")
        if let learnedTop = identityResult.learnedTop {
            log(
                "identify diag learnedTop=\(learnedTop.key) learnedConf=\(format(learnedTop.confidence)) learnedMargin=\(format(identityResult.learnedMargin ?? 0)) fallbackTop=\(identityResult.fallbackTop?.key ?? "none") usedLearned=\(identityResult.usedLearnedModel)"
            )
        }

        // Early-exit for puzzles marked unsupported
        if gate.unsupportedPuzzleKeys.contains(top.key) {
            let displayName = activeRefs.first(where: { $0.key == top.key })?.name ?? top.name
            log("detect early-exit: unsupported puzzle=\(top.key) name=\(displayName) conf=\(format(top.confidence))")
            return Result(
                state: nil,
                reason: "unsupported:\(top.key)",
                confidence: top.confidence,
                bestReference: top,
                unsupportedPuzzleName: displayName
            )
        }

        progress?("Matching tiles…")
        var topRefs = identity.prefix(3).compactMap { candidate in
            activeRefs.first(where: { $0.key == candidate.key })
        }
        var hintIdentityResult: PuzzleIdentifier.IdentifyResult?
        if let hintReferenceImage {
            var hintPreferredKey: String?
            if let hintLocalized = localizer.localizeGrid(in: hintReferenceImage, mode: .fullFrame) ??
                localizer.localizeGrid(in: hintReferenceImage, mode: .snipCrop) {
                saveDebug(hintLocalized.canonicalGridImage, name: "hint_identity_canonical.png")
                let hintIdentity = identifier.identifyDetailed(
                    canonicalGrid: hintLocalized.canonicalGridImage,
                    references: activeRefs,
                    preferredReferenceKey: nil,
                    mode: .hint
                )
                hintIdentityResult = hintIdentity
                if let hintTop = hintIdentity.candidates.first {
                    hintPreferredKey = hintTop.key
                    let hintSource = hintIdentity.usedLearnedModel ? "learned" : "fallback"
                    log(
                        "hint-identify top=\(hintTop.key) conf=\(format(hintTop.confidence)) source=\(hintSource) learnedMargin=\(format(hintIdentity.learnedMargin ?? 0))"
                    )
                    if let learnedTop = hintIdentity.learnedTop {
                        log(
                            "hint-identify diag learnedTop=\(learnedTop.key) learnedConf=\(format(learnedTop.confidence)) fallbackTop=\(hintIdentity.fallbackTop?.key ?? "none") usedLearned=\(hintIdentity.usedLearnedModel)"
                        )
                    }
                }
            }
            let preferredKey = preferredReferenceKey ?? hintPreferredKey ?? top.key
            if let baseRef = activeRefs.first(where: { $0.key == preferredKey }) ?? activeRefs.first(where: { $0.key == top.key }),
               let hintAssistedRef = buildHintAssistedReference(from: hintReferenceImage, baseRef: baseRef) {
                topRefs.removeAll(where: { $0.key == hintAssistedRef.key })
                topRefs.insert(hintAssistedRef, at: 0)
                log("hint-assist active key=\(hintAssistedRef.key) preferred=\(preferredKey)")
            } else {
                log("hint-assist unavailable: failed to localize hint preview")
            }
        }
        var bestState: PuzzleBoxState?
        var bestScore: Float = -1
        var bestReason = "tile-match-failed"
        var bestRef: PuzzleIdentityCandidate?
        var bestAccepted = false

        for ref in topRefs {
            guard let tileMatch = matcher.matchTiles(canonicalGrid: localized.canonicalGridImage, reference: ref) else { continue }
            let refConfidence = identity.first(where: { $0.key == ref.key })?.confidence ?? 0
            let mainLearnedAccepted = identityResult.usedLearnedModel && identityResult.learnedTop?.key == ref.key
            let hintLearnedAccepted = hintIdentityResult?.usedLearnedModel == true && hintIdentityResult?.learnedTop?.key == ref.key
            let gateInput = DetectionGateInput(
                puzzleKey: ref.key,
                localizationScore: localized.localizationScore,
                puzzleConfidence: refConfidence,
                learnedIdAccepted: mainLearnedAccepted || hintLearnedAccepted,
                tileConfidence: tileMatch.confidence,
                ambiguityCount: tileMatch.ambiguityCount,
                tiles: tileMatch.tiles,
                hintAssisted: ref.hintAssisted
            )
            let gateResult = gate.evaluate(gateInput)
            log("candidate ref=\(ref.key) tileConf=\(format(tileMatch.confidence)) ambiguities=\(tileMatch.ambiguityCount) gate=\(gateResult.reason) accepted=\(gateResult.accepted)")
            let state = PuzzleBoxState(
                tiles: tileMatch.tiles,
                gridBoundsInImage: localized.gridRectInImage,
                cellSize: localized.cellSize,
                puzzleName: ref.name,
                matchConfidence: gateResult.finalConfidence,
                needsHintAssistedRetry: gateResult.needsHintAssistedRetry
            )
            let shouldReplace: Bool
            if gateResult.accepted && !bestAccepted {
                shouldReplace = true
            } else if gateResult.accepted == bestAccepted {
                shouldReplace = gateResult.finalConfidence > bestScore
            } else {
                shouldReplace = false
            }
            if shouldReplace {
                bestScore = gateResult.finalConfidence
                bestState = gateResult.accepted ? state : nil
                bestReason = gateResult.reason
                bestRef = identity.first(where: { $0.key == ref.key })
                bestAccepted = gateResult.accepted
            }
        }

        if let state = bestState {
            log("detect success: ref=\(state.puzzleName) conf=\(format(state.matchConfidence))")
            return Result(state: state, reason: "ok", confidence: state.matchConfidence, bestReference: bestRef)
        }
        log("detect fail: reason=\(bestReason) bestScore=\(format(max(0, bestScore)))")
        return Result(state: nil, reason: bestReason, confidence: max(0, bestScore), bestReference: bestRef ?? top)
    }

    func classifyReference(in image: CGImage) -> PuzzleIdentityCandidate? {
        guard let refs = loadReferences(), !refs.isEmpty else { return nil }
        return identifier.identify(
            canonicalGrid: image,
            references: refs,
            preferredReferenceKey: nil,
            mode: .standard
        ).first
    }

    private func loadReferences() -> [ReferenceEntry]? {
        if let cached = Self.cachedRefs, !cached.isEmpty {
            return cached
        }
        guard let manifest = PuzzleManifest.load() else { return nil }
        var refs: [ReferenceEntry] = []
        refs.reserveCapacity(manifest.count)
        let artifactRefs = PuzzleReferenceEmbeddingsArtifact.loadFromBundle()
        let artifactByKey = Dictionary(uniqueKeysWithValues: (artifactRefs?.references ?? []).map { ($0.key, $0) })

        for entry in manifest {
            guard let key = entry["key"], let name = entry["displayName"], let image = loadPuzzleImage(key: key) else { continue }
            let hist = VisionHelpers.rgbHistogram(image, bins: 16)
            let fp = VisionHelpers.featurePrint(of: image)
            let fallbackPuzzleEmbedding = PuzzleEmbeddingExtractor.embedding(for: image, side: 48)
            let fallbackTileEmbeddings = matcher.precomputeReferenceEmbeddings(refImage: image)
            let artifact = artifactByKey[key]
            let puzzleEmbedding = artifact?.puzzleEmbedding ?? fallbackPuzzleEmbedding
            let tileEmbeddings = artifact?.tileEmbeddings ?? fallbackTileEmbeddings
            refs.append(
                ReferenceEntry(
                    key: key,
                    name: name,
                    image: image,
                    histogram: hist,
                    featurePrint: fp,
                    puzzleEmbedding: puzzleEmbedding,
                    tileEmbeddings: tileEmbeddings,
                    hintAssisted: false
                )
            )
        }
        log("loadReferences count=\(refs.count) artifactRefs=\(artifactByKey.count)")
        Self.cachedRefs = refs
        return refs.isEmpty ? nil : refs
    }

    private func loadPuzzleImage(key: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "PuzzleImages"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    private func saveDebug(_ image: CGImage, name: String) {
        guard let debugDir else { return }
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        let url = debugDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    private func log(_ text: String) {
        let line = "[\(logTimestampFormatter.string(from: Date()))] \(text)\n"
        print("[PuzzleDetectionPipeline] \(text)")
        guard let logURL else { return }

        let data = Data(line.utf8)
        logLock.withLock {
            if logFileHandle == nil {
                let fm = FileManager.default
                if !fm.fileExists(atPath: logURL.path) {
                    fm.createFile(atPath: logURL.path, contents: nil)
                }
                logFileHandle = try? FileHandle(forWritingTo: logURL)
                try? logFileHandle?.seekToEnd()
            }
            try? logFileHandle?.write(contentsOf: data)
        }
    }

    private func modeText(_ mode: InputMode) -> String {
        mode == .snipCrop ? "opt2" : "opt1"
    }

    private func format(_ value: Float) -> String {
        if !value.isFinite { return "nan" }
        return String(format: "%.3f", Double(value))
    }

    private func classifierKeySubset() -> Set<String> {
        guard let artifact = PuzzleClassifierArtifact.loadFromBundle() else { return [] }
        var keys: Set<String> = []
        if let prototypes = artifact.prototypes {
            for p in prototypes { keys.insert(p.key) }
        }
        if let centroids = artifact.centroids {
            for c in centroids { keys.insert(c.key) }
        }
        return keys
    }

    /// Class set exposed by the learned-id artifact (centroid or KNN). When the
    /// KNN path is enabled we union this into the auto-narrow filter so classes
    /// the identifier knows about cannot be stripped from `activeRefs` by a
    /// stale CoreML classifier whitelist.
    private func learnedIdKeySubset() -> Set<String> {
        guard PuzzleDetectorRollout.useKnnIdModel,
              let artifact = PuzzleLearnedIdArtifact.loadFromBundle()
        else { return [] }
        var keys: Set<String> = []
        for key in artifact.classToIndex.keys { keys.insert(key) }
        if let refLabels = artifact.referenceLabels {
            for label in refLabels { keys.insert(label) }
        }
        return keys
    }

    private func buildHintAssistedReference(
        from hintPreviewImage: CGImage,
        baseRef: ReferenceEntry
    ) -> ReferenceEntry? {
        let localized =
            localizer.localizeGrid(in: hintPreviewImage, mode: .fullFrame) ??
            localizer.localizeGrid(in: hintPreviewImage, mode: .snipCrop)
        guard let localized else { return nil }
        let hintTileEmbeddings = matcher.precomputeReferenceEmbeddings(refImage: localized.canonicalGridImage)
        let populated = hintTileEmbeddings.compactMap { $0 }.count
        guard populated >= 24 else { return nil }
        saveDebug(localized.canonicalGridImage, name: "hint_assist_canonical.png")
        return ReferenceEntry(
            key: baseRef.key,
            name: baseRef.name,
            image: localized.canonicalGridImage,
            histogram: baseRef.histogram,
            featurePrint: baseRef.featurePrint,
            puzzleEmbedding: baseRef.puzzleEmbedding,
            tileEmbeddings: hintTileEmbeddings,
            hintAssisted: true
        )
    }
}

// MARK: - Learned ID model rollout

final class PuzzleDetectorRollout {
    private enum Keys {
        static let learnedIdModel = "PuzzleDetectorUseLearnedIdModel"
        static let learnedIdModelHintOnly = "PuzzleDetectorUseLearnedIdModelHintOnly"
        static let learnedIdMinConfidence = "PuzzleDetectorLearnedIdMinConfidence"
        static let learnedIdMinMargin = "PuzzleDetectorLearnedIdMinMargin"
        static let knnIdModel = "PuzzleDetectorUseKnnIdModel"
        static let tileKnnModel = "PuzzleDetectorUseKnnTileModel"
    }

    static var useLearnedIdModel: Bool {
        UserDefaults.standard.object(forKey: Keys.learnedIdModel) as? Bool ?? true
    }

    static var useLearnedIdModelHintOnly: Bool {
        UserDefaults.standard.object(forKey: Keys.learnedIdModelHintOnly) as? Bool ?? true
    }

    /// Master kill switch for the KNN-based puzzle identifier. When disabled
    /// the runtime falls back to the legacy centroid-based artifact loader,
    /// assuming one is still bundled.
    static var useKnnIdModel: Bool {
        UserDefaults.standard.object(forKey: Keys.knnIdModel) as? Bool ?? true
    }

    /// Master kill switch for the KNN-based tile matcher. When disabled the
    /// runtime falls back to the single-reference cosine + ZNCC path.
    static var tileKnnEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.tileKnnModel) as? Bool ?? true
    }

    /// Defaults recalibrated against the new KNN metrics JSON (see
    /// `train_puzzle_id_knn_model.py`). The KNN predictions reliably score
    /// >= 0.94 cosine on correct matches; 0.80 leaves a safety buffer for
    /// domain shift between captures.
    static var learnedIdMinConfidence: Float {
        learnedIdMinConfidenceOverride ?? 0.80
    }

    static var learnedIdMinMargin: Float {
        learnedIdMinMarginOverride ?? 0.05
    }

    static var learnedIdMinConfidenceOverride: Float? {
        floatOverride(forKey: Keys.learnedIdMinConfidence)
    }

    static var learnedIdMinMarginOverride: Float? {
        floatOverride(forKey: Keys.learnedIdMinMargin)
    }

    static func learnedIdModelEnabled(for mode: PuzzleIdentifier.IdentificationMode) -> Bool {
        if !useKnnIdModel { return false }
        if useLearnedIdModel { return true }
        if useLearnedIdModelHintOnly, mode == .hint { return true }
        return false
    }

    private static func floatOverride(forKey key: String) -> Float? {
        if let value = UserDefaults.standard.object(forKey: key) as? Float { return value }
        if let value = UserDefaults.standard.object(forKey: key) as? Double { return Float(value) }
        return nil
    }
}
