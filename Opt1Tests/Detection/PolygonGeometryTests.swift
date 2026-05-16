import Testing
import CoreGraphics
@testable import Opt1

@Suite("pointInPolygon")
struct PolygonGeometryTests {

    // Axis-aligned unit square with vertices (0,0) (1,0) (1,1) (0,1).
    private let unitSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1),
        CGPoint(x: 0, y: 1),
    ]

    // MARK: - Inside

    @Test("Centre of unit square is inside")
    func centreIsInside() {
        #expect(pointInPolygon(CGPoint(x: 0.5, y: 0.5), polygon: unitSquare))
    }

    @Test("Points clearly inside a triangle are detected", arguments: [
        CGPoint(x: 1, y: 1),
        CGPoint(x: 2, y: 1),
        CGPoint(x: 1.5, y: 1.5),
    ] as [CGPoint])
    func triangleInteriorDetected(pt: CGPoint) {
        let triangle: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 3, y: 0),
            CGPoint(x: 1.5, y: 3),
        ]
        #expect(pointInPolygon(pt, polygon: triangle))
    }

    // MARK: - Outside

    @Test("Points outside the unit square are not inside", arguments: [
        CGPoint(x: -0.1, y: 0.5),
        CGPoint(x:  1.1, y: 0.5),
        CGPoint(x:  0.5, y: -0.1),
        CGPoint(x:  0.5, y:  1.1),
        CGPoint(x:  2.0, y:  2.0),
    ] as [CGPoint])
    func outsideUnitSquareNotInside(pt: CGPoint) {
        #expect(!pointInPolygon(pt, polygon: unitSquare))
    }

    // MARK: - Edge cases

    @Test("Empty polygon returns false")
    func emptyPolygon() {
        #expect(!pointInPolygon(CGPoint(x: 0, y: 0), polygon: []))
    }

    @Test("Single-point polygon returns false")
    func singlePointPolygon() {
        #expect(!pointInPolygon(CGPoint(x: 0, y: 0), polygon: [CGPoint(x: 0, y: 0)]))
    }

    @Test("Non-convex (L-shaped) polygon correctly classifies inside vs outside")
    func nonConvexPolygon() {
        // L-shape: bottom-left 2×2, top-right 1×1 notch removed
        let lShape: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2, y: 0),
            CGPoint(x: 2, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 2),
            CGPoint(x: 0, y: 2),
        ]
        // Inside (bottom strip)
        #expect( pointInPolygon(CGPoint(x: 1.5, y: 0.5), polygon: lShape))
        // Inside (left strip)
        #expect( pointInPolygon(CGPoint(x: 0.5, y: 1.5), polygon: lShape))
        // Outside (the removed notch corner)
        #expect(!pointInPolygon(CGPoint(x: 1.5, y: 1.5), polygon: lShape))
    }
}
