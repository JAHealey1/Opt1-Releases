import Foundation
import CoreGraphics

/// A compass bearing that carries its own uncertainty.
///
/// Internally we store the angle in the "math" convention used by the
/// calibration tables we ported from
/// [Leridon/cluetrainer](https://github.com/Leridon/cluetrainer) — i.e.
/// radians measured **CCW from East** (`0 = East`, `π/2 = North`, `π = West`,
/// `3π/2 = South`). This matches `ANGLE_REFERENCE_VECTOR = {x: 1, y: 0}` and
/// the `Vector2.angle(ref, {x, -y})` convention in `Compasses.ts`.
///
/// We expose convenience accessors that convert to the **compass bearing**
/// convention (degrees CW from North, `0 = N`, `90 = E`) used everywhere else
/// in this project (overlay rendering, triangulation, etc.).
public struct UncertainAngle: Equatable {
    /// Median of the angle in radians, math convention (CCW from East).
    /// Always in `[0, 2π)`.
    public var medianMathRadians: Double
    /// Half-width of the uncertainty interval in radians, ≥ 0.
    public var epsilonRadians: Double

    public init(medianMathRadians: Double, epsilonRadians: Double) {
        self.medianMathRadians = UncertainAngle.normalize(medianMathRadians)
        self.epsilonRadians = max(0, epsilonRadians)
    }

    /// Build an `UncertainAngle` from an inclusive math-radians range
    /// `[fromRad, toRad]` going CCW. Handles wrap-around across 0/2π.
    public static func fromMathRange(fromRad: Double, toRad: Double) -> UncertainAngle {
        let from = normalize(fromRad)
        let to   = normalize(toRad)
        var width = to - from
        if width < 0 { width += 2 * .pi }
        let median = normalize(from + width / 2)
        return UncertainAngle(medianMathRadians: median, epsilonRadians: width / 2)
    }

    public static func normalize(_ rad: Double) -> Double {
        var x = rad.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x
    }

    // MARK: - Bearing-convention accessors (degrees CW from North)

    /// Compass bearing in degrees, `[0, 360)`, CW from North.
    public var bearingDegrees: Double {
        let rad = .pi / 2 - medianMathRadians
        var deg = rad * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Half-width of the uncertainty interval in degrees.
    public var epsilonDegrees: Double { epsilonRadians * 180 / .pi }

    /// Median bearing in radians, CW from North.
    public var bearingRadians: Double {
        let r = .pi / 2 - medianMathRadians
        let two = 2 * Double.pi
        var x = r.truncatingRemainder(dividingBy: two)
        if x < 0 { x += two }
        return x
    }

    /// Lower & upper bearing-degree bounds (`bearingDegrees ± epsilonDegrees`),
    /// not normalised — the caller is expected to wrap if needed.
    public var bearingRangeDegrees: (lower: Double, upper: Double) {
        let b = bearingDegrees
        let e = epsilonDegrees
        return (b - e, b + e)
    }

    /// Unit direction vector in screen-space (RuneScape map: `+x = East`, `+y = North`).
    /// Useful for ray casting in tile space.
    public func bearingDirectionVector() -> (dx: Double, dy: Double) {
        let rad = bearingRadians
        return (sin(rad), cos(rad))
    }

    /// Unit direction vector at the lower / upper edges of the beam.
    public func edgeDirectionVectors() -> (lo: (dx: Double, dy: Double),
                                    hi: (dx: Double, dy: Double)) {
        let mid = bearingRadians
        let e   = epsilonRadians
        let loR = mid - e
        let hiR = mid + e
        return ((sin(loR), cos(loR)), (sin(hiR), cos(hiR)))
    }

    /// Returns true if the given math-radian angle is inside this uncertainty
    /// interval, taking wrap-around into account.
    public func contains(mathRadians angle: Double) -> Bool {
        let a = UncertainAngle.normalize(angle)
        let lo = UncertainAngle.normalize(medianMathRadians - epsilonRadians)
        let hi = UncertainAngle.normalize(medianMathRadians + epsilonRadians)
        if lo <= hi {
            return a >= lo && a <= hi
        } else {
            return a >= lo || a <= hi
        }
    }

    /// Convenience formatter, e.g. `"74.2° ±0.3°"`.
    public func formatted(decimals: Int = 1) -> String {
        let bd = bearingDegrees
        let ed = epsilonDegrees
        return String(format: "%.\(decimals)f° ±%.\(decimals)f°", bd, ed)
    }
}
