import Testing
import Foundation
@testable import Opt1

// MARK: - WalkabilityGrid Tests

@Suite("WalkabilityGrid")
struct WalkabilityGridTests {

    // 4×2 grid (width=4, height=2), all tiles walkable.
    // 8 tiles fit in one byte; 0xFF sets all 8 bits.
    private func allWalkable4x2() -> WalkabilityGrid {
        WalkabilityGrid(regionId: "test", mapId: 0,
                        originX: 0, originY: 0,
                        width: 4, height: 2,
                        bits: [0xFF])
    }

    @Test("in-bounds walkable tile reports walkable")
    func inBoundsWalkable() {
        #expect(allWalkable4x2().isWalkable(gameX: 2, gameY: 1))
    }

    @Test("out-of-bounds tile reports walkable (graceful fallback)")
    func outOfBoundsWalkable() {
        #expect(allWalkable4x2().isWalkable(gameX: 99, gameY: 99))
    }

    @Test("explicitly blocked tile reports not walkable")
    func blockedTileNotWalkable() {
        // 4×1 grid: only tile at col=0 is walkable (bit 0 set).
        // bits = 0b00000001 = 0x01
        let grid = WalkabilityGrid(regionId: "test", mapId: 0,
                                   originX: 0, originY: 0,
                                   width: 4, height: 1,
                                   bits: [0x01])
        #expect( grid.isWalkable(gameX: 0, gameY: 0))
        #expect(!grid.isWalkable(gameX: 1, gameY: 0))
        #expect(!grid.isWalkable(gameX: 3, gameY: 0))
    }

    @Test("gridIndex returns row×width+col for in-bounds tile")
    func gridIndexInBounds() {
        // col=2, row=1 → idx = 1×4 + 2 = 6
        #expect(allWalkable4x2().gridIndex(gameX: 2, gameY: 1) == 6)
    }

    @Test("gridIndex returns nil for out-of-bounds tile")
    func gridIndexOutOfBounds() {
        #expect(allWalkable4x2().gridIndex(gameX: 10, gameY: 0) == nil)
    }

    @Test("covers returns true when bounding box fits within grid")
    func coversInsideBounds() {
        // Grid spans game x: 0…3, y: 0…1. xMax=3 < originX+width=4 ✓
        #expect(allWalkable4x2().covers(xMin: 0, yMin: 0, xMax: 3, yMax: 1))
    }

    @Test("covers returns false when bounding box equals or exceeds grid edge")
    func coversExceedsBounds() {
        // xMax == originX+width (4) — one tile past the last valid column
        #expect(!allWalkable4x2().covers(xMin: 0, yMin: 0, xMax: 4, yMax: 1))
    }
}

// MARK: - BFSPathfinder Tests

@Suite("BFSPathfinder")
struct BFSPathfinderTests {

    // 3×3 fully walkable grid at origin (0,0).
    // 9 tiles → byte 0 covers tiles 0-7 (0xFF), byte 1 covers tile 8 (0x01).
    private func openGrid3x3() -> WalkabilityGrid {
        WalkabilityGrid(regionId: "test", mapId: 0,
                        originX: 0, originY: 0,
                        width: 3, height: 3,
                        bits: [0xFF, 0x01])
    }

    @Test("distance to same tile is 0")
    func selfDistanceIsZero() {
        #expect(BFSPathfinder.distance(from: (1, 1), to: (1, 1), over: openGrid3x3()) == 0)
    }

    @Test("diagonal move costs 1 (8-directional movement)")
    func diagonalCostsOne() {
        #expect(BFSPathfinder.distance(from: (1, 1), to: (0, 0), over: openGrid3x3()) == 1)
        #expect(BFSPathfinder.distance(from: (1, 1), to: (2, 2), over: openGrid3x3()) == 1)
    }

    @Test("all tiles reachable in fully open grid")
    func allTilesReachableInOpenGrid() {
        let map = BFSPathfinder.distanceMap(from: (1, 1), over: openGrid3x3())
        #expect(map.count == 9)
        #expect(map.allSatisfy { $0 != Int.max })
    }

    @Test("blocked tile blocks traversal in 1D corridor")
    func blockedTileBlocksTraversal() {
        // 5×1 corridor: tiles 0,1 walkable; tile 2 blocked; tiles 3,4 walkable.
        // bit pattern: 0 1 _ 3 4 → bits set: 0,1,3,4 → 0b00011011 = 0x1B
        let grid = WalkabilityGrid(regionId: "test", mapId: 0,
                                   originX: 0, originY: 0,
                                   width: 5, height: 1,
                                   bits: [0x1B])
        // Tiles 3 and 4 are unreachable from tile 0 in a 1D corridor.
        #expect(BFSPathfinder.distance(from: (0, 0), to: (4, 0), over: grid) == nil)
        #expect(BFSPathfinder.distance(from: (0, 0), to: (3, 0), over: grid) == nil)
        // Tile 1 is still reachable (distance = 1).
        #expect(BFSPathfinder.distance(from: (0, 0), to: (1, 0), over: grid) == 1)
    }

