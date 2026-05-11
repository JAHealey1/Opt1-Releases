import CoreGraphics
import Foundation
import Opt1Detection

/// ClueTrainer-inspired diagnostic reader for the Celtic Knot tile grid.
///
/// The reader deliberately starts as a conservative companion to the existing
/// template matcher: it reports grid anchoring, per-tile structure and topology
/// hints without needing rune identity classification.
public struct CelticKnotGridReader {

    private let runePresenceClassifier: RunePresenceClassifier

    public init(artifact: CelticKnotRuneModelArtifact? = CelticKnotRuneModelArtifact.loadFromBundle()) {
        self.runePresenceClassifier = RunePresenceClassifier(artifact: artifact)
    }

    public struct GridPoint: Hashable, CustomStringConvertible {
        public let x: Int
        public let y: Int

        public var description: String { "(\(x),\(y))" }
    }

    public struct Tile {
        public let point: GridPoint
        public let originInImage: CGPoint
        public let centerInImage: CGPoint
        public let trackColor: Int?
        public let neighboursExist: [Bool]
        public let isIntersection: Bool
        public let intersectionMatches: Bool?
        public let runeLabel: String?
        public let runeConfidence: Float?
        public let isTraceable: Bool
        public let trackColorConfidence: Float?
        public let backgroundCount: Int

        public var isReadable: Bool { true }
    }

    public struct RejectedTile {
        public let point: GridPoint
        public let backgroundCount: Int
        public let neighboursExist: [Bool]
        public let runeLabel: String?
        public let runeConfidence: Float?
        public let visualContentFraction: Float
        public let visualInkFraction: Float
        public let visualVariance: Float
        public let trackColor: Int?
        public let trackColorConfidence: Float?
        public let reason: String
    }

    public struct Lane {
        public let color: Int
        public let tiles: [Tile]
    }

    public struct Topology {
        public let laneLengths: [Int]
        public let intersectionCount: Int
        public let candidate: CelticKnotLayoutType?
        public let confidence: Float
        public let reason: String

        public var description: String {
            let layout = candidate?.rawValue ?? "unknown"
            return "candidate=\(layout) lengths=\(laneLengths) intersections=\(intersectionCount) confidence=\(String(format: "%.2f", confidence)) reason=\(reason)"
        }
    }

    public struct Analysis {
        public let areaInImage: CGRect
        public let gridOriginInImage: CGPoint
        public let tilePitch: CGFloat
        public let gridSize: GridPoint
        public let runesOnOddTiles: Bool
        public let tiles: [Tile]
        public let rejectedTiles: [RejectedTile]
        public let traceableTileCount: Int
        public let lanes: [Lane]
        public let laneTraceDiagnostics: [String]
        public let topology: Topology?
        public let failureReason: String?

        public var succeeded: Bool { failureReason == nil }
        public var readableTileCount: Int { tiles.filter(\.isReadable).count }
        public var occupiedTileCount: Int { tiles.count }

        public var summaryLines: [String] {
            let trackCounts = Dictionary(grouping: tiles.compactMap(\.trackColor), by: { $0 })
                .map { "\($0.key):\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            let runeCounts = Dictionary(grouping: tiles.compactMap(\.runeLabel), by: { $0 })
                .map { "\($0.key):\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            let intersectionCount = tiles.filter(\.isIntersection).count
            let weakTrackTiles = tiles
                .filter { ($0.trackColorConfidence ?? 0) < 0.84 }
                .map { "\($0.point):c\($0.trackColor.map(String.init) ?? "?")/\(String(format: "%.2f", $0.trackColorConfidence ?? 0))/bg\($0.backgroundCount)/n\($0.neighboursExist.map { $0 ? "1" : "0" }.joined())\($0.isIntersection ? "/i" : "")" }
            let intersectionTiles = tiles
                .filter(\.isIntersection)
                .map { "\($0.point):c\($0.trackColor.map(String.init) ?? "?")/\(String(format: "%.2f", $0.trackColorConfidence ?? 0))/n\($0.neighboursExist.map { $0 ? "1" : "0" }.joined())/\($0.intersectionMatches == true ? "match" : "nomatch")" }
            let globalIntersectionPoints = Set(tiles.filter(\.isIntersection).map(\.point))
            let selectedIntersectionPoints = Set(lanes.flatMap { lane in
                lane.tiles.filter(\.isIntersection).map(\.point)
            })
            let pairedIntersectionPoints = Set(inferIntersectionPoints(from: lanes))
            let missedIntersectionPoints = globalIntersectionPoints.subtracting(pairedIntersectionPoints)
            let extraSelectedIntersectionPoints = selectedIntersectionPoints.subtracting(globalIntersectionPoints)
            var lines = [
                "grid:",
                "  origin=(\(String(format: "%.1f", gridOriginInImage.x)), \(String(format: "%.1f", gridOriginInImage.y))) pitch=\(String(format: "%.2f", tilePitch)) size=\(gridSize.x)x\(gridSize.y) parity=\(runesOnOddTiles ? "odd" : "even")",
                "tiles:",
                "  occupied=\(occupiedTileCount) readable=\(readableTileCount) traceable=\(traceableTileCount)",
                "  lanes=\(lanes.count) lengths=\(lanes.map(\.tiles.count))",
                "counts:",
                "  runes={\(runeCounts)}",
                "  tracks={\(trackCounts)} intersections=\(intersectionCount)",
            ]
            if !weakTrackTiles.isEmpty {
                lines.append("weakTrackTiles:")
                lines.append(contentsOf: wrappedDiagnosticLines(weakTrackTiles))
            }
            if !intersectionTiles.isEmpty {
                lines.append("intersectionTiles:")
                lines.append(contentsOf: wrappedDiagnosticLines(intersectionTiles))
            }
            if !rejectedTiles.isEmpty {
                let acceptedPoints = Set(tiles.map(\.point))
                let nearRejected = rejectedTiles.filter { isNearAcceptedTile($0.point, acceptedPoints: acceptedPoints) }
                let hiddenCount = rejectedTiles.count - nearRejected.count
                lines.append("rejectedTiles:")
                lines.append("  nearAccepted=\(nearRejected.count) hidden=\(hiddenCount)")
                if !nearRejected.isEmpty {
                    lines.append(contentsOf: wrappedDiagnosticLines(nearRejected.map(formatRejectedTile)))
                }
            }
            if !lanes.isEmpty {
                lines.append(
                    "selectedIntersections:"
                )
                lines.append(
                    "  all=\(formatPoints(selectedIntersectionPoints))"
                )
                lines.append(
                    "  paired=\(formatPoints(pairedIntersectionPoints))"
                )
                lines.append(
                    "  missed=\(formatPoints(missedIntersectionPoints)) extra=\(formatPoints(extraSelectedIntersectionPoints))"
                )
            }
            if let topology {
                lines.append("topology:")
                lines.append("  \(topology.description)")
            }
            if !laneTraceDiagnostics.isEmpty {
                lines.append("laneAttempts:")
                lines.append(contentsOf: wrappedDiagnosticLines(laneTraceDiagnostics, entriesPerLine: 4))
            }
            if let failureReason {
                lines.append("failure:")
                lines.append("  \(failureReason)")
            }
            return lines
        }

        private func inferIntersectionPoints(from lanes: [Lane]) -> [GridPoint] {
            let lanePoints = lanes.map { lane in
                Set(lane.tiles.map(\.point))
            }
            var points = Set<GridPoint>()
            for laneIndex in lanePoints.indices {
                for otherLaneIndex in lanePoints.indices where otherLaneIndex > laneIndex {
                    points.formUnion(lanePoints[laneIndex].intersection(lanePoints[otherLaneIndex]))
                }
            }
            return Array(points)
        }

        private func formatPoints(_ points: Set<GridPoint>) -> String {
            let sorted = points.sorted {
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.x < $1.x
            }
            return "[" + sorted.map(\.description).joined(separator: ",") + "]"
        }

        private func wrappedDiagnosticLines(_ entries: [String], entriesPerLine: Int = 5) -> [String] {
            stride(from: 0, to: entries.count, by: entriesPerLine).map { start in
                let end = min(start + entriesPerLine, entries.count)
                return "  " + entries[start..<end].joined(separator: " ")
            }
        }

        private func isNearAcceptedTile(_ point: GridPoint, acceptedPoints: Set<GridPoint>) -> Bool {
            let directions = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            return directions.contains { direction in
                acceptedPoints.contains(GridPoint(x: point.x + direction.0, y: point.y + direction.1))
            }
        }

        private func formatRejectedTile(_ rejected: RejectedTile) -> String {
            let rune = rejected.runeLabel.map {
                "\($0)/\(String(format: "%.2f", rejected.runeConfidence ?? 0))"
            } ?? "nil"
            let track = rejected.trackColor.map {
                "\($0)/\(String(format: "%.2f", rejected.trackColorConfidence ?? 0))"
            } ?? "?/0.00"
            return "\(rejected.point):\(rejected.reason)/rune=\(rune)/vis=\(String(format: "%.2f", rejected.visualContentFraction)),\(String(format: "%.2f", rejected.visualInkFraction)),\(String(format: "%.4f", rejected.visualVariance))/bg\(rejected.backgroundCount)/n\(rejected.neighboursExist.map { $0 ? "1" : "0" }.joined())/c\(track)"
        }
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let data: [UInt8]

        func sample(x: Int, y: Int) -> (r: Float, g: Float, b: Float)? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let i = (y * width + x) * 4
            guard i + 2 < data.count else { return nil }
            return (Float(data[i]), Float(data[i + 1]), Float(data[i + 2]))
        }
    }

    private struct CandidateOrigin {
        let anchor: CGPoint
        let gridOrigin: CGPoint
        let runesOnOddTiles: Bool
        let score: Int
    }

    fileprivate struct RunePresence {
        let label: String
        let confidence: Float
        let margin: Float
    }

    private struct RuneLikePatchStats {
        let contentFraction: Float
        let inkFraction: Float
        let variance: Float

        var isRuneLike: Bool {
            contentFraction >= 0.30
                && inkFraction >= 0.08
                && variance >= 0.003
        }
    }

    private struct LaneTraceResult {
        let lanes: [Lane]
        let diagnostics: [String]
    }

    private struct LaneCandidate {
        let lane: Lane
        let start: GridPoint
        let initialDirection: Int
    }

    private struct LaneCandidateGroup {
        let color: Int
        let candidates: [LaneCandidate]
    }

    private struct LayoutCandidate {
        let metadata: CelticKnotLayoutMetadata
        let expectedLengths: [Int]
    }

    private struct TileReadGrid {
        let grid: [[Tile?]]
        let rejected: [RejectedTile]
    }

    private struct OriginAlignmentScore {
        let acceptedCount: Int
        let confidenceSum: Float
        let minConfidence: Float
        let visualPatchCount: Int

        var averageConfidence: Float {
            acceptedCount > 0 ? confidenceSum / Float(acceptedCount) : 0
        }
    }

