import CoreGraphics
import Foundation

// MARK: - Layout type

public enum CelticKnotLayoutType: String, CaseIterable, CustomStringConvertible {
    case sixSpot         = "6-spot"
    case eightSpot       = "8-spot"
    case eightSpotLinked = "8-spot-linked"
    case eightSpotWrap   = "8-spot-wrap"
    case eightSpotL      = "8-spot-L"
    case tenSpot         = "10-spot"
    case tenSpotLinked   = "10-spot-linked"
    case twelveSpot      = "12-spot"
    case fourteenSpot    = "14-spot"

    public var description: String { rawValue }
}

// MARK: - Domain types

public struct RuneSlot {
    public let x: CGFloat
    public let y: CGFloat
    public let trackIndex: Int
    public let slotIndex: Int
    public var intersectionPartner: (track: Int, slot: Int)? = nil
    public var isOnTop: Bool = true

    public init(
        x: CGFloat,
        y: CGFloat,
        trackIndex: Int,
        slotIndex: Int,
        intersectionPartner: (track: Int, slot: Int)? = nil,
        isOnTop: Bool = true
    ) {
        self.x = x
        self.y = y
        self.trackIndex = trackIndex
        self.slotIndex = slotIndex
        self.intersectionPartner = intersectionPartner
        self.isOnTop = isOnTop
    }
}

public struct CelticKnotLayout {
    public let type: CelticKnotLayoutType
    public let tracks: [[RuneSlot]]
    public let intersections: [(trackA: Int, slotA: Int, trackB: Int, slotB: Int)]
    public let estimatedRuneDiameter: CGFloat
    public let clockwiseRotationSigns: [Int]

    public init(
        type: CelticKnotLayoutType,
        tracks: [[RuneSlot]],
        intersections: [(trackA: Int, slotA: Int, trackB: Int, slotB: Int)],
        estimatedRuneDiameter: CGFloat,
        clockwiseRotationSigns: [Int]? = nil
    ) {
        var mutableTracks = tracks
        for inter in intersections {
            mutableTracks[inter.trackA][inter.slotA].intersectionPartner = (inter.trackB, inter.slotB)
            mutableTracks[inter.trackB][inter.slotB].intersectionPartner = (inter.trackA, inter.slotA)
        }
        self.type = type
        self.tracks = mutableTracks
        self.intersections = intersections
        self.estimatedRuneDiameter = estimatedRuneDiameter
        self.clockwiseRotationSigns = clockwiseRotationSigns ?? Array(repeating: 1, count: tracks.count)
    }
}

public struct CelticKnotSlotClassification {
    public let label: String?
    public let confidence: Float?
    public let margin: Float?
    public let reason: CelticKnotSlotNilReason?

    public init(
        label: String?,
        confidence: Float?,
        margin: Float?,
        reason: CelticKnotSlotNilReason?
    ) {
        self.label = label
        self.confidence = confidence
        self.margin = margin
        self.reason = reason
    }
}

public enum CelticKnotSlotNilReason: String {
    case hidden = "hidden"
    case belowConfidence = "low_conf"
    case belowMargin = "low_margin"
    case embeddingFailed = "emb_fail"
    case noCrop = "no_crop"
}

public struct CelticKnotState {
    public let layout: CelticKnotLayout
    public let runeLabels: [[String?]]
    public let classDetails: [[CelticKnotSlotClassification]]
    public let puzzleBoundsInImage: CGRect
    public let runeAreaInImage: CGRect
    public let isInverted: Bool

    public init(
        layout: CelticKnotLayout,
        runeLabels: [[String?]],
        classDetails: [[CelticKnotSlotClassification]],
        puzzleBoundsInImage: CGRect,
        runeAreaInImage: CGRect,
        isInverted: Bool
    ) {
        self.layout = layout
        self.runeLabels = runeLabels
        self.classDetails = classDetails
        self.puzzleBoundsInImage = puzzleBoundsInImage
        self.runeAreaInImage = runeAreaInImage
        self.isInverted = isInverted
    }
}

/// One pass of a celtic-knot capture, with every slot classified (intersection
/// slots included) so the coordinator can later try both possible
/// "this-capture-was-the-inverted-one" hypotheses without a second classify.
public struct CelticKnotCapture {
    public let layout: CelticKnotLayout
    /// 2D matrix of labels, indexed `[trackIdx][slotIdx]`; intersection slots
    /// carry whatever rune is currently visible at that pixel location for
    /// either track-attribution. Cross-attribution between tracks happens at
    /// hypothesis-build time in the coordinator.
    public let labels: [[String?]]
    public let details: [[CelticKnotSlotClassification]]
    public let puzzleBoundsInImage: CGRect
    public let runeAreaInImage: CGRect
    /// Root training-data puzzle directory (e.g. `.../puzzle_<ts>`), shared
    /// across both captures so pass 2 can deposit its crops alongside pass 1
    /// and `meta.json` can be written at the puzzle level after hypothesis
    /// selection. Nil when developer-mode / training dumps are off.
    public let trainingDirectory: URL?

    public init(
        layout: CelticKnotLayout,
        labels: [[String?]],
        details: [[CelticKnotSlotClassification]],
        puzzleBoundsInImage: CGRect,
        runeAreaInImage: CGRect,
        trainingDirectory: URL?
    ) {
        self.layout = layout
        self.labels = labels
        self.details = details
        self.puzzleBoundsInImage = puzzleBoundsInImage
        self.runeAreaInImage = runeAreaInImage
        self.trainingDirectory = trainingDirectory
    }
}

public struct CelticKnotDetectionResult {
    public let puzzleBounds: CGRect
    public let runeArea: CGRect
    public let layoutType: CelticKnotLayoutType
    public let layout: CelticKnotLayout
    public let gridAnalysis: CelticKnotGridReader.Analysis?

    public init(
        puzzleBounds: CGRect,
        runeArea: CGRect,
        layoutType: CelticKnotLayoutType,
        layout: CelticKnotLayout,
        gridAnalysis: CelticKnotGridReader.Analysis?
    ) {
        self.puzzleBounds = puzzleBounds
        self.runeArea = runeArea
        self.layoutType = layoutType
        self.layout = layout
        self.gridAnalysis = gridAnalysis
    }
}