    @Test("origin outside grid bounds returns all-unreachable map")
    func originOutsideGridReturnsUnreachable() {
        #expect(BFSPathfinder.distance(from: (99, 99), to: (0, 0), over: openGrid3x3()) == nil)
    }

    @Test("unwalkable origin returns all-unreachable map")
    func unwalkableOriginReturnsUnreachable() {
        // 3×1 grid: tiles 0 and 2 walkable, tile 1 (middle) blocked.
        // bits set: 0, 2 → 0b00000101 = 0x05
        let grid = WalkabilityGrid(regionId: "test", mapId: 0,
                                   originX: 0, originY: 0,
                                   width: 3, height: 1,
                                   bits: [0x05])
        // Starting from the blocked middle tile should yield nil for all queries.
        #expect(BFSPathfinder.distance(from: (1, 0), to: (0, 0), over: grid) == nil)
        #expect(BFSPathfinder.distance(from: (1, 0), to: (2, 0), over: grid) == nil)
    }
}

// MARK: - ScanOptimiser Tests

@Suite("ScanOptimiser")
struct ScanOptimiserTests {

    private let fourSpots: [(id: String, x: Int, y: Int)] = [
        ("A",  0, 0),
        ("B", 30, 0),
        ("C", 60, 0),
        ("D", 90, 0),
    ]

    // MARK: Nil-return edge cases

    @Test("returns nil when only one candidate survives")
    func nilForSingleSurvivor() {
        #expect(ScanOptimiser.recommend(
            surviving: ["A"],
            allCoords: fourSpots,
            range: 10,
            mapId: 0
        ) == nil)
    }

    @Test("returns nil when no candidates survive")
    func nilForNoSurvivors() {
        #expect(ScanOptimiser.recommend(
            surviving: [],
            allCoords: fourSpots,
            range: 10,
            mapId: 0
        ) == nil)
    }

    @Test("returns nil when range is zero")
    func nilForZeroRange() {
        #expect(ScanOptimiser.recommend(
            surviving: Set(fourSpots.map(\.id)),
            allCoords: fourSpots,
            range: 0,
            mapId: 0
        ) == nil)
    }

    // MARK: Valid recommendation properties

    @Test("recommended step has at least 2 non-empty pulse buckets")
    func recommendedStepSplitsAtLeastTwoBuckets() throws {
        let step = try #require(ScanOptimiser.recommend(
            surviving: Set(fourSpots.map(\.id)),
            allCoords: fourSpots,
            range: 10,
            mapId: 0
        ))
        let nonEmpty = (step.expectedTriple > 0 ? 1 : 0)
                     + (step.expectedDouble > 0 ? 1 : 0)
                     + (step.expectedSingle > 0 ? 1 : 0)
        #expect(nonEmpty >= 2)
    }

    @Test("bucket counts sum to the number of surviving spots")
    func bucketCountsSumToN() throws {
        let allIDs = Set(fourSpots.map(\.id))
        let step = try #require(ScanOptimiser.recommend(
            surviving: allIDs,
            allCoords: fourSpots,
            range: 10,
            mapId: 0
        ))
        #expect(step.expectedTriple + step.expectedDouble + step.expectedSingle == fourSpots.count)
    }

    // MARK: expectedRemaining formula

    @Test("expectedRemaining equals (T²+D²+S²) / n")
    func expectedRemainingFormula() throws {
        let allIDs = Set(fourSpots.map(\.id))
        let step = try #require(ScanOptimiser.recommend(
            surviving: allIDs,
            allCoords: fourSpots,
            range: 10,
            mapId: 0
        ))
        let n = fourSpots.count
        let expected = Double(
            step.expectedTriple * step.expectedTriple
          + step.expectedDouble * step.expectedDouble
          + step.expectedSingle * step.expectedSingle
        ) / Double(n)
        #expect(abs(step.expectedRemaining - expected) < 1e-9)
    }

    // MARK: Travel cost preference

    @Test("playerPos biases recommendation toward the closer end of the region")
    func playerPosBiasesTowardCloserCandidate() throws {
        // Two spots 80 tiles apart with playerPos near the left spot.
        // Any informative position near the left end should be recommended
        // over an equally-informative one near the right end.
        let twoSpots: [(id: String, x: Int, y: Int)] = [("A", 0, 0), ("B", 80, 0)]
        let playerPos = (x: 4, y: 0)

        let step = try #require(ScanOptimiser.recommend(
            surviving: ["A", "B"],
            allCoords: twoSpots,
            range: 10,
            mapId: 0,
            playerPos: playerPos
        ))

        let distToPlayer = max(abs(step.x - playerPos.x), abs(step.y - playerPos.y))
        // The chosen step should be on the near half of the region (<40 tiles from player).
        #expect(distToPlayer < 40)
    }
}
