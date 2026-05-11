import CoreGraphics
import Foundation
import Opt1CelticKnot

// MARK: - CelticKnotDetector debug outputs

extension CelticKnotDetector {

    static var debugTrackFilter: [Int]? {
        get { CelticKnotDebugRenderer.debugTrackFilter }
        set { CelticKnotDebugRenderer.debugTrackFilter = newValue }
    }

    func drawTemplateOverlay(
        on image: CGImage,
        puzzleBounds: CGRect,
        layout: CelticKnotLayout
    ) -> CGImage? {
        CelticKnotDebugRenderer().drawTemplateOverlay(
            on: image,
            puzzleBounds: puzzleBounds,
            layout: layout
        )
    }

    func saveDebugImages(
        image: CGImage,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        layoutType: CelticKnotLayoutType,
        layout: CelticKnotLayout,
        gridAnalysis: CelticKnotGridReader.Analysis? = nil,
        to dir: URL
    ) {
        CelticKnotDebugRenderer().saveDebugImages(
            image: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            layoutType: layoutType,
            layout: layout,
            gridAnalysis: gridAnalysis,
            to: dir
        )
    }

    func saveGridAnalysisDebug(
        image: CGImage,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        gridAnalysis: CelticKnotGridReader.Analysis,
        to dir: URL
    ) {
        CelticKnotDebugRenderer().saveGridAnalysisDebug(
            image: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            gridAnalysis: gridAnalysis,
            to: dir
        )
    }
}