    private static let maxGridSize = GridPoint(x: 24, y: 13)
    private static let minReadableTiles = 20
    private static let minLaneLength = 10
    private static let minTopologyConfidence: Float = 0.90
    private static let maxGraphCandidatesPerColor = 24
    private static let maxGraphCyclesPerSeed = 16

    private static let directions: [(dx: Int, dy: Int)] = [
        (-1, -1), (1, -1), (1, 1), (-1, 1),
    ]

    private static let expectedLaneLengths = Set(
        CelticKnotLayoutType.allCases.flatMap { CelticKnotLayoutMetadata.metadata(for: $0).laneLengths }
    )

    private static let expectedTrackCounts = Set(
        CelticKnotLayoutType.allCases.map { CelticKnotLayoutMetadata.metadata(for: $0).trackCount }
    )

    private static let expectedVisibleTileCounts = Set(
        CelticKnotLayoutType.allCases.map {
            let metadata = CelticKnotLayoutMetadata.metadata(for: $0)
            return metadata.laneLengths.reduce(0, +) - metadata.intersectionCount
        }
    )

    public func analyze(in image: CGImage, puzzleBounds: CGRect, runeArea: CGRect) -> Analysis {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let baseArea = runeArea.intersection(imageBounds).integral
        let pitch = estimateTilePitch(area: baseArea, puzzleBounds: puzzleBounds)
        let fullArea = CGRect(
            x: baseArea.minX,
            y: baseArea.minY,
            width: baseArea.width,
            height: min(puzzleBounds.maxY, baseArea.maxY + pitch) - baseArea.minY
        ).intersection(imageBounds).integral
        let trimX = min(fullArea.width * 0.16, pitch * (46.0 / 24.0))
        let trimY = min(fullArea.height * 0.06, pitch * (9.0 / 24.0))
        let area = fullArea.insetBy(dx: trimX, dy: trimY).intersection(imageBounds).integral
        guard area.width > 60, area.height > 60 else {
            return failed(area: area, reason: "rune area too small")
        }
        guard let crop = image.cropping(to: area),
              let buffer = Self.makePixelBuffer(from: crop)
        else {
            return failed(area: area, reason: "could not read rune area pixels")
        }

        guard pitch >= 8 else {
            return failed(area: area, reason: "estimated pitch too small: \(pitch)")
        }
        guard let coarseOrigin = findOrigin(in: buffer, area: area, pitch: pitch) else {
            return failed(area: area, reason: "grid anchor not found")
        }
        let origin = coarseOrigin

        func analyzeGrid(using origin: CandidateOrigin) -> Analysis {
            let gridSize = GridPoint(
                x: min(Self.maxGridSize.x, max(0, Int(floor((area.width - origin.gridOrigin.x) / pitch)))),
                y: min(Self.maxGridSize.y, max(0, Int(floor((area.height - origin.gridOrigin.y) / pitch))))
            )
            guard gridSize.x >= 6, gridSize.y >= 6 else {
                return failed(area: area, reason: "grid too small: \(gridSize.x)x\(gridSize.y)")
            }

            let primaryTileGrid = readTiles(
                image: image,
                buffer: buffer,
                area: area,
                gridOrigin: origin.gridOrigin,
                pitch: pitch,
                gridSize: gridSize,
                runesOnOddTiles: origin.runesOnOddTiles
            )
            let alternateTileGrid = readTiles(
                image: image,
                buffer: buffer,
                area: area,
                gridOrigin: origin.gridOrigin,
                pitch: pitch,
                gridSize: gridSize,
                runesOnOddTiles: !origin.runesOnOddTiles
            )
            let primaryTiles = primaryTileGrid.grid.flatMap { $0 }.compactMap { $0 }
            let alternateTiles = alternateTileGrid.grid.flatMap { $0 }.compactMap { $0 }
            let useAlternateParity = alternateTiles.count > primaryTiles.count
            let tileGrid = useAlternateParity ? alternateTileGrid : primaryTileGrid
            let rejectedTiles = useAlternateParity ? alternateTileGrid.rejected : primaryTileGrid.rejected
            let runesOnOddTiles = useAlternateParity ? !origin.runesOnOddTiles : origin.runesOnOddTiles
            let tiles = tileGrid.grid.flatMap { $0 }.compactMap { $0 }
            let traceableTileGrid = traceableGrid(
                from: tileGrid.grid,
                gridSize: gridSize,
                strictIntersections: false
            )
            var traceableTileCount = traceableTileGrid.flatMap { $0 }.compactMap { $0 }.count
            guard tiles.count >= Self.minReadableTiles else {
                return Analysis(
                    areaInImage: area,
                    gridOriginInImage: CGPoint(x: area.minX + origin.gridOrigin.x, y: area.minY + origin.gridOrigin.y),
                    tilePitch: pitch,
                    gridSize: gridSize,
                    runesOnOddTiles: runesOnOddTiles,
                    tiles: tiles,
                    rejectedTiles: rejectedTiles,
                    traceableTileCount: traceableTileCount,
                    lanes: [],
                    laneTraceDiagnostics: [
                        "parity primary=\(primaryTiles.count) alternate=\(alternateTiles.count)",
                    ],
                    topology: nil,
                    failureReason: "not enough rune-like tiles: \(tiles.count)"
                )
            }

            var traceResult = traceLanes(
                tileGrid: traceableTileGrid,
                gridSize: gridSize,
                visibleTileCount: tiles.count
            )
            if traceResult.lanes.isEmpty {
                let strictTraceableTileGrid = traceableGrid(
                    from: tileGrid.grid,
                    gridSize: gridSize,
                    strictIntersections: true
                )
                let strictTraceResult = traceLanes(
                    tileGrid: strictTraceableTileGrid,
                    gridSize: gridSize,
                    visibleTileCount: tiles.count
                )
                if !strictTraceResult.lanes.isEmpty {
                    traceableTileCount = strictTraceableTileGrid.flatMap { $0 }.compactMap { $0 }.count
                    traceResult = LaneTraceResult(
                        lanes: strictTraceResult.lanes,
                        diagnostics: traceResult.diagnostics + ["strictIntersectionsFallback"] + strictTraceResult.diagnostics
                    )
                }
            }
            let lanes = traceResult.lanes
            let topology = inferTopology(from: lanes, visibleTileCount: tiles.count)
            let failureReason: String?
            if lanes.count < 3 {
                failureReason = "not enough lanes: \(lanes.count)"
            } else if let topology, topology.confidence < Self.minTopologyConfidence {
                failureReason = "topology confidence too low: \(String(format: "%.2f", topology.confidence))"
            } else if topology?.candidate == nil {
                failureReason = "layout topology not recognised"
            } else {
                failureReason = nil
            }
            return Analysis(
                areaInImage: area,
                gridOriginInImage: CGPoint(x: area.minX + origin.gridOrigin.x, y: area.minY + origin.gridOrigin.y),
                tilePitch: pitch,
                gridSize: gridSize,
                runesOnOddTiles: runesOnOddTiles,
                tiles: tiles,
                rejectedTiles: rejectedTiles,
                traceableTileCount: traceableTileCount,
                lanes: lanes,
                laneTraceDiagnostics: [
                    "parity primary=\(primaryTiles.count) alternate=\(alternateTiles.count)",
                ] + traceResult.diagnostics,
                topology: topology,
                failureReason: failureReason
            )
        }

        var analysis = analyzeGrid(using: origin)
        if analysis.failureReason != nil && analysis.lanes.count < 3 {
            let rescueOrigins = candidateOriginsForRescue(
                origin,
                image: image,
                area: area,
                buffer: buffer,
                pitch: pitch
            )
            for shiftedOrigin in rescueOrigins {
                let shiftedAnalysis = analyzeGrid(using: shiftedOrigin)
                if shiftedAnalysis.failureReason == nil ||
                    (analysis.failureReason != nil && shiftedAnalysis.occupiedTileCount > analysis.occupiedTileCount) {
                    analysis = shiftedAnalysis
                }
                if analysis.failureReason == nil {
                    break
                }
            }
        }
        return analysis
    }

    public func makeLayout(
        from analysis: Analysis,
        puzzleBounds: CGRect,
        layoutType: CelticKnotLayoutType
    ) -> CelticKnotLayout? {
        guard analysis.succeeded,
              analysis.topology?.candidate == layoutType,
              !analysis.lanes.isEmpty
        else { return nil }

        let metadata = CelticKnotLayoutMetadata.metadata(for: layoutType)
        let lanes = analysis.lanes.sorted { lhs, rhs in
            Self.trackOrderRank(lhs.color) < Self.trackOrderRank(rhs.color)
        }
        guard lanes.count == metadata.trackCount else { return nil }

        var tracks: [[RuneSlot]] = lanes.enumerated().map { trackIndex, lane in
            lane.tiles.enumerated().map { slotIndex, tile in
                RuneSlot(
                    x: (tile.centerInImage.x - puzzleBounds.minX) / puzzleBounds.width,
                    y: (tile.centerInImage.y - puzzleBounds.minY) / puzzleBounds.height,
                    trackIndex: trackIndex,
                    slotIndex: slotIndex,
                    isOnTop: tile.trackColor == lane.color
                )
            }
        }

        var intersections: [(trackA: Int, slotA: Int, trackB: Int, slotB: Int)] = []
        var seen = Set<String>()

        for (laneIndex, lane) in lanes.enumerated() {
            for (slotIndex, tile) in lane.tiles.enumerated() {
                for otherLaneIndex in lanes.indices where otherLaneIndex > laneIndex {
                    guard let otherSlotIndex = lanes[otherLaneIndex].tiles.firstIndex(where: { $0.point == tile.point }) else {
                        continue
                    }

                    let key = "\(laneIndex):\(slotIndex)-\(otherLaneIndex):\(otherSlotIndex)"
                    guard seen.insert(key).inserted else { continue }

                    intersections.append((laneIndex, slotIndex, otherLaneIndex, otherSlotIndex))

                    if let visibleColor = tile.trackColor {
                        tracks[laneIndex][slotIndex].isOnTop = visibleColor == lane.color
                        tracks[otherLaneIndex][otherSlotIndex].isOnTop = visibleColor == lanes[otherLaneIndex].color
                    }
                }
            }
        }

        return CelticKnotLayout(
            type: layoutType,
            tracks: tracks,
            intersections: intersections,
            estimatedRuneDiameter: metadata.estimatedRuneDiameter,
            clockwiseRotationSigns: lanes.map { clockwiseRotationSign(for: $0) }
        )
    }

    private func clockwiseRotationSign(for lane: Lane) -> Int {
        guard lane.tiles.count >= 3 else { return 1 }

        let signedArea = lane.tiles.indices.reduce(CGFloat(0)) { partial, index in
            let current = lane.tiles[index].centerInImage
            let next = lane.tiles[(index + 1) % lane.tiles.count].centerInImage
            return partial + current.x * next.y - current.y * next.x
        }

        // In screen coordinates y increases downward, so positive shoelace
        // area means the stored slot order proceeds clockwise on screen.
        return signedArea >= 0 ? 1 : -1
    }

