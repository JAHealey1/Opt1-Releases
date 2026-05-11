import CoreGraphics
import Foundation

public struct CelticKnotLayoutMetadata {
    public let type: CelticKnotLayoutType
    public let trackCount: Int
    public let laneLengths: [Int]
    public let intersectionCount: Int
    public let estimatedRuneDiameter: CGFloat
    public let topologyHash: [Int]?
}

extension CelticKnotLayoutMetadata {
    public static let runeDiameter: CGFloat = 0.070

    public static func metadata(for type: CelticKnotLayoutType) -> CelticKnotLayoutMetadata {
        switch type {
        case .sixSpot:
            return metadata(type, laneLengths: [16, 16, 16], intersectionCount: 6)
        case .eightSpot:
            return metadata(
                type,
                laneLengths: [16, 16, 16],
                intersectionCount: 8,
                topologyHash: [16, 16, 16, 10115, 20214, 60210, 70109, 1010215, 1070209]
            )
        case .eightSpotLinked:
            return metadata(type, laneLengths: [12, 12, 12, 12], intersectionCount: 8)
        case .eightSpotWrap:
            return metadata(type, laneLengths: [14, 14, 28], intersectionCount: 8)
        case .eightSpotL:
            return metadata(
                type,
                laneLengths: [16, 16, 16],
                intersectionCount: 8,
                topologyHash: [16, 16, 16, 20115, 40103, 90104, 110114, 1060204, 1070211, 1110213, 1120202]
            )
        case .tenSpot:
            return metadata(type, laneLengths: [16, 24, 20], intersectionCount: 10)
        case .tenSpotLinked:
            return metadata(type, laneLengths: [16, 16, 16], intersectionCount: 10)
        case .twelveSpot:
            return metadata(type, laneLengths: [16, 16, 16], intersectionCount: 12)
        case .fourteenSpot:
            return metadata(type, laneLengths: [10, 16, 18, 10], intersectionCount: 14)
        }
    }

    private static func metadata(
        _ type: CelticKnotLayoutType,
        laneLengths: [Int],
        intersectionCount: Int,
        topologyHash: [Int]? = nil
    ) -> CelticKnotLayoutMetadata {
        CelticKnotLayoutMetadata(
            type: type,
            trackCount: laneLengths.count,
            laneLengths: laneLengths,
            intersectionCount: intersectionCount,
            estimatedRuneDiameter: runeDiameter,
            topologyHash: topologyHash
        )
    }
}
