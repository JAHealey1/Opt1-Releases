import CoreGraphics
import Foundation
import Opt1CelticKnot

// MARK: - Detection Outcome

/// Returned by `CelticKnotDetector.detect`. A `nil` result means the image
/// did not present enough evidence to identify the modal as a Celtic Knot
/// (no X-button, OCR failure, or wrong title), and the pipeline may continue
/// to the next detector. A non-nil result means the X-button **and** the
/// "Celtic Knot" title were both positively identified, so the pipeline must
/// **not** fall through regardless of the case:
///
/// - `.detected`: grid analysis succeeded — proceed to rune classification.
/// - `.confirmedButFailed`: the modal is definitely a Celtic Knot but grid
///   analysis or layout construction failed — surface an error to the user.
enum CelticKnotDetectionOutcome {
    case detected(CelticKnotDetectionResult)
    case confirmedButFailed
}

// MARK: - Detector

struct CelticKnotDetector: PuzzleDetector {

    private var debugDir: URL? {
        AppSettings.debugSubfolder(named: "CelticKnotDebug")
    }

    /// Knot modal X glyphs correlate slightly lower than slider X glyphs in the
    /// supplied 100% capture, but title-bar OCR still gates puzzle type.
    private static let anchorConfidenceThreshold: Float = 0.70

    func detect(in image: CGImage) async -> CelticKnotDetectionOutcome? {
        print("[CelticKnot] Image size: \(image.width)×\(image.height) px")

        guard let anchorMatch = PuzzleModalLocator().locateCloseButton(
            in: image,
            bracketedConfidenceThreshold: Self.anchorConfidenceThreshold,
            logPrefix: "CelticKnot"
        ) else {
            return nil
        }

        let uiScale = CGFloat(anchorMatch.pinnedAnchor.offset.uiScale) / 100.0
        let scale = uiScale * anchorMatch.searchToImageScale
        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: imageW, height: imageH)

        let titleBounds = scaledRectFromX(
            anchorMatch.xMatchInImage,
            offset: NXTModalOffsetsAt100.titleBarTopLeftFromX,
            size: NXTModalOffsetsAt100.titleBarSize,
            scale: scale
        ).intersection(imageBounds)
        let buttonTop = anchorMatch.xMatchInImage.minY
            + CGFloat(NXTModalOffsetsAt100.buttonBandTopFromX) * scale
        let anchoredFooterBottom = min(imageH, buttonTop + 34 * scale)

        guard let titleCrop = image.cropping(to: titleBounds.integral),
              let titleObservations = try? await ClueTextReader().readObservations(from: titleCrop)
        else {
            print("[CelticKnot] X anchor matched but title crop/OCR failed: \(titleBounds)")
            return nil
        }

        let titleText = titleObservations.joined(separator: " ")
        guard Self.isCelticKnotTitle(titleText) else {
            print("[CelticKnot] X anchor matched but title was not Celtic Knot: '\(titleText)' \(titleBounds)")
            return nil
        }

        print("[CelticKnot] Triggered — title: '\(titleText)' \(titleBounds)")

        let dialogLeft = max(0, titleBounds.minX)
        let dialogRight = min(imageW, titleBounds.maxX)
        let titleBottom = titleBounds.maxY

        let pbY: CGFloat
        if let detected = findDialogTopEdge(in: image, titleBounds: titleBounds) {
            pbY = detected
            print("[CelticKnot] Pixel-locked top edge: y=\(String(format: "%.1f", detected))")
        } else {
            pbY = max(0, titleBounds.minY - 4 * scale)
            print("[CelticKnot] Pixel top-edge scan failed, falling back to anchored title margin: y=\(String(format: "%.1f", pbY))")
        }


        let pbBottom: CGFloat
        if let detected = findDialogBottomEdge(
            in: image,
            modalLeft: dialogLeft,
            modalRight: dialogRight,
            buttonBandTop: buttonTop,
            expectedBottom: anchoredFooterBottom,
            scale: scale
        ) {
            pbBottom = detected
            print("[CelticKnot] Pixel-locked bottom edge: y=\(String(format: "%.1f", detected))")
        } else {
            pbBottom = anchoredFooterBottom
            print("[CelticKnot] Pixel bottom-edge scan failed, falling back to anchored footer margin: y=\(String(format: "%.1f", pbBottom))")
        }

        let puzzleBounds = CGRect(
            x: dialogLeft,
            y: pbY,
            width: dialogRight - dialogLeft,
            height: pbBottom - pbY
        ).intersection(imageBounds).integral

        let padding: CGFloat = max(4, 8 * scale)
        let runeArea = CGRect(
            x: max(0, dialogLeft + padding),
            y: titleBottom + padding,
            width: max(50, dialogRight - dialogLeft - padding * 2),
            height: max(50, buttonTop - titleBottom - padding * 2)
        ).intersection(imageBounds).integral

        guard runeArea.width > 40, runeArea.height > 40 else {
            print("[CelticKnot] Rune area too small: \(runeArea)")
            return .confirmedButFailed
        }

        print("[CelticKnot] Puzzle bounds: \(puzzleBounds)")
        print("[CelticKnot] Rune area: \(runeArea)")

        let gridAnalysis = CelticKnotGridReader().analyze(
            in: image,
            puzzleBounds: puzzleBounds,
            runeArea: runeArea
        )
        for line in gridAnalysis.summaryLines {
            print("[CelticKnotGrid] \(line)")
        }

        guard gridAnalysis.succeeded,
              let layoutType = gridAnalysis.topology?.candidate,
              let layout = CelticKnotGridReader().makeLayout(
                from: gridAnalysis,
                puzzleBounds: puzzleBounds,
                layoutType: layoutType
              )
        else {
            if let debugDir {
                saveGridAnalysisDebug(
                    image: image,
                    puzzleBounds: puzzleBounds,
                    runeArea: runeArea,
                    gridAnalysis: gridAnalysis,
                    to: debugDir
                )
            }
            print("[CelticKnotGrid] Grid analysis did not produce a trusted dynamic layout")
            return .confirmedButFailed
        }
        print("[CelticKnot] Detected layout: \(layoutType)")
        print("[CelticKnotGrid] Using grid-derived layout: tracks=\(layout.tracks.map(\.count)) intersections=\(layout.intersections.count)")

        if let debugDir {
            saveDebugImages(image: image, puzzleBounds: puzzleBounds,
                            runeArea: runeArea, layoutType: layoutType,
                            layout: layout,
                            gridAnalysis: gridAnalysis, to: debugDir)
        }

        return .detected(CelticKnotDetectionResult(
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            layoutType: layoutType,
            layout: layout,
            gridAnalysis: gridAnalysis
        ))
    }

    private static func isCelticKnotTitle(_ text: String) -> Bool {
        let compact = text
            .uppercased()
            .filter { $0.isLetter }
        return compact.contains("CELTICKNOT")
            || (compact.contains("CELTIC") && compact.contains("KNOT"))
    }

}