    private func failed(area: CGRect, reason: String) -> Analysis {
        Analysis(
            areaInImage: area,
            gridOriginInImage: area.origin,
            tilePitch: 0,
            gridSize: GridPoint(x: 0, y: 0),
            runesOnOddTiles: false,
            tiles: [],
            rejectedTiles: [],
            traceableTileCount: 0,
            lanes: [],
            laneTraceDiagnostics: [],
            topology: nil,
            failureReason: reason
        )
    }

    private static func trackOrderRank(_ color: Int) -> Int {
        // ClueTrainer lane ids: 3=yellow/gold, 2=dark blue, 0=blue, 4=grey, 1=red.
        // This rank preserves the existing solver/arrow convention for the
        // common three-track Celtic knots while still supporting four-track shapes.
        switch color {
        case 3: return 0
        case 2: return 1
        case 0: return 2
        case 4: return 3
        case 1: return 4
        default: return 100 + color
        }
    }

    private func estimateTilePitch(area: CGRect, puzzleBounds: CGRect) -> CGFloat {
        // ClueTrainer's knot lattice uses a 24 px pitch at the standard
        // ~505 px modal width. Keep pitch tied to modal scale, not to the
        // number of diagnostic columns we choose to draw across the parchment.
        let modalScaledPitch = puzzleBounds.width / 505.0 * 24.0
        let verticalSanityPitch = puzzleBounds.height / 14.4
        let pitch = min(max(modalScaledPitch, 18), max(verticalSanityPitch, 18) * 1.15)
        return max(12, pitch.rounded())
    }

    private func findOrigin(in buffer: PixelBuffer, area: CGRect, pitch: CGFloat) -> CandidateOrigin? {
        let scanColumns = [0.26, 0.30, 0.34, 0.38, 0.42].map {
            min(buffer.width - 2, max(1, Int(round(CGFloat(buffer.width) * CGFloat($0)))))
        }
        let maxY = min(buffer.height - Int(ceil(pitch)) - 2, Int(round(pitch * 8.5)))
        var best: CandidateOrigin?

        for x in scanColumns {
            var aboveWasBackground = true
            for y in 2..<max(3, maxY) {
                let isBg = isBackground(at: x, y: y, in: buffer)
                let belowY = min(buffer.height - 1, y + Int(round(pitch)))
                if !isBg, aboveWasBackground, !isBackground(at: x, y: belowY, in: buffer) {
                    let anchor = climbToBorderTip(from: CGPoint(x: x, y: y), in: buffer)
                    let originOfTile = CGPoint(
                        x: anchor.x - pitch * (11.0 / 24.0),
                        y: anchor.y + pitch * (9.0 / 24.0)
                    )
                    let tileIndexX = Int(floor(originOfTile.x / pitch))
                    let tileIndexY = Int(floor(originOfTile.y / pitch))
                    let gridOrigin = CGPoint(
                        x: originOfTile.x - CGFloat(tileIndexX) * pitch,
                        y: originOfTile.y - CGFloat(tileIndexY) * pitch
                    )
                    let runesOnOddTiles = (tileIndexX + tileIndexY).isMultiple(of: 2) == false
                    let candidate = CandidateOrigin(
                        anchor: anchor,
                        gridOrigin: gridOrigin,
                        runesOnOddTiles: runesOnOddTiles,
                        score: originScore(
                            gridOrigin: gridOrigin,
                            pitch: pitch,
                            buffer: buffer,
                            runesOnOddTiles: runesOnOddTiles
                        )
                    )
                    if best == nil || candidate.score > best!.score {
                        best = candidate
                    }
                    break
                }
                aboveWasBackground = isBg
            }
        }

        return best
    }

    private func refineOrigin(_ origin: CandidateOrigin, in buffer: PixelBuffer, pitch: CGFloat) -> CandidateOrigin {
        var best = origin
        let radius = max(2, Int(round(pitch * 0.35)))

        for dy in -radius...radius {
            for dx in -radius...radius {
                let gridOrigin = CGPoint(
                    x: origin.gridOrigin.x + CGFloat(dx),
                    y: origin.gridOrigin.y + CGFloat(dy)
                )
                let score = originScore(
                    gridOrigin: gridOrigin,
                    pitch: pitch,
                    buffer: buffer,
                    runesOnOddTiles: origin.runesOnOddTiles
                )
                let candidate = CandidateOrigin(
                    anchor: origin.anchor,
                    gridOrigin: gridOrigin,
                    runesOnOddTiles: origin.runesOnOddTiles,
                    score: score
                )
                if candidate.score > best.score ||
                    (candidate.score == best.score && candidate.gridOrigin.y > best.gridOrigin.y) ||
                    (candidate.score == best.score && candidate.gridOrigin.y == best.gridOrigin.y && candidate.gridOrigin.x > best.gridOrigin.x) {
                    best = candidate
                }
            }
        }

        return best
    }

    private func candidateOriginsForRescue(
        _ origin: CandidateOrigin,
        image: CGImage,
        area: CGRect,
        buffer: PixelBuffer,
        pitch: CGFloat
    ) -> [CandidateOrigin] {
        var candidates: [CandidateOrigin] = []
        var seen = Set<String>()

        func appendCandidate(dx: Int, dy: Int) {
            let gridOrigin = CGPoint(
                x: origin.gridOrigin.x + CGFloat(dx),
                y: origin.gridOrigin.y + CGFloat(dy)
            )
            let key = "\(Int(round(gridOrigin.x))):\(Int(round(gridOrigin.y)))"
            guard seen.insert(key).inserted else { return }
            candidates.append(
                CandidateOrigin(
                    anchor: origin.anchor,
                    gridOrigin: gridOrigin,
                    runesOnOddTiles: origin.runesOnOddTiles,
                    score: originScore(
                        gridOrigin: gridOrigin,
                        pitch: pitch,
                        buffer: buffer,
                        runesOnOddTiles: origin.runesOnOddTiles
                    )
                )
            )
        }

        appendCandidate(dx: 0, dy: 0)
        appendCandidate(dx: Int(round(pitch / 6)), dy: Int(round(pitch / 8)))
        appendCandidate(dx: Int(round(pitch / 6)), dy: Int(round(pitch / 4)))
        appendCandidate(dx: Int(round(pitch / 4)), dy: Int(round(pitch / 12)))
        appendCandidate(dx: Int(round(pitch / 4)), dy: Int(round(pitch / 8)))
        appendCandidate(dx: Int(round(pitch / 4)), dy: Int(round(pitch / 6)))
        appendCandidate(dx: Int(round(pitch / 3)), dy: Int(round(pitch / 12)))
        appendCandidate(dx: Int(round(pitch / 3)), dy: Int(round(pitch / 8)))
        appendCandidate(dx: Int(round(pitch / 3)), dy: Int(round(pitch / 6)))

        let scored = candidates.map { candidate in
            (
                origin: candidate,
                score: originAlignmentScore(
                    image: image,
                    area: area,
                    gridOrigin: candidate.gridOrigin,
                    pitch: pitch,
                    buffer: buffer,
                    runesOnOddTiles: candidate.runesOnOddTiles
                )
            )
        }

        return scored
            .sorted { lhs, rhs in
                originAlignmentScoreIsBetter(lhs.score, than: rhs.score)
            }
            .map(\.origin)
    }

    private func originAlignmentScore(
        image: CGImage,
        area: CGRect,
        gridOrigin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer,
        runesOnOddTiles: Bool
    ) -> OriginAlignmentScore {
        let gridSize = GridPoint(
            x: min(Self.maxGridSize.x, max(0, Int(floor((area.width - gridOrigin.x) / pitch)))),
            y: min(Self.maxGridSize.y, max(0, Int(floor((area.height - gridOrigin.y) / pitch))))
        )

        var acceptedCount = 0
        var confidenceSum: Float = 0
        var minConfidence = Float.greatestFiniteMagnitude
        var visualPatchCount = 0

        for y in 0..<gridSize.y {
            for x in 0..<gridSize.x where ((x + y) % 2 == 1) == runesOnOddTiles {
                let tileOrigin = CGPoint(
                    x: gridOrigin.x + CGFloat(x) * pitch,
                    y: gridOrigin.y + CGFloat(y) * pitch
                )
                guard tileOrigin.x >= -pitch,
                      tileOrigin.x < CGFloat(buffer.width),
                      tileOrigin.y >= -pitch,
                      tileOrigin.y < CGFloat(buffer.height)
                else { continue }

                if isRuneLikeCenterPatch(origin: tileOrigin, pitch: pitch, buffer: buffer) {
                    visualPatchCount += 1
                }

                guard let rune = identifyRune(
                    image: image,
                    area: area,
                    origin: tileOrigin,
                    pitch: pitch
                ) else {
                    continue
                }
                acceptedCount += 1
                confidenceSum += rune.confidence
                minConfidence = min(minConfidence, rune.confidence)
            }
        }

        return OriginAlignmentScore(
            acceptedCount: acceptedCount,
            confidenceSum: confidenceSum,
            minConfidence: acceptedCount > 0 ? minConfidence : 0,
            visualPatchCount: visualPatchCount
        )
    }

    private func originAlignmentScoreIsBetter(
        _ lhs: OriginAlignmentScore,
        than rhs: OriginAlignmentScore
    ) -> Bool {
        let lhsDistance = expectedVisibleTileDistance(lhs.acceptedCount)
        let rhsDistance = expectedVisibleTileDistance(rhs.acceptedCount)
        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }
        if lhs.acceptedCount != rhs.acceptedCount {
            return lhs.acceptedCount > rhs.acceptedCount
        }
        let averageDelta = lhs.averageConfidence - rhs.averageConfidence
        if abs(averageDelta) > 0.001 {
            return averageDelta > 0
        }
        let minDelta = lhs.minConfidence - rhs.minConfidence
        if abs(minDelta) > 0.001 {
            return minDelta > 0
        }
        return lhs.visualPatchCount > rhs.visualPatchCount
    }

    private func expectedVisibleTileDistance(_ count: Int) -> Int {
        Self.expectedVisibleTileCounts.map { abs($0 - count) }.min() ?? 0
    }

    private func climbToBorderTip(from start: CGPoint, in buffer: PixelBuffer) -> CGPoint {
        var p = start
        while p.y > 0 {
            let x = Int(round(p.x))
            let y = Int(round(p.y))
            if !isBackground(at: x - 1, y: y - 1, in: buffer) {
                p.x -= 1
                p.y -= 1
            } else if !isBackground(at: x + 1, y: y - 1, in: buffer) {
                p.x += 1
                p.y -= 1
            } else {
                break
            }
        }
        if !isBackground(at: Int(round(p.x)) - 1, y: Int(round(p.y)), in: buffer) {
            p.x -= 1
        }
        return p
    }

