import CoreGraphics
import Foundation

/// Finds parchment-coloured regions in a RuneScape screenshot.
///
/// Shared between `EliteCompassDetector` (compass needle scroll) and
/// `ClueScrollPipeline.matchScanWithoutScroll` (scan clue sticky UI),
/// both of which target the same compact parchment format.
struct ParchmentLocator {

    // MARK: - Pixel Classification

    /// Parchment / tan scroll background colour predicate.
    static func isParchment(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        r >= 140 && r <= 235 &&
        g >= 120 && g <= 210 &&
        b >= 50  && b <= 150 &&
        r > g && g > b &&
        (Int(r) - Int(b)) >= 30
    }

    // MARK: - Pixel Buffer

    func renderToRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return pixels
    }

    // MARK: - Cluster Data

    /// A connected component of densely parchment-coloured grid cells.
    struct Cluster {
        /// Bounding rect in image-pixel coordinates.
        let bounds: CGRect
        /// Number of grid cells in the component.
        let cellCount: Int
        /// Individual grid-cell positions (row/column indices). Used for debug visualisation.
        let cells: [(gx: Int, gy: Int)]
    }

    /// Full output of a single parchment-scan pass.
    struct ScanResult {
        let totalParchmentPixels: Int
        /// Raw pixel counts per grid cell. `densityGrid[gy][gx]` = parchment pixel count in that cell.
        let densityGrid: [[Int]]
        let gridW: Int
        let gridH: Int
        let clusters: [Cluster]
    }

    // MARK: - Cluster Finding

    /// Single-pass parchment scan: builds a density grid, then BFS-labels connected clusters.
    /// Returns all clusters with no size or aspect-ratio filtering applied.
    ///
    /// - Parameters:
    ///   - pixels: RGBA pixel buffer obtained from `renderToRGBA`.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - cellSize: Grid cell side length in pixels.
    func scan(pixels: [UInt8], width: Int, height: Int, cellSize: Int = 32) -> ScanResult {
        let w = width, h = height
        let gridW = (w + cellSize - 1) / cellSize
        let gridH = (h + cellSize - 1) / cellSize
        let cellArea = Double(cellSize * cellSize)
        let minDensity = 0.25

        // ── Pass 1: count parchment pixels per grid cell ──
        var grid = [[Int]](repeating: [Int](repeating: 0, count: gridW), count: gridH)
        var totalParchment = 0
        for y in 0..<h {
            let row = y * w * 4
            let gy = y / cellSize
            for x in 0..<w {
                let i = row + x * 4
                if Self.isParchment(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]) {
                    grid[gy][x / cellSize] += 1
                    totalParchment += 1
                }
            }
        }

        // ── Collect dense cells ──
        var unvisited = Set<Int>()
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                if Double(grid[gy][gx]) / cellArea >= minDensity {
                    unvisited.insert(gy * gridW + gx)
                }
            }
        }

        // ── BFS connected-component labelling ──
        var clusters: [Cluster] = []
        while let seed = unvisited.first {
            unvisited.remove(seed)
            var cells: [(gx: Int, gy: Int)] = []
            var queue = [seed]
            while !queue.isEmpty {
                let idx = queue.removeFirst()
                let gy = idx / gridW, gx = idx % gridW
                cells.append((gx, gy))
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = gx + dx, ny = gy + dy
                        guard nx >= 0, nx < gridW, ny >= 0, ny < gridH else { continue }
                        let nidx = ny * gridW + nx
                        if unvisited.contains(nidx) {
                            unvisited.remove(nidx)
                            queue.append(nidx)
                        }
                    }
                }
            }

            let minX = cells.map { $0.gx * cellSize }.min()!
            let maxX = min(w - 1, cells.map { ($0.gx + 1) * cellSize - 1 }.max()!)
            let minY = cells.map { $0.gy * cellSize }.min()!
            let maxY = min(h - 1, cells.map { ($0.gy + 1) * cellSize - 1 }.max()!)

            clusters.append(Cluster(
                bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                cellCount: cells.count,
                cells: cells
            ))
        }

        return ScanResult(
            totalParchmentPixels: totalParchment,
            densityGrid: grid,
            gridW: gridW,
            gridH: gridH,
            clusters: clusters
        )
    }

    /// Convenience: renders `image` to RGBA and scans in one call.
    func scan(in image: CGImage, cellSize: Int = 32) -> ScanResult? {
        guard let pixels = renderToRGBA(image) else { return nil }
        return scan(pixels: pixels, width: image.width, height: image.height, cellSize: cellSize)
    }

    // MARK: - Compact Scroll Detection

    /// Reference scroll height (px) at 100% NXT UI scale.
    /// Source: `CapturedCompass.UI_SIZE.y` in ClueTrainer — the compact scan
    /// sticky UI is the same size as the compass parchment.
    private let referenceScrollH = 259.0

    /// Returns the bounding rect of the most likely compact scan / compass scroll,
    /// or `nil` if none is found. Applies scale-aware size caps and the same
    /// 0.30–0.85 aspect-ratio filter as `EliteCompassDetector`.
    ///
    /// Used by `ClueScrollPipeline.matchScanWithoutScroll` to crop the OCR target
    /// to the small parchment region instead of running OCR over the full frame.
    func bestCompactScrollRect(in image: CGImage) -> CGRect? {
        guard let result = scan(in: image) else { return nil }
        let w = image.width

        let uiScale   = Double(AppSettings.puzzleUIScalePercent) / 100.0
        let maxScrollH = Int((referenceScrollH * uiScale * 1.20).rounded(.up))

        var best: (score: Double, bounds: CGRect)?

        let cellArea = Double(32 * 32)   // matches the default cellSize passed to scan()
        for cluster in result.clusters {
            guard cluster.cellCount >= 6 else { continue }

            let bw = Int(cluster.bounds.width)
            let bh = Int(cluster.bounds.height)

            guard bw >= 40, bh >= 40 else { continue }
            guard bw <= w / 5, bh <= maxScrollH else { continue }

            let aspect = Double(bw) / Double(bh)
            guard aspect >= 0.30, aspect <= 0.85 else { continue }

            // Aggregate fill-density guard: parchment pixels across all cluster
            // cells divided by the total cluster cell area. Real parchment UI
            // panels are near-solid fills (~0.70+); terrain textures like
            // cobblestone that happen to share warm-tan tones are patchy (~0.10–0.25)
            // and are rejected here.
            let parchmentPixels = cluster.cells.reduce(0) {
                $0 + result.densityGrid[$1.gy][$1.gx]
            }
            let fillRatio = Double(parchmentPixels) / (Double(cluster.cellCount) * cellArea)
            guard fillRatio >= 0.45 else { continue }

            // Prefer taller scrolls (more content) and aspect ratios near 0.5.
            let aspectScore = max(0.0, 1.0 - abs(aspect - 0.5) * 4.0)
            let sizeScore   = Double(cluster.cellCount)
            let score       = aspectScore + sizeScore * 0.01

            if best == nil || score > best!.score {
                best = (score, cluster.bounds)
            }
        }

        return best?.bounds
    }
}
