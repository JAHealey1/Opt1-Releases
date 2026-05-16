import CoreGraphics

// MARK: - Polygon geometry utilities

/// Ray-casting point-in-polygon test (crossing-number algorithm).
///
/// Works in any 2-D coordinate system; coordinates are game-tile `CGFloat`s
/// when used by the elite-compass dig-spot snap logic.
///
/// Returns `true` when `pt` falls strictly inside `polygon`; edge / vertex
/// hits are treated as outside, which is acceptable for sub-tile precision.
func pointInPolygon(_ pt: CGPoint, polygon: [CGPoint]) -> Bool {
    var crossings = 0
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i]
        let b = polygon[(i + 1) % n]
        if (a.y <= pt.y && b.y > pt.y) || (b.y <= pt.y && a.y > pt.y) {
            let xIntersect = a.x + (pt.y - a.y) / (b.y - a.y) * (b.x - a.x)
            if pt.x < xIntersect { crossings += 1 }
        }
    }
    return crossings % 2 != 0
}
