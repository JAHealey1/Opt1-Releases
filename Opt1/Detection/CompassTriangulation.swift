import Foundation
import SwiftUI
import Opt1Detection

/// A bearing line originating from a known game-world position.
///
/// The bearing is an `UncertainAngle` (median ± epsilon). The half-width
/// epsilon defines a wedge ("beam") rather than a single ray; downstream
/// rendering and intersection use this to draw and intersect polygons.
struct BearingLine: Identifiable {
    let id = UUID()
    /// Origin in RS3 game-tile coordinates.
    let origin: CGPoint
    /// Bearing as an UncertainAngle (median ± epsilon, compass convention).
    let bearing: UncertainAngle
    /// Optional radius (in tiles) of uncertainty around the origin point.
    /// Reserved for teleport-aware origins; not yet wired into intersection.
    var originUncertaintyTiles: Double = 0
}

/// A polygonal region computed by intersecting two bearing beams. Up to 4
/// vertices ordered to form a convex quadrilateral (the lens of the
/// uncertainty wedges). May be empty if the beams do not intersect (e.g.
/// nearly parallel) or if both epsilons are zero (degenerate ray case).
struct IntersectionRegion {
    /// Polygon vertices in tile coordinates, ordered around the polygon.
    var polygon: [CGPoint]
    /// Centroid of the polygon — used for pin placement / readout.
    var centroid: CGPoint
}

/// Observable state for the Elite compass triangulation workflow.
///
/// Holds zero or more confirmed bearing lines (origin + UncertainAngle), an
/// optional pending bearing (detected but not yet anchored to a position),
/// and the computed intersection polygon of the most recent two lines.
@MainActor
final class CompassTriangulationState: ObservableObject {
    /// Called when the user taps the close button on the overlay.
    var onClose: (() -> Void)?

    /// Confirmed bearing lines (origin placed by double-click).
    @Published var bearings: [BearingLine] = []
    /// Bearing detected from the arrow but not yet anchored to a map position.
    @Published var pendingBearing: UncertainAngle? = nil
    /// Polygonal intersection region of the last two bearing lines, nil if
    /// < 2 lines or the wedges don't overlap.
    @Published var intersectionRegion: IntersectionRegion? = nil
    /// True when the compass scroll's region label was detected as "EASTERN LANDS",
    /// indicating a master Arc clue. Drives map auto-centering on The Arc and
    /// selects the Arc auto-triangulation calibration points when available.
    @Published var isEasternLands: Bool = false

    /// UI toggle: when true, the overlay map renders every known surface
    /// compass dig spot as a faint pin so the user can eyeball them.
    /// Persisted across launches via `UserDefaults`.
    @Published var showAllDigSpots: Bool = AppSettings.eliteCompassShowAllDigSpots {
        didSet { AppSettings.eliteCompassShowAllDigSpots = showAllDigSpots }
    }

    /// Convenience: centroid of the current intersection region (existing pin
    /// animations and overlays still want a single point).
    var intersection: CGPoint? { intersectionRegion?.centroid }

    /// Record a newly-detected arrow bearing.  Becomes "pending" until the user
    /// double-clicks on the map to set the origin.
    func addBearing(_ angle: UncertainAngle) {
        pendingBearing = angle
    }

    /// Anchor the current pending bearing at the given game-tile position.
    func setOriginForPending(gameX: Int, gameY: Int) {
        guard let bearing = pendingBearing else { return }
        let line = BearingLine(
            origin: CGPoint(x: CGFloat(gameX), y: CGFloat(gameY)),
            bearing: bearing
        )
        bearings.append(line)
        pendingBearing = nil
        print("[Opt1] Bearing anchored: origin=(\(gameX), \(gameY)), bearing=\(bearing.formatted())")
        recomputeIntersection()
    }

    /// Clear everything and start over.
    func reset() {
        bearings.removeAll()
        pendingBearing = nil
        intersectionRegion = nil
        isEasternLands = false
    }

    // MARK: - Intersection

