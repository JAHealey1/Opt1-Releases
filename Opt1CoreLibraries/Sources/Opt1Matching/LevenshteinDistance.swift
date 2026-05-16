import Foundation

// MARK: - Levenshtein edit distance

/// Shared Unicode-scalar Levenshtein implementation for OCR-adjacent string
/// comparison. Scalar-based distances avoid UTF-8 byte-length artefacts
/// (multi-byte substitutions counting as multiple edits).
public enum LevenshteinDistance {

    public static func unicodeScalars(_ a: String, _ b: String) -> Int {
        unicodeScalars(Array(a.unicodeScalars), Array(b.unicodeScalars))
    }

    /// When callers already split strings into scalars, reuse them to avoid
    /// reallocating scalar arrays — e.g. `FuzzyMatcher.levenshteinSimilarity`.
    public static func unicodeScalars(_ s: [Unicode.Scalar], _ t: [Unicode.Scalar]) -> Int {
        let m = s.count, n = t.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = Swift.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
