import CoreGraphics
import Foundation
import Opt1Solvers

/// Pure coordinate-math helpers for mapping between the overlay's normalised
/// snip rect (origin bottom-left, AppKit convention) and image pixels, and
/// for scaling an image-space `PuzzleBoxSolution` out to screen points for
/// the overlay window.
///
/// Lifted out of `ClueOrchestrator` so the two duplicate copies that used to
/// live in `PuzzleDataCollectionController` / `CelticKnotDataCollectionController`
/// can share a single implementation, and so the math is unit-testable without
/// spinning up a full orchestrator.
enum SnipCoordinateMapper {

    /// Converts a normalised snip rect (0…1, bottom-left origin — AppKit screen
    /// convention produced by the snip overlay) into an image-pixel `CGRect`
    /// (top-left origin — Core Graphics image convention). The result is
    /// clamped to the image bounds and snapped to integer pixels.
    static func normalizedSnipToImagePixels(_ normalized: CGRect, imageSize: CGSize) -> CGRect {
        let x1 = max(0, min(imageSize.width,  normalized.minX * imageSize.width))
        let x2 = max(0, min(imageSize.width,  normalized.maxX * imageSize.width))
        let y1 = max(0, min(imageSize.height, (1.0 - normalized.maxY) * imageSize.height))
        let y2 = max(0, min(imageSize.height, (1.0 - normalized.minY) * imageSize.height))
        let px1 = floor(x1), py1 = floor(y1), px2 = ceil(x2), py2 = ceil(y2)
        return CGRect(x: px1, y: py1, width: max(0, px2 - px1), height: max(0, py2 - py1))
    }

    /// Scales a puzzle-box solution from image-pixel coordinates out to the
    /// on-screen window frame. The incoming `gridBoundsOnScreen` is actually
    /// image-space (name is historical — retained because several persisted
    /// call sites assume it); the returned solution has genuine screen-space
    /// bounds. A small inset accounts for the rendered grid border.
    static func scaleSolutionToScreen(
        _ solution: PuzzleBoxSolution,
        imageSize: CGSize,
        windowFrame: CGRect
    ) -> PuzzleBoxSolution {
        let scaleX = windowFrame.width  / imageSize.width
        let scaleY = windowFrame.height / imageSize.height

        let borderInset: CGFloat = 4
        let g = solution.gridBoundsOnScreen.insetBy(dx: borderInset, dy: borderInset)

        let screenGrid = CGRect(
            x:      windowFrame.minX + g.minX * scaleX,
            y:      windowFrame.minY + g.minY * scaleY,
            width:  g.width  * scaleX,
            height: g.height * scaleY
        )
        let screenCell = CGSize(
            width:  solution.cellSize.width  * scaleX,
            height: solution.cellSize.height * scaleY
        )

        print("[Opt1] scaleSolutionToScreen: image=\(imageSize) window=\(windowFrame) " +
              "scale=(\(scaleX),\(scaleY)) gridImage=\(solution.gridBoundsOnScreen) " +
              "gridScreen=\(screenGrid)")

        return PuzzleBoxSolution(
            moves:              solution.moves,
            gridBoundsOnScreen: screenGrid,
            cellSize:           screenCell,
            puzzleName:         solution.puzzleName
        )
    }
}