    private func originScore(
        gridOrigin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer,
        runesOnOddTiles: Bool
    ) -> Int {
        var score = 0
        for y in 0..<Self.maxGridSize.y {
            for x in 0..<Self.maxGridSize.x where ((x + y) % 2 == 1) == runesOnOddTiles {
                let tileOrigin = CGPoint(
                    x: gridOrigin.x + CGFloat(x) * pitch,
                    y: gridOrigin.y + CGFloat(y) * pitch
                )
                guard tileOrigin.x >= -pitch,
                      tileOrigin.x < CGFloat(buffer.width),
                      tileOrigin.y >= -pitch,
                      tileOrigin.y < CGFloat(buffer.height)
                else { continue }
                if isRuneLikeCenterPatch(origin: tileOrigin, pitch: pitch, buffer: buffer) {
                    score += 1
                }
            }
        }
        return score
    }

    private func readTiles(
        image: CGImage,
        buffer: PixelBuffer,
        area: CGRect,
        gridOrigin: CGPoint,
        pitch: CGFloat,
        gridSize: GridPoint,
        runesOnOddTiles: Bool
    ) -> TileReadGrid {
        var grid = Array(
            repeating: Array<Tile?>(repeating: nil, count: gridSize.x),
            count: gridSize.y
        )
        var rejected: [RejectedTile] = []

        for y in 0..<gridSize.y {
            for x in 0..<gridSize.x {
                guard ((x + y) % 2 == 1) == runesOnOddTiles else { continue }
                let origin = CGPoint(
                    x: gridOrigin.x + CGFloat(x) * pitch,
                    y: gridOrigin.y + CGFloat(y) * pitch
                )
                let result = readTile(
                    image: image,
                    point: GridPoint(x: x, y: y),
                    origin: origin,
                    area: area,
                    pitch: pitch,
                    buffer: buffer
                )
                if let tile = result.tile {
                    grid[y][x] = tile
                } else if let rejectedTile = result.rejected {
                    rejected.append(rejectedTile)
                }
            }
        }
        return TileReadGrid(grid: annotateConnectivity(tileGrid: grid, gridSize: gridSize), rejected: rejected)
    }

