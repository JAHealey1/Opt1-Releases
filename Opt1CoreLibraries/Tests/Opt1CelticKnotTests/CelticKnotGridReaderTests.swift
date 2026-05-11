import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Opt1CelticKnot
import Opt1Detection

@Suite("CelticKnotGridReader")
struct CelticKnotGridReaderTests {

    @Test("8-spot fixture identifies all runes and topology")
    func eightSpotFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "8_spot_capture_1", identifies: .eightSpot)
    }

    @Test("8-spot offset fixture identifies all runes and topology")
    func eightSpotOffsetFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "8_spot_capture_2", identifies: .eightSpot)
    }

    @Test("8-spot fixture with solved intersections identifies all runes and topology")
    func eightSpotSolvedIntersectionsFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "8_spot_solved_intersections_capture_1", identifies: .eightSpot)
    }

    @Test("8-spot-L fixture identifies all runes and topology")
    func eightSpotLFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "8_spot_l_capture_1", identifies: .eightSpotL)
    }

    @Test("8-spot-linked fixture identifies all runes and topology")
    func eightSpotLinkedFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "8_spot_linked_capture_1", identifies: .eightSpotLinked)
    }

    @Test("10-spot fixture identifies all runes and topology")
    func tenSpotFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "10_spot_capture_1", identifies: .tenSpot)
    }

    @Test("12-spot fixture identifies all runes and topology")
    func twelveSpotFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "12_spot_capture_1", identifies: .twelveSpot)
    }

    @Test("14-spot fixture identifies all runes and topology")
    func fourteenSpotFixtureIdentifiesExpectedTopology() throws {
        try assertFixture(named: "14_spot_capture_1", identifies: .fourteenSpot)
    }

    private func assertFixture(
        named fixtureName: String,
        identifies layoutType: CelticKnotLayoutType
    ) throws {
        let image = try loadFixture(named: fixtureName)
        let reader = try makeReader()
        let puzzleBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let runeArea = CGRect(
            x: 8,
            y: 33,
            width: puzzleBounds.width - 16,
            height: puzzleBounds.height - 71
        )

        let analysis = reader.analyze(
            in: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea
        )
        let debugDir = try writeDebugArtifacts(
            image: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            analysis: analysis,
            reader: reader,
            fixtureName: fixtureName
        )
        let metadata = CelticKnotLayoutMetadata.metadata(for: layoutType)
        let expectedRuneCount = metadata.laneLengths.reduce(0, +) - metadata.intersectionCount

        if analysis.failureReason != nil {
            #expect(
                Bool(false),
                "Expected successful grid analysis, got \(analysis.summaryLines.joined(separator: " | ")). Debug: \(debugDir.path)"
            )
            return
        }
        #expect(analysis.topology?.candidate == layoutType, "Debug: \(debugDir.path)")
        #expect(analysis.occupiedTileCount == expectedRuneCount, "Debug: \(debugDir.path)")
        #expect(analysis.lanes.count == metadata.trackCount, "Debug: \(debugDir.path)")
        #expect(analysis.lanes.map(\.tiles.count).sorted() == metadata.laneLengths.sorted(), "Debug: \(debugDir.path)")
        assertExpectedLanePointCycles(
            fixtureName: fixtureName,
            analysis: analysis,
            debugDir: debugDir
        )
        #expect(analysis.topology?.intersectionCount == metadata.intersectionCount, "Debug: \(debugDir.path)")
        if let layout = reader.makeLayout(from: analysis, puzzleBounds: puzzleBounds, layoutType: layoutType) {
            #expect(layout.clockwiseRotationSigns.count == metadata.trackCount, "Debug: \(debugDir.path)")
            #expect(layout.clockwiseRotationSigns.allSatisfy { $0 == 1 || $0 == -1 }, "Debug: \(debugDir.path)")
        } else {
            #expect(Bool(false), "Expected layout with direction metadata. Debug: \(debugDir.path)")
        }
    }

    private func assertExpectedLanePointCycles(
        fixtureName: String,
        analysis: CelticKnotGridReader.Analysis,
        debugDir: URL
    ) {
        guard let expected = expectedLanePointCycles[fixtureName] else {
            #expect(Bool(false), "Missing expected lane point cycles for \(fixtureName). Debug: \(debugDir.path)")
            return
        }

        let actual = Dictionary(
            uniqueKeysWithValues: analysis.lanes.map { lane in
                (lane.color, canonicalCycleKey(lane.tiles.map(\.point.description)))
            }
        )

        #expect(actual == expected, "Expected lane grid positions for \(fixtureName), got \(actual). Debug: \(debugDir.path)")
    }

    private func canonicalCycleKey(_ points: [String]) -> String {
        guard !points.isEmpty else { return "" }

        func rotations(of values: [String]) -> [String] {
            values.indices.map { index in
                (values[index...] + values[..<index]).joined(separator: " ")
            }
        }

        let forward = rotations(of: points)
        let reverse = rotations(of: points.reversed())
        return (forward + reverse).min() ?? points.joined(separator: " ")
    }

    private var expectedLanePointCycles: [String: [Int: String]] {
        [
            "8_spot_capture_1": canonicalLaneCycles([
                0: "(7,1) (8,0) (9,1) (10,2) (11,3) (12,4) (11,5) (10,6) (9,7) (8,8) (7,7) (6,6) (5,5) (4,4) (5,3) (6,2)",
                2: "(11,7) (12,6) (11,5) (10,4) (9,3) (8,2) (7,3) (6,4) (5,5) (4,6) (5,7) (6,8) (7,7) (8,6) (9,7) (10,8)",
                3: "(7,5) (6,4) (5,3) (4,2) (5,1) (4,0) (3,1) (2,2) (3,3) (2,4) (3,5) (2,6) (3,7) (4,8) (5,7) (6,6)",
            ]),
            "8_spot_capture_2": canonicalLaneCycles([
                0: "(8,0) (9,1) (10,2) (11,3) (12,4) (11,5) (10,6) (9,7) (8,8) (7,7) (6,6) (5,5) (4,4) (5,3) (6,2) (7,1)",
                2: "(8,6) (9,7) (10,8) (11,7) (12,6) (11,5) (10,4) (9,3) (8,2) (7,3) (6,4) (5,5) (4,6) (5,7) (6,8) (7,7)",
                3: "(5,1) (4,0) (3,1) (2,2) (3,3) (2,4) (3,5) (2,6) (3,7) (4,8) (5,7) (6,6) (7,5) (6,4) (5,3) (4,2)",
            ]),
            "8_spot_solved_intersections_capture_1": canonicalLaneCycles([
                0: "(8,0) (9,1) (10,2) (11,3) (12,4) (11,5) (10,6) (9,7) (8,8) (7,7) (6,6) (5,5) (4,4) (5,3) (6,2) (7,1)",
                2: "(11,7) (12,6) (11,5) (10,4) (9,3) (8,2) (7,3) (6,4) (5,5) (4,6) (5,7) (6,8) (7,7) (8,6) (9,7) (10,8)",
                3: "(7,5) (6,4) (5,3) (4,2) (5,1) (4,0) (3,1) (2,2) (3,3) (2,4) (3,5) (2,6) (3,7) (4,8) (5,7) (6,6)",
            ]),
            "8_spot_l_capture_1": canonicalLaneCycles([
                0: "(4,4) (3,3) (2,4) (3,5) (4,6) (5,7) (6,8) (7,9) (8,10) (9,9) (10,8) (9,7) (8,8) (7,7) (6,6) (5,5)",
                2: "(12,6) (11,5) (10,4) (9,3) (8,2) (7,1) (6,0) (5,1) (4,2) (5,3) (6,2) (7,3) (8,4) (9,5) (10,6) (11,7)",
                3: "(4,8) (3,7) (4,6) (5,5) (6,4) (7,3) (8,2) (9,1) (10,2) (11,3) (10,4) (9,5) (8,6) (7,7) (6,8) (5,9)",
            ]),
            "8_spot_linked_capture_1": canonicalLaneCycles([
                0: "(12,6) (11,5) (10,4) (9,5) (8,6) (7,7) (6,8) (7,9) (8,10) (9,9) (10,8) (11,7)",
                2: "(4,2) (5,1) (6,0) (7,1) (8,2) (7,3) (6,4) (5,5) (4,6) (3,5) (2,4) (3,3)",
                3: "(2,6) (3,5) (4,4) (5,5) (6,6) (7,7) (8,8) (7,9) (6,10) (5,9) (4,8) (3,7)",
                4: "(10,6) (9,5) (8,4) (7,3) (6,2) (7,1) (8,0) (9,1) (10,2) (11,3) (12,4) (11,5)",
            ]),
            "10_spot_capture_1": canonicalLaneCycles([
                0: "(5,4) (6,3) (7,2) (8,3) (9,4) (10,5) (11,6) (12,7) (11,8) (10,9) (9,10) (8,9) (7,8) (6,9) (5,10) (4,9) (3,8) (2,7) (3,6) (4,5)",
                2: "(4,1) (5,2) (6,3) (7,4) (8,3) (9,2) (10,1) (11,2) (12,3) (13,4) (12,5) (11,6) (10,7) (9,8) (8,9) (7,10) (6,9) (5,8) (4,7) (3,6) (2,5) (1,4) (2,3) (3,2)",
                3: "(10,3) (9,2) (8,1) (7,0) (6,1) (5,2) (4,3) (3,4) (4,5) (5,6) (6,7) (7,6) (8,7) (9,6) (10,5) (11,4)",
            ]),
            "12_spot_capture_1": canonicalLaneCycles([
                0: "(7,8) (6,7) (5,6) (4,5) (3,4) (4,3) (5,2) (6,1) (7,0) (8,1) (9,2) (10,3) (11,4) (10,5) (9,6) (8,7)",
                2: "(9,8) (8,7) (7,6) (6,5) (5,4) (4,3) (3,2) (4,1) (5,0) (6,1) (7,2) (8,3) (9,4) (10,5) (11,6) (10,7)",
                3: "(9,0) (10,1) (11,2) (10,3) (9,4) (8,5) (7,6) (6,7) (5,8) (4,7) (3,6) (4,5) (5,4) (6,3) (7,2) (8,1)",
            ]),
            "14_spot_capture_1": canonicalLaneCycles([
                0: "(12,6) (11,5) (10,4) (9,3) (8,2) (7,1) (6,2) (5,3) (4,4) (5,5) (6,6) (7,7) (8,8) (9,9) (10,8) (11,7)",
                2: "(5,9) (4,8) (3,7) (4,6) (5,5) (6,4) (7,5) (8,6) (7,7) (6,8)",
                3: "(7,9) (6,8) (5,7) (6,6) (7,5) (8,4) (9,3) (10,2) (11,3) (12,4) (11,5) (10,6) (11,7) (12,8) (11,9) (10,8) (9,7) (8,8)",
                4: "(7,3) (8,2) (9,1) (10,0) (11,1) (12,2) (11,3) (10,4) (9,5) (8,4)",
            ]),
        ]
    }

    private func canonicalLaneCycles(_ lanes: [Int: String]) -> [Int: String] {
        lanes.mapValues { canonicalCycleKey($0.split(separator: " ").map(String.init)) }
    }

    private func loadFixture(named name: String) throws -> CGImage {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CelticKnot/\(name).png")

        guard let source = CGImageSourceCreateWithURL(fixtureURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FixtureError.missingImage(fixtureURL.path)
        }
        return image
    }

    private func makeReader() throws -> CelticKnotGridReader {
        let testFile = URL(fileURLWithPath: #filePath)
        let modelURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PuzzleImages/celtic_knot_rune_model.json")

        guard let data = try? Data(contentsOf: modelURL),
              let artifact = try? JSONDecoder().decode(CelticKnotRuneModelArtifact.self, from: data)
        else {
            throw FixtureError.missingImage(modelURL.path)
        }
        return CelticKnotGridReader(artifact: artifact)
    }

    private func writeDebugArtifacts(
        image: CGImage,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        analysis: CelticKnotGridReader.Analysis,
        reader: CelticKnotGridReader,
        fixtureName: String
    ) throws -> URL {
        let debugDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Opt1CelticKnotGridReaderTests", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)

        try? FileManager.default.removeItem(at: debugDir)
        try FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)

        let renderer = CelticKnotDebugRenderer()
        renderer.saveGridAnalysisDebug(
            image: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            gridAnalysis: analysis,
            to: debugDir
        )

        if let layoutType = analysis.topology?.candidate,
           let layout = reader.makeLayout(from: analysis, puzzleBounds: puzzleBounds, layoutType: layoutType) {
            renderer.saveDebugImages(
                image: image,
                puzzleBounds: puzzleBounds,
                runeArea: runeArea,
                layoutType: layoutType,
                layout: layout,
                gridAnalysis: analysis,
                to: debugDir
            )
        }

        return debugDir
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case missingImage(String)

        var description: String {
            switch self {
            case .missingImage(let path):
                return "Missing fixture image at \(path)"
            }
        }
    }
}
