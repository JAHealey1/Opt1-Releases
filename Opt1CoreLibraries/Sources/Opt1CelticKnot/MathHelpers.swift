import Foundation

/// Small numerical helpers used by the Celtic knot rune-presence classifier.
enum MathHelpers {
    /// Plain dot product. Equivalent to cosine only when both inputs are
    /// already L2-normalized to unit length.
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
