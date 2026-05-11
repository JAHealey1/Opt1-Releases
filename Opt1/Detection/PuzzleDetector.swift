import CoreGraphics
import Foundation

/// Common shape for detectors that turn a captured image into an optional
/// domain result. Lets tests and pipelines treat image-in/output-out detectors
/// uniformly (e.g. swap in a fake that returns a known state).
///
/// Each conformer binds `Output` to its own result type — for most detectors
/// this is the solver-ready puzzle state (LockboxState, TowersState, …), for
/// Celtic Knot it's the located puzzle geometry that drives the subsequent
/// rune classification pass, and for Elite Compass it's the bearing reading.
///
/// `PuzzleBoxDetector` intentionally does NOT conform — its entry point
/// (`detectInSnipCrop`) needs additional knobs (preferred reference key,
/// hint-assisted retry reference image, progress callback) and returns a
/// richer outcome enum, so there's nothing useful to be gained by squeezing
/// it through a single-argument protocol.
///
/// Conformances live next to each detector's implementation:
///   - `LockboxDetector`        (LockboxDetector.swift)
///   - `TowersDetector`         (TowersDetector.swift)
///   - `CelticKnotDetector`     (CelticKnotDetector.swift)
///   - `EliteCompassDetector`   (EliteCompassDetector.swift)
protocol PuzzleDetector {
    associatedtype Output

    func detect(in image: CGImage) async -> Output?
}