    private func readTile(
        image: CGImage,
        point: GridPoint,
        origin: CGPoint,
        area: CGRect,
        pitch: CGFloat,
        buffer: PixelBuffer
    ) -> (tile: Tile?, rejected: RejectedTile?) {
        let cornerSamples = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: pitch - 1, y: 0),
            CGPoint(x: pitch, y: pitch),
            CGPoint(x: 0, y: pitch),
        ]
        let background = cornerSamples.map {
            isBackground(at: Int(round(origin.x + $0.x)), y: Int(round(origin.y + $0.y)), in: buffer)
        }
        let backgroundCount = background.filter { $0 }.count
        let rune = identifyRune(
            image: image,
            area: area,
            origin: origin,
            pitch: pitch
        )
        let visualStats = runeLikeCenterPatchStats(origin: origin, pitch: pitch, buffer: buffer)
        let trackColorMatch = getTrackColor(samples: trackColorSamples(origin: origin, pitch: pitch, buffer: buffer))

        let neighbours = background.map { !$0 }
        guard let rune = rune ?? (visualStats.isRuneLike ? RunePresence(label: "visual", confidence: 0, margin: 0) : nil) else {
            return (
                nil,
                RejectedTile(
                    point: point,
                    backgroundCount: backgroundCount,
                    neighboursExist: neighbours,
                    runeLabel: nil,
                    runeConfidence: nil,
                    visualContentFraction: visualStats.contentFraction,
                    visualInkFraction: visualStats.inkFraction,
                    visualVariance: visualStats.variance,
                    trackColor: trackColorMatch?.id,
                    trackColorConfidence: trackColorMatch?.certainty,
                    reason: "no-rune-signal"
                )
            )
        }

        let intersectionMarker = classifyIntersectionMarker(samples: intersectionSamples(origin: origin, pitch: pitch, buffer: buffer))
        let isIntersection = backgroundCount < 2 && intersectionMarker != nil
        let intersectionMatches = isIntersection ? intersectionMarker : nil
        let isTraceable = backgroundCount <= 2 || trackColorMatch != nil

        let center = CGPoint(
            x: area.minX + origin.x + pitch * 0.5,
            y: area.minY + origin.y + pitch * (13.0 / 24.0)
        )

        return (
            Tile(
                point: point,
                originInImage: CGPoint(x: area.minX + origin.x, y: area.minY + origin.y),
                centerInImage: center,
                trackColor: trackColorMatch?.id,
                neighboursExist: neighbours,
                isIntersection: isIntersection,
                intersectionMatches: intersectionMatches,
                runeLabel: rune.label,
                runeConfidence: rune.confidence,
                isTraceable: isTraceable,
                trackColorConfidence: trackColorMatch?.certainty,
                backgroundCount: backgroundCount
            ),
            nil
        )
    }

    private func annotateConnectivity(tileGrid: [[Tile?]], gridSize: GridPoint) -> [[Tile?]] {
        var pruned = tileGrid

        for y in 0..<gridSize.y {
            for x in 0..<gridSize.x {
                guard tileGrid[y][x] != nil else { continue }
                let neighbourCount = Self.directions.filter { direction in
                    let point = GridPoint(x: x + direction.dx, y: y + direction.dy)
                    return point.y >= 0
                        && point.y < gridSize.y
                        && point.x >= 0
                        && point.x < gridSize.x
                        && tileGrid[point.y][point.x] != nil
                }.count

                // UI arrow controls can satisfy the visual rune patch test. At
                // this stage the visual-only fallback is diagnostic evidence,
                // not a trusted rune; real tiles should be confirmed by KNN.
                if neighbourCount == 0 || tileGrid[y][x]?.runeLabel == "visual" {
                    pruned[y][x] = nil
                }
            }
        }

        var annotated = pruned
        for y in 0..<gridSize.y {
            for x in 0..<gridSize.x {
                guard let tile = pruned[y][x] else { continue }
                let latticeNeighbours = Self.directions.map { direction -> Bool in
                    let point = GridPoint(x: x + direction.dx, y: y + direction.dy)
                    return point.y >= 0
                        && point.y < gridSize.y
                        && point.x >= 0
                        && point.x < gridSize.x
                        && pruned[point.y][point.x] != nil
                }
                annotated[y][x] = Tile(
                    point: tile.point,
                    originInImage: tile.originInImage,
                    centerInImage: tile.centerInImage,
                    trackColor: tile.trackColor,
                    neighboursExist: tile.neighboursExist.enumerated().map { index, exists in
                        exists && latticeNeighbours[index]
                    },
                    isIntersection: tile.isIntersection,
                    intersectionMatches: tile.isIntersection ? tile.intersectionMatches : nil,
                    runeLabel: tile.runeLabel,
                    runeConfidence: tile.runeConfidence,
                    isTraceable: tile.isTraceable,
                    trackColorConfidence: tile.trackColorConfidence,
                    backgroundCount: tile.backgroundCount
                )
            }
        }

        return annotated
    }

    private func traceableGrid(
        from tileGrid: [[Tile?]],
        gridSize: GridPoint,
        strictIntersections: Bool
    ) -> [[Tile?]] {
        let filtered = tileGrid.map { row in
            row.map { tile -> Tile? in
                guard let tile, tile.isTraceable else { return nil }
                return tile
            }
        }

        var annotated = filtered
        for y in 0..<gridSize.y {
            for x in 0..<gridSize.x {
                guard let tile = filtered[y][x] else { continue }
                let latticeNeighbours = Self.directions.map { direction -> Bool in
                    let point = GridPoint(x: x + direction.dx, y: y + direction.dy)
                    return point.y >= 0
                        && point.y < gridSize.y
                        && point.x >= 0
                        && point.x < gridSize.x
                        && filtered[point.y][point.x] != nil
                }
                let structurallyIntersection = tile.isIntersection
                    && (!strictIntersections || latticeNeighbours.filter { $0 }.count >= 3)
                annotated[y][x] = Tile(
                    point: tile.point,
                    originInImage: tile.originInImage,
                    centerInImage: tile.centerInImage,
                    trackColor: tile.trackColor,
                    neighboursExist: tile.neighboursExist.enumerated().map { index, exists in
                        exists && latticeNeighbours[index]
                    },
                    isIntersection: structurallyIntersection,
                    intersectionMatches: structurallyIntersection ? tile.intersectionMatches : nil,
                    runeLabel: tile.runeLabel,
                    runeConfidence: tile.runeConfidence,
                    isTraceable: tile.isTraceable,
                    trackColorConfidence: tile.trackColorConfidence,
                    backgroundCount: tile.backgroundCount
                )
            }
        }

        return annotated
    }

    private func traceLanes(
        tileGrid: [[Tile?]],
        gridSize: GridPoint,
        visibleTileCount: Int
    ) -> LaneTraceResult {
        var diagnostics: [String] = []
        let startTiles = tileGrid.flatMap { $0 }.compactMap { $0 }.filter { tile in
            tile.trackColor != nil && !tile.isIntersection
        }
        let colors = Array(Set(startTiles.compactMap(\.trackColor))).sorted()

        let layoutCandidates = layoutCandidates(forVisibleTileCount: visibleTileCount)
        let graphLanes = traceSameColourGraphLanes(
            tileGrid: tileGrid,
            gridSize: gridSize,
            layoutCandidates: layoutCandidates,
            visibleTileCount: visibleTileCount,
            diagnostics: &diagnostics
        )
        if !graphLanes.isEmpty {
            return LaneTraceResult(lanes: graphLanes, diagnostics: diagnostics)
        }

        let ctLanes = traceClueTrainerLanes(startTiles: startTiles, tileGrid: tileGrid, gridSize: gridSize)
        if ctLanes.count >= 3 {
            let topology = inferTopology(from: ctLanes, visibleTileCount: visibleTileCount)
            let confidence = topology?.confidence ?? 0
            diagnostics.append("ctSelected=\(ctLanes.map { "c\($0.color):\($0.tiles.count)" }.joined(separator: ",")) confidence=\(String(format: "%.2f", confidence))")
            if confidence >= Self.minTopologyConfidence {
                return LaneTraceResult(lanes: ctLanes, diagnostics: diagnostics)
            }
        }

        var candidateGroups: [LaneCandidateGroup] = []
        for color in colors {
            let candidates = startTiles
                .filter { $0.trackColor == color }
                .flatMap { start -> [LaneCandidate] in
                    (0..<Self.directions.count).compactMap { direction in
                        let laneTiles = traceLane(
                            from: start,
                            initialDirection: direction,
                            tileGrid: tileGrid,
                            gridSize: gridSize
                        )
                        diagnostics.append("c\(color)@\(start.point)d\(direction):\(laneTiles.count)")
                        guard laneTiles.count >= Self.minLaneLength else { return nil }
                        return LaneCandidate(
                            lane: Lane(color: color, tiles: laneTiles),
                            start: start.point,
                            initialDirection: direction
                        )
                    }
                }

            let bestCandidates = topUniqueLaneCandidates(candidates)
            if !bestCandidates.isEmpty {
                candidateGroups.append(LaneCandidateGroup(color: color, candidates: bestCandidates))
            }
        }

        guard candidateGroups.count >= (Self.expectedTrackCounts.min() ?? 3) else {
            return LaneTraceResult(lanes: [], diagnostics: diagnostics)
        }

        var best: (lanes: [Lane], score: Int, confidence: Float)?
        func visit(groupIndex: Int, selected: [LaneCandidate]) {
            if groupIndex == candidateGroups.count {
                let lanes = selected.map(\.lane)
                guard Self.expectedTrackCounts.contains(lanes.count) else { return }
                let intersections = inferIntersections(from: lanes)
                let match = bestLayoutMatch(
                    laneLengths: lanes.map(\.tiles.count),
                    intersectionCount: intersections.count,
                    visibleTileCount: visibleTileCount,
                    lanes: lanes
                )
                guard match.layout != nil else { return }
                let score = topologyScore(confidence: match.confidence, laneCount: lanes.count)
                if best == nil || score < best!.score {
                    best = (lanes, score, match.confidence)
                }
                return
            }

            visit(groupIndex: groupIndex + 1, selected: selected)

            guard selected.count < (Self.expectedTrackCounts.max() ?? 4) else { return }
            for candidate in candidateGroups[groupIndex].candidates {
                visit(groupIndex: groupIndex + 1, selected: selected + [candidate])
            }
        }
        visit(groupIndex: 0, selected: [])

        if let best {
            diagnostics.append("selected=\(best.lanes.map { "c\($0.color):\($0.tiles.count)" }.joined(separator: ",")) confidence=\(String(format: "%.2f", best.confidence))")
            return LaneTraceResult(lanes: best.lanes, diagnostics: diagnostics)
        }

        return LaneTraceResult(lanes: [], diagnostics: diagnostics)
    }

    private func layoutCandidates(forVisibleTileCount visibleTileCount: Int) -> [LayoutCandidate] {
        CelticKnotLayoutType.allCases.compactMap { layoutType in
            let metadata = CelticKnotLayoutMetadata.metadata(for: layoutType)
            let expectedVisibleTiles = metadata.laneLengths.reduce(0, +) - metadata.intersectionCount
            guard expectedVisibleTiles == visibleTileCount else { return nil }
            return LayoutCandidate(metadata: metadata, expectedLengths: metadata.laneLengths.sorted())
        }
    }

    private func traceSameColourGraphLanes(
        tileGrid: [[Tile?]],
        gridSize: GridPoint,
        layoutCandidates: [LayoutCandidate],
        visibleTileCount: Int,
        diagnostics: inout [String]
    ) -> [Lane] {
        guard !layoutCandidates.isEmpty else { return [] }
        let colors = Array(Set(tileGrid.flatMap { $0 }.compactMap { $0?.trackColor })).sorted()
        var best: (lanes: [Lane], score: Int, layout: CelticKnotLayoutType)?

        for layoutCandidate in layoutCandidates {
            guard layoutCandidate.metadata.trackCount <= colors.count else { continue }
            let expectedLengths = layoutCandidate.expectedLengths
            let expectedLengthCounts = lengthCounts(expectedLengths)
            var candidateGroups: [LaneCandidateGroup] = []
            var viableCombinations: [(lanes: [Lane], baseScore: Int)] = []
            var foundMinimumScore = false

            for color in colors {
                if isNonLaneGrey(color: color, for: layoutCandidate.metadata) {
                    continue
                }
                let candidates = sameColourLaneCandidates(
                    color: color,
                    tileGrid: tileGrid,
                    gridSize: gridSize,
                    expectedLengths: Set(expectedLengths),
                    neutralGreyBridge: layoutCandidate.metadata.type == .eightSpot
                        || layoutCandidate.metadata.type == .eightSpotL
                )
                if !candidates.isEmpty {
                    let preview = candidates.prefix(12).map { "\($0.lane.tiles.count)@\($0.start)" }.joined(separator: ",")
                    diagnostics.append("graph\(layoutCandidate.metadata.type.rawValue)C\(color)=\(candidates.count)[\(preview)]")
                    candidateGroups.append(LaneCandidateGroup(color: color, candidates: candidates))
                }
            }

            guard candidateGroups.count >= layoutCandidate.metadata.trackCount else { continue }

            func visit(groupIndex: Int, selected: [LaneCandidate]) {
                guard !foundMinimumScore else { return }

                let selectedLengths = selected.map(\.lane.tiles.count)
                guard selected.count <= layoutCandidate.metadata.trackCount,
                      lengthCountsFit(selectedLengths, expected: expectedLengthCounts),
                      selected.count + (candidateGroups.count - groupIndex) >= layoutCandidate.metadata.trackCount
                else { return }

                if groupIndex == candidateGroups.count {
                    let lanes = selected.map(\.lane)
                    guard lanes.count == layoutCandidate.metadata.trackCount,
                          lanes.map(\.tiles.count).sorted() == expectedLengths
                    else { return }

                    let intersections = inferIntersections(from: lanes)
                    guard intersections.count == layoutCandidate.metadata.intersectionCount else { return }

                    let baseScore = graphScore(for: lanes)
                    recordViableCombination(lanes: lanes, baseScore: baseScore, combinations: &viableCombinations)
                    if baseScore == 0 {
                        foundMinimumScore = true
                    }
                    return
                }

                visit(groupIndex: groupIndex + 1, selected: selected)

                guard selected.count < layoutCandidate.metadata.trackCount else { return }
                for candidate in candidateGroups[groupIndex].candidates {
                    guard lengthCountsFit(selectedLengths + [candidate.lane.tiles.count], expected: expectedLengthCounts) else {
                        continue
                    }
                    visit(groupIndex: groupIndex + 1, selected: selected + [candidate])
                }
            }
            visit(groupIndex: 0, selected: [])

            guard !viableCombinations.isEmpty else { continue }
            viableCombinations.sort { lhs, rhs in
                if lhs.baseScore != rhs.baseScore { return lhs.baseScore < rhs.baseScore }
                return laneSortKey(lhs.lanes) < laneSortKey(rhs.lanes)
            }

            let first = viableCombinations[0]
            let bestForLayout = (lanes: first.lanes, score: first.baseScore)

            if best == nil || bestForLayout.score < best!.score {
                best = (bestForLayout.lanes, bestForLayout.score, layoutCandidate.metadata.type)
            }
            if best?.score == 0 {
                break
            }
        }

        if let best {
            diagnostics.append("graphSelected=\(best.layout.rawValue):\(best.lanes.map { "c\($0.color):\($0.tiles.count)" }.joined(separator: ",")) score=\(best.score)")
            return best.lanes
        }

        return []
    }

    private func isNonLaneGrey(color: Int, for layoutType: CelticKnotLayoutMetadata) -> Bool {
        color == 4 && layoutType.laneLengths.count == 3
    }

    private func recordViableCombination(
        lanes: [Lane],
        baseScore: Int,
        combinations: inout [(lanes: [Lane], baseScore: Int)]
    ) {
        let limit = 128
        guard combinations.count >= limit else {
            combinations.append((lanes, baseScore))
            return
        }

        guard let worstIndex = combinations.indices.max(by: { lhs, rhs in
            let left = combinations[lhs]
            let right = combinations[rhs]
            if left.baseScore != right.baseScore { return left.baseScore < right.baseScore }
            return laneSortKey(left.lanes) < laneSortKey(right.lanes)
        }) else { return }

        let worst = combinations[worstIndex]
        if baseScore < worst.baseScore ||
            (baseScore == worst.baseScore && laneSortKey(lanes) < laneSortKey(worst.lanes)) {
            combinations[worstIndex] = (lanes, baseScore)
        }
    }

    private func laneSortKey(_ lanes: [Lane]) -> String {
        lanes.map { lane in
            let points = lane.tiles.map(\.point.description).joined(separator: ",")
            return "c\(lane.color):\(points)"
        }.joined(separator: "|")
    }

    private func sameColourLaneCandidates(
        color: Int,
        tileGrid: [[Tile?]],
        gridSize: GridPoint,
        expectedLengths: Set<Int>,
        neutralGreyBridge: Bool = false
    ) -> [LaneCandidate] {
        let startPoints = Set(tileGrid.flatMap { $0 }.compactMap { tile -> GridPoint? in
            guard let tile, tile.trackColor == color, !tile.isIntersection else { return nil }
            return tile.point
        })
        guard !startPoints.isEmpty else { return [] }
        let traversalMembers = Set(tileGrid.flatMap { $0 }.compactMap { tile -> GridPoint? in
            guard let tile,
                  tile.trackColor == color
                    || tile.isIntersection
                    || (tile.trackColor == nil && tile.isTraceable)
                    || (neutralGreyBridge && color != 4 && tile.trackColor == 4)
            else {
                return nil
            }
            return tile.point
        })

        let candidates = startPoints.flatMap { start -> [LaneCandidate] in
            Self.directions.indices.flatMap { direction in
                sameColourCyclePaths(
                    color: color,
                    start: start,
                    initialDirection: direction,
                    members: traversalMembers,
                    tileGrid: tileGrid,
                    gridSize: gridSize,
                    expectedLengths: expectedLengths
                ).compactMap { path in
                    guard let firstTile = tile(at: start, in: tileGrid) else { return nil }
                    let tiles = path.compactMap { tile(at: $0, in: tileGrid) }
                    guard tiles.count == path.count else { return nil }
                    return LaneCandidate(
                        lane: Lane(color: color, tiles: tiles),
                        start: firstTile.point,
                        initialDirection: direction
                    )
                }
            }
        }

        return topUniqueLaneCandidates(
            candidates,
            expectedLengths: expectedLengths,
            limit: Self.maxGraphCandidatesPerColor
        )
    }

    private func sameColourCyclePaths(
        color: Int,
        start: GridPoint,
        initialDirection: Int,
        members: Set<GridPoint>,
        tileGrid: [[Tile?]],
        gridSize: GridPoint,
        expectedLengths: Set<Int>
    ) -> [[GridPoint]] {
        let step = Self.directions[initialDirection]
        let first = GridPoint(x: start.x + step.dx, y: start.y + step.dy)
        guard sameColourNeighbours(
            color: color,
            point: start,
            members: members,
            tileGrid: tileGrid,
            gridSize: gridSize
        ).contains(first) else { return [] }

        var path = [start, first]
        var visited: Set<GridPoint> = [start, first]
        let targets = expectedLengths.sorted()
        var results: [[GridPoint]] = []
        let maxResultsPerSeed = Self.maxGraphCyclesPerSeed

        func search(from current: GridPoint, previous: GridPoint) {
            guard results.count < maxResultsPerSeed else { return }

            if expectedLengths.contains(path.count) {
                let closes = sameColourNeighbours(
                    color: color,
                    point: current,
                    members: members,
                    tileGrid: tileGrid,
                    gridSize: gridSize
                ).contains(start)
                if closes {
                    results.append(path)
                }
            }

            guard path.count < (targets.last ?? 0) else { return }

            let neighbours = sameColourNeighbours(
                color: color,
                point: current,
                members: members,
                tileGrid: tileGrid,
                gridSize: gridSize
            )
            .filter { $0 != previous && $0 != start && !visited.contains($0) }
            .sorted { lhs, rhs in
                let lhsPenalty = tile(at: lhs, in: tileGrid)?.trackColor == color ? 0 : 1
                let rhsPenalty = tile(at: rhs, in: tileGrid)?.trackColor == color ? 0 : 1
                if lhsPenalty != rhsPenalty { return lhsPenalty < rhsPenalty }
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                return lhs.x < rhs.x
            }
            let nextSteps: [GridPoint]
            let currentTile = tile(at: current, in: tileGrid)
            if currentTile?.isIntersection == true, currentTile?.trackColor != color {
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                let straightThrough = GridPoint(x: current.x + dx, y: current.y + dy)
                nextSteps = neighbours.contains(straightThrough) ? [straightThrough] : neighbours
            } else {
                nextSteps = neighbours
            }

            for neighbour in nextSteps {
                path.append(neighbour)
                visited.insert(neighbour)
                search(from: neighbour, previous: current)
                visited.remove(neighbour)
                path.removeLast()
            }
        }

        search(from: first, previous: start)
        return results
    }

    private func graphScore(for lanes: [Lane]) -> Int {
        let bridgePenalty = lanes.reduce(0) { partial, lane in
            partial + lane.tiles.filter { $0.trackColor != lane.color }.count * 4
        }
        let weakPenalty = lanes.reduce(0) { partial, lane in
            partial + lane.tiles.filter { ($0.trackColorConfidence ?? 0) < 0.84 }.count
        }
        let unsupportedIntersectionPenalty = inferIntersections(from: lanes).reduce(0) { partial, intersection in
            let tile = lanes[intersection.0].tiles[intersection.1]
            guard let visibleColor = tile.trackColor else { return partial + 2 }
            let supported = visibleColor == lanes[intersection.0].color || visibleColor == lanes[intersection.2].color
            return partial + (supported ? 0 : 2)
        }
        return bridgePenalty + weakPenalty + unsupportedIntersectionPenalty
    }

    private func lengthCounts(_ lengths: [Int]) -> [Int: Int] {
        lengths.reduce(into: [:]) { counts, length in
            counts[length, default: 0] += 1
        }
    }

    private func lengthCountsFit(_ lengths: [Int], expected: [Int: Int]) -> Bool {
        let counts = lengthCounts(lengths)
        return counts.allSatisfy { length, count in
            count <= (expected[length] ?? 0)
        }
    }

    private func sameColourNeighbours(
        color: Int,
        point: GridPoint,
        members: Set<GridPoint>,
        tileGrid: [[Tile?]],
        gridSize: GridPoint
    ) -> [GridPoint] {
        Self.directions.compactMap { direction in
            let neighbour = GridPoint(x: point.x + direction.dx, y: point.y + direction.dy)
            guard neighbour.y >= 0,
                  neighbour.y < gridSize.y,
                  neighbour.x >= 0,
                  neighbour.x < gridSize.x,
                  let tile = tile(at: neighbour, in: tileGrid)
            else { return nil }

            if members.contains(neighbour) { return neighbour }

            // Hidden tracks pass through the visible top tile at a crossing.
            // Prefer explicit intersections, but allow traceable tiles here so
            // a missed intersection classification does not break the graph.
            guard tile.isIntersection || tile.isTraceable else { return nil }
            let opposite = GridPoint(x: neighbour.x + direction.dx, y: neighbour.y + direction.dy)
            guard opposite.y >= 0,
                  opposite.y < gridSize.y,
                  opposite.x >= 0,
                  opposite.x < gridSize.x,
                  members.contains(opposite)
            else { return nil }
            return neighbour
        }
    }

    private func tile(at point: GridPoint, in tileGrid: [[Tile?]]) -> Tile? {
        guard point.y >= 0,
              point.y < tileGrid.count,
              point.x >= 0,
              point.x < tileGrid[point.y].count
        else { return nil }
        return tileGrid[point.y][point.x]
    }

    private func traceClueTrainerLanes(
        startTiles: [Tile],
        tileGrid: [[Tile?]],
        gridSize: GridPoint
    ) -> [Lane] {
        var lanes: [Lane] = []

        while true {
            guard let start = startTiles.first(where: { tile in
                guard let color = tile.trackColor else { return false }
                return !lanes.contains { $0.color == color }
            }) else {
                break
            }

            let laneTiles = traceLane(
                from: start,
                initialDirection: 2,
                tileGrid: tileGrid,
                gridSize: gridSize
            )
            guard laneTiles.count >= Self.minLaneLength else { break }
            lanes.append(Lane(color: start.trackColor ?? -1, tiles: laneTiles))
        }

        return lanes
    }

    private func topUniqueLaneCandidates(_ candidates: [LaneCandidate]) -> [LaneCandidate] {
        topUniqueLaneCandidates(
            candidates,
            expectedLengths: Self.expectedLaneLengths,
            limit: 8
        )
    }

    private func topUniqueLaneCandidates(
        _ candidates: [LaneCandidate],
        expectedLengths: Set<Int>,
        limit: Int
    ) -> [LaneCandidate] {
        var seen = Set<String>()
        let unique = candidates.filter { candidate in
            let key = laneCandidateKey(candidate)
            return seen.insert(key).inserted
        }

        func sortedCandidates(_ candidates: [LaneCandidate]) -> [LaneCandidate] {
            candidates.sorted { lhs, rhs in
                let lhsDistance = expectedLengths.map { abs(lhs.lane.tiles.count - $0) }.min() ?? Int.max
                let rhsDistance = expectedLengths.map { abs(rhs.lane.tiles.count - $0) }.min() ?? Int.max
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                let lhsScore = graphScore(for: [lhs.lane])
                let rhsScore = graphScore(for: [rhs.lane])
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                if lhs.lane.tiles.count != rhs.lane.tiles.count {
                    return lhs.lane.tiles.count < rhs.lane.tiles.count
                }
                if lhs.start.y != rhs.start.y { return lhs.start.y < rhs.start.y }
                if lhs.start.x != rhs.start.x { return lhs.start.x < rhs.start.x }
                return lhs.initialDirection < rhs.initialDirection
            }
        }

        let exactLengthBuckets = expectedLengths.sorted().map { length in
            sortedCandidates(unique.filter { $0.lane.tiles.count == length })
        }.filter { !$0.isEmpty }

        guard !exactLengthBuckets.isEmpty else {
            return Array(sortedCandidates(unique).prefix(limit))
        }

        let perBucketLimit = max(1, limit / exactLengthBuckets.count)
        var selected = exactLengthBuckets.flatMap { $0.prefix(perBucketLimit) }
        if selected.count < limit {
            let selectedKeys = Set(selected.map(laneCandidateKey))
            let remainder = sortedCandidates(unique).filter { candidate in
                !selectedKeys.contains(laneCandidateKey(candidate))
            }
            selected.append(contentsOf: remainder.prefix(limit - selected.count))
        }
        return Array(selected.prefix(limit))
    }

    private func laneCandidateKey(_ candidate: LaneCandidate) -> String {
        canonicalPointCycleKey(candidate.lane.tiles.map(\.point))
    }

    private func canonicalPointCycleKey(_ points: [GridPoint]) -> String {
        guard !points.isEmpty else { return "" }
        let forward = points.map(\.description)
        let backward = Array(forward.reversed())
        var keys: [String] = []
        keys.reserveCapacity(points.count * 2)

        for index in forward.indices {
            keys.append((forward[index...] + forward[..<index]).joined(separator: ";"))
        }
        for index in backward.indices {
            keys.append((backward[index...] + backward[..<index]).joined(separator: ";"))
        }

        return keys.min() ?? forward.joined(separator: ";")
    }

    private func topologyScore(confidence: Float, laneCount: Int) -> Int {
        let confidencePenalty = Int(round((1 - confidence) * 100))
        return confidencePenalty + abs(laneCount - 3) * 5
    }

    private func traceLane(
        from start: Tile,
        initialDirection: Int,
        tileGrid: [[Tile?]],
        gridSize: GridPoint
    ) -> [Tile] {
        var laneTiles: [Tile] = []
        var directionIndex = initialDirection
        var tile = start
        var visited = Set<GridPoint>()

        while true {
            laneTiles.append(tile)
            visited.insert(tile.point)

            let step = Self.directions[directionIndex]
            let nextPoint = GridPoint(x: tile.point.x + step.dx, y: tile.point.y + step.dy)
            guard nextPoint.y >= 0, nextPoint.y < gridSize.y,
                  nextPoint.x >= 0, nextPoint.x < gridSize.x,
                  let nextTile = tileGrid[nextPoint.y][nextPoint.x],
                  nextTile.isReadable
            else { break }

            if nextTile.point == start.point || laneTiles.count > 40 {
                break
            }

            tile = nextTile
            if !tile.isIntersection, !tile.neighboursExist[safe: directionIndex, default: false] {
                if let turn = [0, 1, 2, 3].first(where: { idx in
                    idx != (directionIndex + 2) % 4
                        && tile.neighboursExist[safe: idx, default: false]
                }) {
                    directionIndex = turn
                } else {
                    break
                }
            }

            if visited.contains(tile.point) {
                break
            }
        }

        return laneTiles
    }

    private func inferTopology(from lanes: [Lane], visibleTileCount: Int) -> Topology? {
        guard lanes.count >= 3 else { return nil }
        let intersections = inferIntersections(from: lanes)
        let lengths = lanes.map(\.tiles.count)
        let match = bestLayoutMatch(
            laneLengths: lengths,
            intersectionCount: intersections.count,
            visibleTileCount: visibleTileCount,
            lanes: lanes
        )
        return Topology(
            laneLengths: lengths,
            intersectionCount: intersections.count,
            candidate: match.layout,
            confidence: match.confidence,
            reason: match.reason
        )
    }

    private func inferIntersections(from lanes: [Lane]) -> [(Int, Int, Int, Int)] {
        var intersections: [(Int, Int, Int, Int)] = []
        var seen = Set<String>()

        for laneIndex in lanes.indices {
            for otherLaneIndex in lanes.indices where otherLaneIndex > laneIndex {
                for tileIndex in lanes[laneIndex].tiles.indices {
                    let point = lanes[laneIndex].tiles[tileIndex].point
                    guard let otherTileIndex = lanes[otherLaneIndex].tiles.firstIndex(where: { $0.point == point }) else {
                        continue
                    }

                    let key = "\(laneIndex):\(tileIndex)-\(otherLaneIndex):\(otherTileIndex)"
                    if seen.insert(key).inserted {
                        intersections.append((laneIndex, tileIndex, otherLaneIndex, otherTileIndex))
                    }
                }
            }
        }

        return intersections
    }

    private func topologyHash(for lanes: [Lane]) -> [Int] {
        let lengths = lanes.map(\.tiles.count)
        let locks = inferIntersections(from: lanes).map { intersection in
            topologyLockCode(
                laneA: intersection.0,
                slotA: intersection.1,
                laneB: intersection.2,
                slotB: intersection.3
            )
        }.sorted()
        return lengths + locks
    }

    private func topologyHashMatches(lanes: [Lane], metadata: CelticKnotLayoutMetadata) -> Bool {
        guard let expectedHash = metadata.topologyHash else { return true }
        guard lanes.count == metadata.trackCount,
              expectedHash.count >= metadata.trackCount,
              Array(expectedHash.prefix(metadata.trackCount)).sorted() == lanes.map(\.tiles.count).sorted()
        else { return false }

        let observedIntersections = inferIntersections(from: lanes)
        let expectedLockCodes = Set(expectedHash.dropFirst(metadata.trackCount))
        guard observedIntersections.count == expectedLockCodes.count else { return false }

        for metadataToObservedLane in permutations(of: Array(lanes.indices)) {
            var observedToMetadataLane = Array(repeating: 0, count: lanes.count)
            var lengthsMatch = true
            for metadataLane in metadataToObservedLane.indices {
                let observedLane = metadataToObservedLane[metadataLane]
                guard metadata.laneLengths[metadataLane] == lanes[observedLane].tiles.count else {
                    lengthsMatch = false
                    break
                }
                observedToMetadataLane[observedLane] = metadataLane
            }
            guard lengthsMatch else { continue }

            let orientationCount = 1 << lanes.count
            for orientationMask in 0..<orientationCount {
                var rotations = Array(repeating: 0, count: lanes.count)
                if topologyHashMatches(
                    metadataLane: 0,
                    rotations: &rotations,
                    orientationMask: orientationMask,
                    observedToMetadataLane: observedToMetadataLane,
                    observedIntersections: observedIntersections,
                    expectedLockCodes: expectedLockCodes,
                    metadata: metadata
                ) {
                    return true
                }
            }
        }

        return false
    }

    private func topologyHashMatches(
        metadataLane: Int,
        rotations: inout [Int],
        orientationMask: Int,
        observedToMetadataLane: [Int],
        observedIntersections: [(Int, Int, Int, Int)],
        expectedLockCodes: Set<Int>,
        metadata: CelticKnotLayoutMetadata
    ) -> Bool {
        guard partialTopologyHashMatches(
            assignedMetadataLaneCount: metadataLane,
            rotations: rotations,
            orientationMask: orientationMask,
            observedToMetadataLane: observedToMetadataLane,
            observedIntersections: observedIntersections,
            expectedLockCodes: expectedLockCodes,
            metadata: metadata
        ) else {
            return false
        }

        if metadataLane == metadata.trackCount {
            var observedLockCodes = Set<Int>()
            for intersection in observedIntersections {
                let laneA = observedToMetadataLane[intersection.0]
                let laneB = observedToMetadataLane[intersection.2]
                let slotA = transformedSlot(
                    intersection.1,
                    lane: laneA,
                    rotations: rotations,
                    orientationMask: orientationMask,
                    lengths: metadata.laneLengths
                )
                let slotB = transformedSlot(
                    intersection.3,
                    lane: laneB,
                    rotations: rotations,
                    orientationMask: orientationMask,
                    lengths: metadata.laneLengths
                )
                observedLockCodes.insert(topologyLockCode(laneA: laneA, slotA: slotA, laneB: laneB, slotB: slotB))
            }
            return observedLockCodes == expectedLockCodes
        }

        for rotation in 0..<metadata.laneLengths[metadataLane] {
            rotations[metadataLane] = rotation
            if topologyHashMatches(
                metadataLane: metadataLane + 1,
                rotations: &rotations,
                orientationMask: orientationMask,
                observedToMetadataLane: observedToMetadataLane,
                observedIntersections: observedIntersections,
                expectedLockCodes: expectedLockCodes,
                metadata: metadata
            ) {
                return true
            }
        }
        return false
    }

    private func partialTopologyHashMatches(
        assignedMetadataLaneCount: Int,
        rotations: [Int],
        orientationMask: Int,
        observedToMetadataLane: [Int],
        observedIntersections: [(Int, Int, Int, Int)],
        expectedLockCodes: Set<Int>,
        metadata: CelticKnotLayoutMetadata
    ) -> Bool {
        guard assignedMetadataLaneCount > 0 else { return true }

        for intersection in observedIntersections {
            let laneA = observedToMetadataLane[intersection.0]
            let laneB = observedToMetadataLane[intersection.2]
            guard laneA < assignedMetadataLaneCount,
                  laneB < assignedMetadataLaneCount
            else { continue }

            let slotA = transformedSlot(
                intersection.1,
                lane: laneA,
                rotations: rotations,
                orientationMask: orientationMask,
                lengths: metadata.laneLengths
            )
            let slotB = transformedSlot(
                intersection.3,
                lane: laneB,
                rotations: rotations,
                orientationMask: orientationMask,
                lengths: metadata.laneLengths
            )
            guard expectedLockCodes.contains(topologyLockCode(laneA: laneA, slotA: slotA, laneB: laneB, slotB: slotB)) else {
                return false
            }
        }

        return true
    }

    private func transformedSlot(
        _ slot: Int,
        lane: Int,
        rotations: [Int],
        orientationMask: Int,
        lengths: [Int]
    ) -> Int {
        let length = lengths[lane]
        let rotation = rotations[lane]
        if (orientationMask & (1 << lane)) == 0 {
            return (slot + rotation) % length
        }
        return (rotation - slot + length) % length
    }

    private func topologyLockCode(laneA: Int, slotA: Int, laneB: Int, slotB: Int) -> Int {
        let first = laneA * 100 + slotA
        let second = laneB * 100 + slotB
        let minEndpoint = min(first, second)
        let maxEndpoint = max(first, second)
        return minEndpoint * 10_000 + maxEndpoint
    }

    private func permutations(of values: [Int]) -> [[Int]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { permutation in
            (0...permutation.count).map { index in
                var next = permutation
                next.insert(first, at: index)
                return next
            }
        }
    }

    private func bestLayoutMatch(
        laneLengths: [Int],
        intersectionCount: Int,
        visibleTileCount: Int,
        lanes: [Lane]? = nil
    ) -> (layout: CelticKnotLayoutType?, confidence: Float, reason: String) {
        let observedLengths = laneLengths.sorted()
        var best: (layout: CelticKnotLayoutType, score: Int, reason: String)?

        for layoutType in CelticKnotLayoutType.allCases {
            let metadata = CelticKnotLayoutMetadata.metadata(for: layoutType)
            let expectedVisibleTiles = metadata.laneLengths.reduce(0, +) - metadata.intersectionCount
            guard expectedVisibleTiles == visibleTileCount else { continue }
            let expectedLengths = metadata.laneLengths.sorted()
            guard observedLengths == expectedLengths else { continue }
            let intersectionPenalty = abs(intersectionCount - metadata.intersectionCount) * 4
            guard intersectionPenalty == 0 else { continue }
            let hashPenalty = metadata.topologyHash != nil && lanes != nil && !topologyHashMatches(lanes: lanes!, metadata: metadata) ? 1 : 0
            let score = intersectionPenalty + hashPenalty
            let observedHash = lanes.map { " observedHash=\(topologyHash(for: $0))" } ?? ""
            let reason = "expectedLengths=\(expectedLengths) expectedVisible=\(expectedVisibleTiles) expectedIntersections=\(metadata.intersectionCount) penalty=\(score) hashPenalty=\(hashPenalty)\(observedHash)"
            if best == nil || score < best!.score {
                best = (layoutType, score, reason)
            }
        }

        guard let best else {
            return (nil, 0, "no exact layout candidates for visibleTiles=\(visibleTileCount) lengths=\(observedLengths) intersections=\(intersectionCount)")
        }
        let confidence = max(0, 1 - Float(best.score) / 20)
        return (best.layout, confidence, best.reason)
    }

    private func isBackground(at x: Int, y: Int, in buffer: PixelBuffer) -> Bool {
        guard let rgb = buffer.sample(x: x, y: y) else { return true }
        let samples: [(Float, Float, Float)] = [
            (159, 145, 86),
            (177, 161, 95),
            (144, 131, 79),
        ]
        return (samples.map { rgbSimilarity((rgb.r, rgb.g, rgb.b), $0) }.max() ?? 0) > 0.90
    }

    private func identifyRune(
        image: CGImage,
        area: CGRect,
        origin: CGPoint,
        pitch: CGFloat
    ) -> RunePresence? {
        // Opt1's shipped rune model was trained on whole rune crops, while
        // ClueTrainer's atlas is a compact 12x12 fingerprint. Use the CT patch
        // as a presence sanity check, then ask the Opt1 model about the full rune.
        let center = CGPoint(
            x: area.minX + origin.x + pitch * 0.5,
            y: area.minY + origin.y + pitch * (13.0 / 24.0)
        )
        let cropSide = max(12, Int(round(pitch * (25.0 / 24.0))))
        let imageCropRect = CGRect(
            x: center.x - CGFloat(cropSide) / 2,
            y: center.y - CGFloat(cropSide) / 2,
            width: CGFloat(cropSide),
            height: CGFloat(cropSide)
        ).integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))

        if imageCropRect.width >= 6,
           imageCropRect.height >= 6,
           let crop = image.cropping(to: imageCropRect),
           let rune = runePresenceClassifier.identify(crop) {
            return rune
        }

        return nil
    }

    private func isRuneLikeCenterPatch(
        origin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer
    ) -> Bool {
        runeLikeCenterPatchStats(origin: origin, pitch: pitch, buffer: buffer).isRuneLike
    }

    private func runeLikeCenterPatchStats(
        origin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer
    ) -> RuneLikePatchStats {
        let cropOrigin = CGPoint(
            x: origin.x + pitch * (7.0 / 24.0),
            y: origin.y + pitch * (7.0 / 24.0)
        )
        let cropSide = max(6, Int(round(pitch * (12.0 / 24.0))))
        var content = 0
        var saturatedOrDark = 0
        var total = 0
        var luminances: [Float] = []
        luminances.reserveCapacity(cropSide * cropSide)

        for y in 0..<cropSide {
            for x in 0..<cropSide {
                let px = Int(round(cropOrigin.x)) + x
                let py = Int(round(cropOrigin.y)) + y
                guard let rgb = buffer.sample(x: px, y: py) else { continue }
                let r = rgb.r / 255
                let g = rgb.g / 255
                let b = rgb.b / 255
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let sat = maxC > 0.001 ? (maxC - minC) / maxC : 0
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if !isBackground(at: px, y: py, in: buffer) {
                    content += 1
                }
                if maxC < 0.35 || sat > 0.45 {
                    saturatedOrDark += 1
                }
                luminances.append(lum)
                total += 1
            }
        }

        guard total > 0 else {
            return RuneLikePatchStats(contentFraction: 0, inkFraction: 0, variance: 0)
        }
        let contentFraction = Float(content) / Float(total)
        let inkFraction = Float(saturatedOrDark) / Float(total)
        let mean = luminances.reduce(Float(0), +) / Float(luminances.count)
        let variance = luminances.reduce(Float(0)) { sum, lum in
            let d = lum - mean
            return sum + d * d
        } / Float(luminances.count)

        return RuneLikePatchStats(
            contentFraction: contentFraction,
            inkFraction: inkFraction,
            variance: variance
        )
    }

    private func trackColorSamples(
        origin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer
    ) -> [(Float, Float, Float)] {
        let offsets = [
            CGPoint(x: 11, y: -3), CGPoint(x: 12, y: -3),
            CGPoint(x: -5, y: 12), CGPoint(x: -5, y: 13),
            CGPoint(x: 29, y: 12), CGPoint(x: 29, y: 13),
            CGPoint(x: 11, y: 28), CGPoint(x: 12, y: 28),
        ].map { CGPoint(x: $0.x / 24 * pitch, y: $0.y / 24 * pitch) }

        return offsets.compactMap {
            buffer.sample(x: Int(round(origin.x + $0.x)), y: Int(round(origin.y + $0.y)))
        }
    }

    private func intersectionSamples(
        origin: CGPoint,
        pitch: CGFloat,
        buffer: PixelBuffer
    ) -> [(Float, Float, Float)] {
        let offsets = [
            CGPoint(x: 12, y: -1),
            CGPoint(x: -1, y: 12),
            CGPoint(x: 24, y: 12),
            CGPoint(x: 12, y: 24),
        ].map { CGPoint(x: $0.x / 24 * pitch, y: $0.y / 24 * pitch) }

        return offsets.compactMap {
            buffer.sample(x: Int(round(origin.x + $0.x)), y: Int(round(origin.y + $0.y)))
        }
    }

    private func getTrackColor(samples: [(Float, Float, Float)]) -> (id: Int, certainty: Float)? {
        let trackSamples = samples.filter { !isLikelyIntersectionMarkerInk($0) }
        guard !trackSamples.isEmpty else { return nil }
        let trackInkCount = trackSamples.filter(isLikelyTrackInk).count
        guard trackInkCount >= 2 else { return nil }

        let refs: [(id: Int, colors: [(Float, Float, Float)])] = [
            (0, [(46, 46, 77), (45, 45, 75), (28, 28, 47), (35, 25, 58), (50, 50, 85)]),
            (1, [(137, 60, 43), (67, 29, 21), (97, 43, 30), (62, 27, 17)]),
            (2, [(12, 12, 18), (11, 11, 16), (18, 18, 27)]),
            (3, [(43, 30, 0), (159, 112, 0), (205, 146, 0), (104, 74, 0), (137, 97, 0)]),
            (4, [(95, 89, 76), (123, 116, 98), (30, 28, 24)]),
        ]

        let scored = refs.map { ref -> (id: Int, certainty: Float) in
            let sum = trackSamples.reduce(Float(0)) { total, sample in
                total + (ref.colors.map { rgbSimilarity(sample, $0) }.max() ?? 0)
            }
            return (ref.id, sum / Float(trackSamples.count))
        }
        guard let best = scored.max(by: { $0.certainty < $1.certainty }),
              best.certainty > 0.80
        else { return nil }
        return best
    }

    private func isLikelyTrackInk(_ sample: (Float, Float, Float)) -> Bool {
        let r = sample.0 / 255
        let g = sample.1 / 255
        let b = sample.2 / 255
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let sat = maxC > 0.001 ? (maxC - minC) / maxC : 0

        // Parchment is mid-value and warm; actual tracks are either dark,
        // strongly saturated, or low-value grey. This prevents beige cells
        // from being classified as the yellow/grey lanes.
        return maxC < 0.34
            || sat > 0.58
            || (maxC < 0.52 && sat < 0.32)
    }

    private func isLikelyIntersectionMarkerInk(_ sample: (Float, Float, Float)) -> Bool {
        let match: [(Float, Float, Float)] = [(99, 178, 74), (86, 155, 64), (108, 195, 81), (130, 235, 98)]
        let noMatch: [(Float, Float, Float)] = [(60, 0, 0), (86, 0, 0), (92, 0, 0), (106, 0, 0)]
        let matchScore = match.map { rgbSimilarity(sample, $0) }.max() ?? 0
        let noMatchScore = noMatch.map { rgbSimilarity(sample, $0) }.max() ?? 0
        let redDominant = sample.0 > 55 && sample.0 > sample.1 * 1.8 && sample.0 > sample.2 * 1.8
        let greenDominant = sample.1 > 90 && sample.1 > sample.0 * 1.15 && sample.1 > sample.2 * 1.35
        return (greenDominant && matchScore > 0.78) || (redDominant && noMatchScore > 0.78)
    }

    private func classifyIntersectionMarker(samples: [(Float, Float, Float)]) -> Bool? {
        guard !samples.isEmpty else { return nil }
        let match: [(Float, Float, Float)] = [(99, 178, 74), (86, 155, 64), (108, 195, 81), (130, 235, 98)]
        let noMatch: [(Float, Float, Float)] = [(60, 0, 0), (86, 0, 0), (92, 0, 0), (106, 0, 0)]
        let matchScore = samples.reduce(Float(0)) { total, sample in
            total + (match.map { rgbSimilarity(sample, $0) }.max() ?? 0)
        }
        let noMatchScore = samples.reduce(Float(0)) { total, sample in
            total + (noMatch.map { rgbSimilarity(sample, $0) }.max() ?? 0)
        }
        let sampleCount = Float(samples.count)
        let matchAverage = matchScore / sampleCount
        let noMatchAverage = noMatchScore / sampleCount
        guard max(matchAverage, noMatchAverage) > 0.76 else { return nil }
        return matchAverage > noMatchAverage
    }

    private func rgbSimilarity(
        _ a: (Float, Float, Float),
        _ b: (Float, Float, Float)
    ) -> Float {
        let dr = a.0 - b.0
        let dg = a.1 - b.1
        let db = a.2 - b.2
        let dist = sqrt(dr * dr + dg * dg + db * db)
        return max(0, 1 - dist / 441.67295)
    }

    private static func makePixelBuffer(from image: CGImage) -> PixelBuffer? {
        let width = image.width
        let height = image.height
        let byteCount = width * height * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let rawData = ctx.data else { return nil }
        let buffer = rawData.bindMemory(to: UInt8.self, capacity: byteCount)
        let data = Array(UnsafeBufferPointer(start: buffer, count: byteCount))
        return PixelBuffer(width: width, height: height, data: data)
    }
}

