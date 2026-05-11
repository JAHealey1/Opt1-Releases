import AppKit
import CoreGraphics
import Foundation

final class DatasetWriter {
    private let config: PuzzleCollectionConfig
    private let capturesDir: URL
    private let labelsDir: URL
    private let sessionId: String
    private let filePrefix: String
    private(set) var nextIndex: Int

    init(config: PuzzleCollectionConfig) throws {
        self.config = config
        self.sessionId = ISO8601DateFormatter().string(from: Date())
        self.filePrefix = DatasetWriter.makeFilePrefix(config.puzzle.displayName)

        self.capturesDir = config.outputRoot.appendingPathComponent("captures", isDirectory: true)
        self.labelsDir = config.outputRoot.appendingPathComponent("labels", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelsDir, withIntermediateDirectories: true)

        self.nextIndex = DatasetWriter.computeNextIndex(prefix: filePrefix, in: capturesDir)
    }

    struct WriteResult {
        let index: Int
        let imageURL: URL
        let labelURL: URL
    }

    func writeCapture(
        _ image: CGImage,
        phase: PuzzleCollectionPhase,
        phaseIndex: Int,
        roiNormalized: CGRect,
        sourceWindowSize: CGSize
    ) throws -> WriteResult {
        let index = nextIndex

        let stem = "\(filePrefix)_\(String(format: "%03d", index))"
        let imageURL = capturesDir.appendingPathComponent(stem).appendingPathExtension("png")
        let labelURL = labelsDir.appendingPathComponent(stem).appendingPathExtension("json")

        try writePNGAtomic(image, to: imageURL)
        try writeLabelAtomic(
            to: labelURL,
            payload: [
                "puzzle_id": config.puzzle.key,
                "puzzle_kind": config.puzzle.kind.rawValue,
                "hint_state": phase.rawValue,
                "session_id": sessionId,
                "phase_index": phaseIndex,
                "captured_at": ISO8601DateFormatter().string(from: Date()),
                "roi_normalized": [
                    "x": roiNormalized.minX,
                    "y": roiNormalized.minY,
                    "width": roiNormalized.width,
                    "height": roiNormalized.height
                ],
                "window_size": [
                    "width": sourceWindowSize.width,
                    "height": sourceWindowSize.height
                ]
            ]
        )

        nextIndex += 1

        return WriteResult(index: index, imageURL: imageURL, labelURL: labelURL)
    }

    private func writePNGAtomic(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "DatasetWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private func writeLabelAtomic(to url: URL, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private static func computeNextIndex(prefix: String, in directory: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 1 }
        var maxIndex = 0
        let pattern = "^\(NSRegularExpression.escapedPattern(for: prefix))_(\\d+)\\.png$"
        let regex = try? NSRegularExpression(pattern: pattern)
        for name in names {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex?.firstMatch(in: name, range: range),
                  match.numberOfRanges >= 2,
                  let idxRange = Range(match.range(at: 1), in: name),
                  let idx = Int(name[idxRange]) else { continue }
            maxIndex = max(maxIndex, idx)
        }
        return maxIndex + 1
    }

    private static func makeFilePrefix(_ displayName: String) -> String {
        let parts = displayName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if parts.isEmpty { return "Puzzle" }
        return parts.map { part in
            let lower = part.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined()
    }
}