    /// Recomputes the intersection of the two most recent bearing lines.
    private func recomputeIntersection() {
        guard bearings.count >= 2 else {
            intersectionRegion = nil
            return
        }
        let a = bearings[bearings.count - 2]
        let b = bearings[bearings.count - 1]
        intersectionRegion = Self.intersect(a, b)
        if let region = intersectionRegion {
            print("[Opt1] Intersection polygon: \(region.polygon.count) vertices, centroid=(\(Int(region.centroid.x)), \(Int(region.centroid.y))) from \(a.bearing.formatted())@(\(Int(a.origin.x)),\(Int(a.origin.y))) + \(b.bearing.formatted())@(\(Int(b.origin.x)),\(Int(b.origin.y)))")
        } else {
            print("[Opt1] No intersection (nearly parallel beams or non-overlapping wedges)")
        }
    }

    /// Compute the polygonal intersection of two bearing wedges.
    ///
    /// Each beam is bounded by two edges at `median ± epsilon`. We intersect
    /// the four edge pairs; if all four intersections lie in the forward
    /// direction of both rays they form a convex quadrilateral. We accept any
    /// 2–4 valid forward intersections and order them around the centroid.
    static func intersect(_ a: BearingLine, _ b: BearingLine) -> IntersectionRegion? {
        // Use raw degree midpoints to pick up nearly-parallel beams.
        let diff = abs(a.bearing.bearingDegrees - b.bearing.bearingDegrees)
            .truncatingRemainder(dividingBy: 180)
        if diff < 2 || diff > 178 { return nil }

        let aEdges = a.bearing.edgeDirectionVectors()
        let bEdges = b.bearing.edgeDirectionVectors()

        let aDirs = [aEdges.lo, aEdges.hi]
        let bDirs = [bEdges.lo, bEdges.hi]

        var hits: [CGPoint] = []
        for da in aDirs {
            for db in bDirs {
                if let hit = forwardIntersection(
                    originA: a.origin, dirA: da,
                    originB: b.origin, dirB: db
                ) {
                    hits.append(hit)
                }
            }
        }

        // Need at least two valid intersection vertices to define a region.
        guard hits.count >= 2 else {
            // Degenerate: zero-epsilon rays — fall back to single-point intersect.
            if let p = forwardIntersection(
                originA: a.origin,
                dirA: a.bearing.bearingDirectionVector(),
                originB: b.origin,
                dirB: b.bearing.bearingDirectionVector()
            ) {
                return IntersectionRegion(polygon: [p], centroid: p)
            }
            return nil
        }

        let cx = hits.reduce(0) { $0 + Double($1.x) } / Double(hits.count)
        let cy = hits.reduce(0) { $0 + Double($1.y) } / Double(hits.count)
        let centroid = CGPoint(x: cx, y: cy)

        let ordered = hits.sorted {
            atan2(Double($0.y) - cy, Double($0.x) - cx) <
            atan2(Double($1.y) - cy, Double($1.x) - cx)
        }

        return IntersectionRegion(polygon: ordered, centroid: centroid)
    }

    /// Intersection of two rays — only returns a hit if it lies in the
    /// forward half-line of both rays (parameters t, u ≥ 0). Returns nil for
    /// near-parallel pairs.
    private static func forwardIntersection(
        originA: CGPoint, dirA: (dx: Double, dy: Double),
        originB: CGPoint, dirB: (dx: Double, dy: Double)
    ) -> CGPoint? {
        let denom = dirA.dx * dirB.dy - dirA.dy * dirB.dx
        guard abs(denom) > 1e-9 else { return nil }

        let ox = Double(originB.x - originA.x)
        let oy = Double(originB.y - originA.y)

        let t = (ox * dirB.dy - oy * dirB.dx) / denom
        let u = (ox * dirA.dy - oy * dirA.dx) / denom

        guard t >= 0, u >= 0 else { return nil }

        let ix = Double(originA.x) + t * dirA.dx
        let iy = Double(originA.y) + t * dirA.dy
        return CGPoint(x: ix, y: iy)
    }
}