private struct RunePresenceClassifier {
    private let artifact: CelticKnotRuneModelArtifact?

    init(artifact: CelticKnotRuneModelArtifact?) {
        self.artifact = artifact
    }

    func identify(_ image: CGImage) -> CelticKnotGridReader.RunePresence? {
        guard let artifact,
              let embedding = embedding(for: image, version: artifact.embeddingVersion)
        else { return nil }

        if artifact.isKNN {
            return identifyKNN(embedding, artifact: artifact)
        }
        return identifyCentroid(embedding, artifact: artifact)
    }

    private func embedding(for image: CGImage, version: Int) -> [Float]? {
        if version >= 3 {
            return PuzzleEmbeddingExtractor.colorEmbeddingV3(for: image, side: 32)
        }
        if version >= 2 {
            return PuzzleEmbeddingExtractor.colorEmbedding(for: image, side: 32)
        }
        return PuzzleEmbeddingExtractor.embedding(for: image, side: 32)
    }

    private func identifyKNN(
        _ embedding: [Float],
        artifact: CelticKnotRuneModelArtifact
    ) -> CelticKnotGridReader.RunePresence? {
        guard let refs = artifact.referenceEmbeddings,
              let labels = artifact.referenceLabels,
              !refs.isEmpty,
              refs.count == labels.count
        else { return nil }

        let k = min(max(1, artifact.k ?? 3), refs.count)
        var topSims = [Float](repeating: -.infinity, count: k)
        var topIdxs = [Int](repeating: -1, count: k)
        for i in refs.indices {
            let sim = MathHelpers.dotNormalized(embedding, refs[i])
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
        for j in 0..<k {
            let idx = topIdxs[j]
            guard idx >= 0 else { continue }
            voteWeights[labels[idx], default: 0] += max(0, topSims[j])
        }
        guard let label = voteWeights.max(by: { $0.value < $1.value })?.key else { return nil }

        let winnerScores = (0..<k).compactMap { j -> Float? in
            let idx = topIdxs[j]
            guard idx >= 0, labels[idx] == label else { return nil }
            return topSims[j]
        }
        let confidence = winnerScores.isEmpty
            ? 0
            : winnerScores.reduce(0, +) / Float(winnerScores.count)
        let runnerLabel = voteWeights.filter { $0.key != label }.max(by: { $0.value < $1.value })?.key
        let runnerScores = (0..<k).compactMap { j -> Float? in
            let idx = topIdxs[j]
            guard let runnerLabel, idx >= 0, labels[idx] == runnerLabel else { return nil }
            return topSims[j]
        }
        let runnerConfidence = runnerScores.isEmpty
            ? 0
            : runnerScores.reduce(0, +) / Float(runnerScores.count)
        let margin = confidence - runnerConfidence

        let minConfidence = max(artifact.recommendedMinConfidence ?? 0.70, 0.70)
        let minMargin = artifact.recommendedMinMargin ?? 0.0
        guard confidence >= minConfidence, margin >= minMargin else { return nil }
        return CelticKnotGridReader.RunePresence(label: label, confidence: confidence, margin: margin)
    }

    private func identifyCentroid(
        _ embedding: [Float],
        artifact: CelticKnotRuneModelArtifact
    ) -> CelticKnotGridReader.RunePresence? {
        guard let centroids = artifact.centroids,
              !centroids.isEmpty,
              centroids.count == artifact.indexToClass.count
        else { return nil }

        let scores = centroids.map { MathHelpers.dotNormalized(embedding, $0) }
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let sorted = scores.sorted()
        let confidence = scores[bestIndex]
        let margin = sorted.count >= 2
            ? sorted[sorted.count - 1] - sorted[sorted.count - 2]
            : confidence
        let minConfidence = max(artifact.recommendedMinConfidence ?? 0.70, 0.70)
        let minMargin = max(artifact.recommendedMinMargin ?? 0.0, 0.0)
        guard confidence >= minConfidence, margin >= minMargin else { return nil }
        return CelticKnotGridReader.RunePresence(
            label: artifact.indexToClass[bestIndex],
            confidence: confidence,
            margin: margin
        )
    }
}

private extension Array {
    subscript(safe index: Int, default defaultValue: Element) -> Element {
        indices.contains(index) ? self[index] : defaultValue
    }
}
