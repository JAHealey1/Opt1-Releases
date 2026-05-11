import CoreGraphics
import Foundation
import Vision

// MARK: - Math helpers

/// Small numerical helpers shared by detectors and classifiers.
enum MathHelpers {
    /// Numerically stable softmax. Returns an empty array for empty input, or a
    /// zero vector when all exponentials collapse to zero.
    static func softmax(_ values: [Float]) -> [Float] {
        guard let maxV = values.max() else { return [] }
        let exps = values.map { expf($0 - maxV) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else { return [Float](repeating: 0, count: values.count) }
        return exps.map { $0 / sum }
    }

    /// Cosine similarity of two float vectors. Uses `min(a.count, b.count)` so a
    /// length mismatch compares the shared prefix rather than returning zero.
    /// Returns 0 when either vector is empty or has zero magnitude.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let den = sqrt(na) * sqrt(nb)
        return den > 0 ? dot / den : 0
    }

    /// Plain dot product. **Equivalent to `cosine` only when both inputs are
    /// L2-normalized to unit length.** Skips the per-call norm computation and
    /// sqrt that `cosine` performs, so it's roughly 3× cheaper in the inner
    /// loop. Use only at call sites where you can guarantee L2-normalized
    /// inputs on both sides (e.g. embeddings produced by
    /// `PuzzleEmbeddingExtractor` and references trained by the matching
    /// Python pipeline, which both end with `l2normalize(...)`).
    static func dotNormalized(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
        }
        return dot
    }
}

// MARK: - Vision helpers

/// Shared Vision-framework wrappers used by the detection and matching pipelines.
enum VisionHelpers {
    /// Computes a FeaturePrint embedding for `image`. Returns nil when Vision fails.
    static func featurePrint(of image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// Per-channel RGB histogram of `image` downsampled to 64×64, concatenated as
    /// `[R…, G…, B…]` with length `bins * 3` and normalised by the pixel count.
    static func rgbHistogram(_ image: CGImage, bins: Int) -> [Float] {
        let side = 64
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [Float](repeating: 0, count: bins * 3) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return [Float](repeating: 0, count: bins * 3) }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var hist = [Float](repeating: 0, count: bins * 3)
        for i in 0..<(side * side) {
            let r = Int(raw[i * 4]), g = Int(raw[i * 4 + 1]), b = Int(raw[i * 4 + 2])
            hist[r * bins / 256] += 1
            hist[bins + g * bins / 256] += 1
            hist[bins * 2 + b * bins / 256] += 1
        }
        let scale = 1.0 / Float(side * side)
        return hist.map { $0 * scale }
    }
}

// MARK: - Bundle manifest loader

enum PuzzleManifest {
    /// Loads `PuzzleImages/manifest.json` from the main bundle as an array of
    /// string dictionaries (e.g. `[{"key": ..., "displayName": ...}, ...]`).
    static func load() -> [[String: String]]? {
        guard let url = Bundle.main.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "PuzzleImages"
        ),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return nil }
        return arr
    }
}
