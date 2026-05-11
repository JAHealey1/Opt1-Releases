import CoreGraphics
import Foundation
import ImageIO
import Vision
import Opt1Solvers
import Opt1Detection

// MARK: - Detector

/// Detects the Towers puzzle dialog (primary: close-X anchor + title OCR + fixed
/// offsets; fallback: legacy instruction/button OCR), crops to NXT parchment bounds
/// (same framing strategy as Celtic Knot), reads the 20 edge hints inside that crop,
/// and returns a TowersState ready to be passed to TowersSolver.solve(_:).
///
/// Visual layout of the puzzle dialog (game renders it as a 7×7 cell grid):
///
///   [  ] [T0] [T1] [T2] [T3] [T4] [  ]   ← top hints, row 0 of 7×7
///   [L0] [  ] [  ] [  ] [  ] [  ] [R0]   ← left/right hints + playing cells
///   [L1] [  ] [  ] [  ] [  ] [  ] [R1]
///   [L2] [  ] [  ] [  ] [  ] [  ] [R2]
///   [L3] [  ] [  ] [  ] [  ] [  ] [R3]
///   [L4] [  ] [  ] [  ] [  ] [  ] [R4]
///   [  ] [B0] [B1] [B2] [B3] [B4] [  ]   ← bottom hints, row 6 of 7×7
///
struct TowersDetector: PuzzleDetector {

    private static let anchorConfidenceThreshold: Float = 0.70

    func detect(in image: CGImage) async -> TowersState? {
        if let anchorMatch = PuzzleModalLocator().locateCloseButton(
            in: image,
            bracketedConfidenceThreshold: Self.anchorConfidenceThreshold,
            logPrefix: "TowersDetector"
        ) {
            return await detectFromAnchorMatch(anchorMatch, image: image)
        }
        print("[TowersDetector] Anchor not found - falling back to OCR")
        return await detectUsingLegacyOCR(in: image)
    }

    // MARK: - Anchor path (preferred)

    /// Close-X matched - gate on title + anchored geometry. Returns `nil` when this modal is not Towers (without OCR fallback).
    private func detectFromAnchorMatch(_ anchorMatch: PuzzleModalAnchorMatch, image: CGImage) async -> TowersState? {
        let uiScale = CGFloat(anchorMatch.pinnedAnchor.offset.uiScale) / 100.0
        let scale = uiScale * anchorMatch.searchToImageScale
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))

        let titleBounds = scaledRectFromX(
            anchorMatch.xMatchInImage,
            offset: NXTModalOffsetsAt100.titleBarTopLeftFromX,
            size: NXTModalOffsetsAt100.titleBarSize,
            scale: scale
        ).intersection(imageBounds)

        guard let titleCrop = image.cropping(to: titleBounds.integral) else {
            print("[TowersDetector] X anchor matched but title crop failed: \(titleBounds)")
            return nil
        }

        let located = (try? await ClueTextReader().readLocatedObservations(from: titleCrop)) ?? []
        let titleText = located.map(\.text).joined(separator: " ")
        guard Self.isTowersTitle(titleText) else {
            print("[TowersDetector] X anchor matched but title was not Towers: '\(titleText)' \(titleBounds)")
            return nil
        }

        let titleBottomForHints = Self.towersTitleBottomForHints(titleBounds: titleBounds, located: located)
        print("[TowersDetector] Triggered (anchor) - title: '\(titleText)' \(titleBounds)")
        print("[TowersDetector] Title bottom for hint grid: \(String(format: "%.1f", titleBottomForHints)) (template maxY=\(String(format: "%.1f", titleBounds.maxY)))")

        guard let hintRaw = hintAreaRectFromAnchor(
            anchorMatch: anchorMatch,
            titleBounds: titleBounds,
            titleBottomForHints: titleBottomForHints,
            image: image,
            scale: scale
        ) else { return nil }

        var hintAreaRectScreen = hintRaw
        Self.expandHintRoiUpward(
            &hintAreaRectScreen,
            bands: NXTModalOffsetsAt100.towersHintRoiExtraBandsAbove,
            imageBounds: imageBounds
        )

        guard var dialogBounds = nxtModalDialogBounds(
            image: image,
            anchorMatch: anchorMatch,
            titleBounds: titleBounds,
            scale: scale,
            imageBounds: imageBounds
        ) else { return nil }

        Self.extendDialogTopIfNeeded(
            dialogBounds: &dialogBounds,
            hintRect: hintAreaRectScreen,
            imageBounds: imageBounds
        )

        guard let dialogCrop = image.cropping(to: dialogBounds) else { return nil }
        print("[TowersDetector] Dialog crop (NXT modal): \(Self.formatRect(dialogBounds)) → \(dialogCrop.width)×\(dialogCrop.height) px")

        let dialogExtent = CGRect(x: 0, y: 0, width: CGFloat(dialogCrop.width), height: CGFloat(dialogCrop.height))
        let hintInDialog = hintAreaRectScreen
            .offsetBy(dx: -dialogBounds.minX, dy: -dialogBounds.minY)
            .intersection(dialogExtent)
            .integral

        guard hintInDialog.width > 80, hintInDialog.height > 80 else {
            print("[TowersDetector] Hint rect not usable inside dialog crop: screen=\(Self.formatRect(hintAreaRectScreen)) dialog=\(Self.formatRect(dialogBounds)) clipped=\(Self.formatRect(hintInDialog))")
            return nil
        }

        return await readHints(
            dialogCrop: dialogCrop,
            dialogOriginInScreen: CGPoint(x: dialogBounds.minX, y: dialogBounds.minY),
            hintAreaRectInDialog: hintInDialog,
            screenCaptureSize: (width: image.width, height: image.height)
        )
    }

    /// Celtic Knot–style parchment bounds (top dark edge → footer edge below buttons).
    private func nxtModalDialogBounds(
        image: CGImage,
        anchorMatch: PuzzleModalAnchorMatch,
        titleBounds: CGRect,
        scale: CGFloat,
        imageBounds: CGRect
    ) -> CGRect? {
        let imageH = imageBounds.height
        let dialogLeft = max(imageBounds.minX, titleBounds.minX)
        let dialogRight = min(imageBounds.maxX, titleBounds.maxX)
        let buttonTop = anchorMatch.xMatchInImage.minY
            + CGFloat(NXTModalOffsetsAt100.buttonBandTopFromX) * scale
        let anchoredFooterBottom = min(
            imageH,
            buttonTop + CGFloat(NXTModalOffsetsAt100.towersModalExtentBelowButtons) * scale
        )

        let pbY: CGFloat
        if let y = findDialogTopEdge(in: image, titleBounds: titleBounds) {
            pbY = y
            print("[TowersDetector] Dialog top edge (pixel-locked): y=\(String(format: "%.1f", y))")
        } else {
            pbY = max(0, titleBounds.minY - 4 * scale)
            print("[TowersDetector] Dialog top edge fallback: title margin y=\(String(format: "%.1f", pbY))")
        }

        let generousSlack = Self.towersParchmentBottomSlack(scale: scale)
        let pbBottom: CGFloat
        if let y = findDialogBottomEdge(
            in: image,
            modalLeft: dialogLeft,
            modalRight: dialogRight,
            buttonBandTop: buttonTop,
            expectedBottom: anchoredFooterBottom,
            scale: scale
        ) {
            // Detector already lands on the modal chrome row; adding ~28px slack was dipping into the 3D scene below parchment.
            pbBottom = min(imageH, y + Self.towersTightBottomMargin(scale: scale))
            print("[TowersDetector] Dialog bottom edge (pixel-locked): y=\(String(format: "%.1f", y)) + tightMargin=\(String(format: "%.1f", Self.towersTightBottomMargin(scale: scale)))")
        } else {
            pbBottom = min(imageH, anchoredFooterBottom + generousSlack)
            print("[TowersDetector] Dialog bottom edge fallback: y=\(String(format: "%.1f", anchoredFooterBottom)) + generousSlack=\(String(format: "%.1f", generousSlack))")
        }

        let dialogBounds = CGRect(
            x: dialogLeft,
            y: pbY,
            width: dialogRight - dialogLeft,
            height: pbBottom - pbY
        ).intersection(imageBounds).integral

        guard dialogBounds.width >= 80, dialogBounds.height >= 80 else {
            print("[TowersDetector] Dialog bounds too small: \(dialogBounds)")
            return nil
        }
        return dialogBounds
    }

    /// Hint ROI uses the anchored title crop; **vertical** start is `titleBottomForHints` (Vision glyphs) + inset, not the template bar’s oversized `maxY`.
    private func hintAreaRectFromAnchor(
        anchorMatch: PuzzleModalAnchorMatch,
        titleBounds: CGRect,
        titleBottomForHints: CGFloat,
        image: CGImage,
        scale: CGFloat
    ) -> CGRect? {
        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: imageW, height: imageH)
        let xRect = anchorMatch.xMatchInImage

        let dialogLeft = titleBounds.minX
        let dialogRight = titleBounds.maxX

        let hintLeft = titleBounds.minX
        let insetBelowTitle = CGFloat(NXTModalOffsetsAt100.towersGridTopInsetBelowTitleBar) * scale
        let hintTop = titleBottomForHints + insetBelowTitle
        let hintWidth = CGFloat(NXTModalOffsetsAt100.towersHintAreaWidth) * scale

        let buttonTop = xRect.minY + CGFloat(NXTModalOffsetsAt100.buttonBandTopFromX) * scale

        print("[TowersDetector] Hint grid vertical anchor: titleBottom=\(String(format: "%.1f", titleBottomForHints)) + inset=\(String(format: "%.1f", insetBelowTitle)) → hintTop=\(String(format: "%.1f", hintTop))")

        let fallbackBottom = hintTop + CGFloat(NXTModalOffsetsAt100.towersHintAreaHeightFallback) * scale
        let generousSlack = Self.towersParchmentBottomSlack(scale: scale)
        let hintBottom: CGFloat
        if let detected = findDialogBottomEdge(
            in: image,
            modalLeft: dialogLeft,
            modalRight: dialogRight,
            buttonBandTop: buttonTop,
            expectedBottom: fallbackBottom,
            scale: scale
        ) {
            hintBottom = min(imageH, detected + Self.towersTightBottomMargin(scale: scale))
            print("[TowersDetector] Pixel-locked hint bottom edge: y=\(String(format: "%.1f", detected)) + tightMargin=\(String(format: "%.1f", Self.towersTightBottomMargin(scale: scale)))")
        } else {
            hintBottom = min(imageH, fallbackBottom + generousSlack)
            print("[TowersDetector] Pixel bottom-edge scan failed - fallback hint bottom y=\(String(format: "%.1f", fallbackBottom)) + generousSlack=\(String(format: "%.1f", generousSlack))")
        }

        guard hintBottom > hintTop else {
            print("[TowersDetector] Invalid hint vertical span (anchor path)")
            return nil
        }

        let hintAreaRect = CGRect(
            x: max(0, hintLeft),
            y: max(0, hintTop),
            width: min(hintWidth, imageW - max(0, hintLeft)),
            height: min(hintBottom - hintTop, imageH - max(0, hintTop))
        ).intersection(imageBounds)

        guard hintAreaRect.width > 80, hintAreaRect.height > 80 else {
            print("[TowersDetector] Hint area too small (anchor path): \(hintAreaRect)")
            return nil
        }

        return hintAreaRect.integral
    }

    /// Bottom edge of painted title glyphs in screen space - tighter than `titleBounds.maxY`, which uses a generous template bar height.
    private static func towersTitleBottomForHints(titleBounds: CGRect, located: [LocatedText]) -> CGFloat {
        guard !located.isEmpty else { return titleBounds.maxY }
        let matched = located.filter { isTowersTitle($0.text) }
        let sources = matched.isEmpty ? located : matched
        let relBottom = sources.map { $0.bounds.maxY }.max() ?? 0
        let y = titleBounds.minY + relBottom
        return min(titleBounds.maxY, max(titleBounds.minY + 4, y))
    }

    /// Slack below anchor/footer estimates when **bottom-edge CV scan fails** (need room for bottom clues).
    private static func towersParchmentBottomSlack(scale: CGFloat) -> CGFloat {
        max(24, 28 * scale)
    }

    /// Small pad past `findDialogBottomEdge` when scan **succeeds** - parchment chrome only, not terrain bleed.
    private static func towersTightBottomMargin(scale: CGFloat) -> CGFloat {
        max(4, min(14, 10 * scale))
    }

    private static func isTowersTitle(_ text: String) -> Bool {
        let compact = text.uppercased().filter { $0.isLetter }
        return compact.contains("WER")
    }

    // MARK: - OCR fallback

    private func detectUsingLegacyOCR(in image: CGImage) async -> TowersState? {
        let reader = ClueTextReader()
        guard let located = try? await reader.readLocatedObservations(from: image) else { return nil }

        let instrFragments = ["each couare", "each square", "same height",
                              "obiective is", "objective is",
                              "tower behind a tall"]
        let instrObs = located.filter { obs in
            let l = obs.text.lowercased()
            return instrFragments.contains { l.contains($0) }
        }

        let buttonObs = located.filter {
            let t = $0.text.uppercased().trimmingCharacters(in: .whitespaces)
            return ["RESET", "RESPT", "RFCFT", "RFSET",
                    "CHECK", "CHFCK", "CHEOK"].contains(t)
        }

        guard !instrObs.isEmpty, !buttonObs.isEmpty else {
            if instrObs.isEmpty { print("[TowersDetector] No Towers instruction text found") }
            if buttonObs.isEmpty { print("[TowersDetector] No RESET/CHECK button found") }
            return nil
        }

        print("[TowersDetector] Triggered (OCR fallback) - instrObs: \(instrObs.count)  buttons: \(buttonObs.count)")
        for obs in instrObs { print("[TowersDetector] Instr  '\(obs.text)'  \(obs.bounds)") }
        for obs in buttonObs { print("[TowersDetector] Button '\(obs.text)'  \(obs.bounds)") }

        let titleObs = located.first(where: {
            let t = $0.text.trimmingCharacters(in: .whitespaces)
            return t.count <= 10 && t.uppercased().contains("WER")
        })
        if let t = titleObs { print("[TowersDetector] Title  '\(t.text)'  \(t.bounds)") }

        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)

        let instrMinX = instrObs.map { $0.bounds.minX }.min()!
        let instrMaxX = instrObs.map { $0.bounds.maxX }.max()!
        let instrSectW = instrMaxX - instrMinX

        let gridWidth: CGFloat
        let gridLeft: CGFloat
        if let title = titleObs {
            let titleMidX = title.bounds.midX
            gridLeft = 2 * titleMidX - instrMaxX - 10
            gridWidth = instrMinX - gridLeft - 4
            print("[TowersDetector] Grid width from title (full-dialog mirror): \(Int(gridWidth)) px  left: \(Int(gridLeft))")
        } else {
            gridWidth = instrSectW * 2.0
            gridLeft = instrMinX - gridWidth
            print("[TowersDetector] Grid width from instrSect×2: \(Int(gridWidth)) px  left: \(Int(gridLeft))")
        }

        guard gridWidth > 20 else {
            print("[TowersDetector] Grid width too small (\(Int(gridWidth)) px) - bailing")
            return nil
        }

        let bottomBtn = buttonObs.max(by: { $0.bounds.maxY < $1.bounds.maxY })!
        let hintAreaBottom = min(bottomBtn.bounds.maxY + 75, imageH)

        let hintAreaTop: CGFloat
        if let title = titleObs {
            let gap = CGFloat(NXTModalOffsetsAt100.towersGridTopInsetBelowTitleBar)
            hintAreaTop = title.bounds.maxY + gap
            print("[TowersDetector] OCR fallback hint top: title.maxY=\(String(format: "%.1f", title.bounds.maxY)) + gap=\(Int(gap)) px")
        } else {
            let instrTopY = instrObs.map { $0.bounds.minY }.min()!
            let estCellH = (hintAreaBottom - instrTopY) / 7.0
            hintAreaTop = instrTopY - estCellH
        }

        var hintAreaRect = CGRect(
            x: max(0, gridLeft),
            y: max(0, hintAreaTop),
            width: min(gridWidth, imageW - max(0, gridLeft)),
            height: min(hintAreaBottom - hintAreaTop, imageH - max(0, hintAreaTop))
        )

        guard hintAreaRect.width > 80, hintAreaRect.height > 80 else {
            print("[TowersDetector] Hint area too small: \(hintAreaRect)")
            return nil
        }

        Self.expandHintRoiUpward(
            &hintAreaRect,
            bands: NXTModalOffsetsAt100.towersHintRoiExtraBandsAbove,
            imageBounds: CGRect(x: 0, y: 0, width: imageW, height: imageH)
        )

        let margin: CGFloat = 40
        var dialogUnion = hintAreaRect
        if let title = titleObs {
            dialogUnion = dialogUnion.union(title.bounds)
        }
        dialogUnion = dialogUnion.union(bottomBtn.bounds)
        dialogUnion = dialogUnion.insetBy(dx: -margin, dy: -margin)
        let imageBounds = CGRect(x: 0, y: 0, width: imageW, height: imageH)
        let dialogBounds = dialogUnion.intersection(imageBounds).integral

        guard dialogBounds.width >= 80, dialogBounds.height >= 80 else {
            print("[TowersDetector] OCR fallback dialog bounds too small: \(dialogBounds)")
            return nil
        }

        guard let dialogCrop = image.cropping(to: dialogBounds) else { return nil }
        print("[TowersDetector] Dialog crop (OCR fallback): \(Self.formatRect(dialogBounds)) → \(dialogCrop.width)×\(dialogCrop.height) px")

        let dialogExtent = CGRect(x: 0, y: 0, width: CGFloat(dialogCrop.width), height: CGFloat(dialogCrop.height))
        let hintInDialog = hintAreaRect
            .offsetBy(dx: -dialogBounds.minX, dy: -dialogBounds.minY)
            .intersection(dialogExtent)
            .integral

        guard hintInDialog.width > 80, hintInDialog.height > 80 else {
            print("[TowersDetector] Hint rect not usable in dialog crop (OCR): clipped=\(Self.formatRect(hintInDialog))")
            return nil
        }

        return await readHints(
            dialogCrop: dialogCrop,
            dialogOriginInScreen: CGPoint(x: dialogBounds.minX, y: dialogBounds.minY),
            hintAreaRectInDialog: hintInDialog,
            screenCaptureSize: (width: image.width, height: image.height)
        )
    }

    // MARK: - Digit pipeline

    /// All geometry after this point uses `dialogCrop` (NXT parchment) plus `hintAreaRectInDialog`; screen coordinates are reconstructable with `dialogOriginInScreen`.
    private func readHints(
        dialogCrop: CGImage,
        dialogOriginInScreen: CGPoint,
        hintAreaRectInDialog: CGRect,
        screenCaptureSize: (width: Int, height: Int)
    ) async -> TowersState? {
        // One integral rect for crop + overlays - avoids ½px drift between dialog stroke and hint bitmap.
        let hintRect = hintAreaRectInDialog.integral
        let hintAreaRectScreen = hintRect.offsetBy(dx: dialogOriginInScreen.x, dy: dialogOriginInScreen.y)

        print("""
        [TowersDetector] ─── frame / grid debug ─────────────────────────────────
        [TowersDetector] Screen capture: \(screenCaptureSize.width)×\(screenCaptureSize.height) px
        [TowersDetector] Dialog crop: \(dialogCrop.width)×\(dialogCrop.height) px  originOnScreen=(\(Int(dialogOriginInScreen.x)),\(Int(dialogOriginInScreen.y)))
        [TowersDetector] Hint area (dialog-local, integral): \(Self.formatRect(hintRect))
        [TowersDetector] Hint area (screen): \(Self.formatRect(hintAreaRectScreen))
        [TowersDetector] Debug: hint_area.png = raw ROI bitmap for digit OCR/templates; hint_area_overlay = dialog_overlay cropped to magenta (identical grid).
        """)

        saveDebugImage(dialogCrop, name: "dialog_crop.png")

        let naiveCellW = hintRect.width / 7
        let naiveCellH = hintRect.height / 7
        print("[TowersDetector] Naive 7×7 cell (from hint rect): \(String(format: "%.2f×%.2f", naiveCellW, naiveCellH)) px")

        guard let hintCrop = dialogCrop.cropping(to: hintRect) else { return nil }

        saveDebugImage(hintCrop, name: "hint_area.png")

        let calibOutcome = calibrateCellDimensions(
            hintCrop: hintCrop,
            naiveCellW: naiveCellW,
            naiveCellH: naiveCellH
        )
        let cellDims = calibOutcome.dims
        let calibReport = calibOutcome.report
        let calibCellW  = cellDims.cellW
        let calibCellH  = cellDims.cellH
        let calibTopOff = cellDims.topOffset
        let calibLeftOff = cellDims.leftOffset

        print("""
        [TowersDetector] Calibration mode: \(calibReport.modeDescription)
        [TowersDetector] Hint crop size: \(hintCrop.width)×\(hintCrop.height) px  bright rows(raw)=\(calibReport.rawBrightRowCount) cols(raw)=\(calibReport.rawBrightColCount)
        \(calibReport.detailLogLines.map { "[TowersDetector]   \($0)" }.joined(separator: "\n"))
        [TowersDetector] Applied cell frame: \(String(format: "%.2f×%.2f", calibCellW, calibCellH)) px  leftOff=\(String(format: "%.2f", calibLeftOff))  topOff=\(String(format: "%.2f", calibTopOff))
        """)

        logPerCellFrames(
            cellW: calibCellW,
            cellH: calibCellH,
            leftOffset: calibLeftOff,
            topOffset: calibTopOff,
            dialogOrigin: dialogOriginInScreen,
            hintAreaInDialog: hintRect
        )

        let playGridRectInDialog = CGRect(
            x: hintRect.minX + calibCellW + calibLeftOff,
            y: hintRect.minY + calibCellH + calibTopOff,
            width: calibCellW * 5,
            height: calibCellH * 5
        )
        let playGridRectScreen = playGridRectInDialog.offsetBy(dx: dialogOriginInScreen.x, dy: dialogOriginInScreen.y)

        print("[TowersDetector] Play grid (dialog-local): \(Self.formatRect(playGridRectInDialog))")
        print("[TowersDetector] Play grid (screen): \(Self.formatRect(playGridRectScreen))")
        print("[TowersDetector] ─── geometry logged - digit reads follow ─────────────────")

        saveTowersDebugArtifacts(
            dialogCrop: dialogCrop,
            dialogOriginInScreen: dialogOriginInScreen,
            hintAreaRectInDialog: hintRect,
            cellW: calibCellW,
            cellH: calibCellH,
            leftOffset: calibLeftOff,
            topOffset: calibTopOff,
            report: calibReport,
            naiveCellW: naiveCellW,
            naiveCellH: naiveCellH,
            playGridRectInDialog: playGridRectInDialog,
            playGridRectScreen: playGridRectScreen,
            screenCaptureSize: screenCaptureSize
        )

        let artifact = TowersDigitTemplateArtifact.loadFromBundle()
        if artifact == nil {
            print("[TowersDetector] WARNING: towers_digit_templates.json not found - falling back to OCR only")
        }

        let hintSlots: [(edge: String, index: Int, gx: Int, gy: Int)] = {
            var s = [(String, Int, Int, Int)]()
            for i in 0..<5 { s.append(("top",    i, i + 1, 0)) }
            for i in 0..<5 { s.append(("bottom", i, i + 1, 6)) }
            for i in 0..<5 { s.append(("left",   i, 0,     i + 1)) }
            for i in 0..<5 { s.append(("right",  i, 6,     i + 1)) }
            return s
        }()

        var hints = TowersHints()

        for slot in hintSlots {
            let cellRect = Self.hintSlotRectInHintCrop(
                gx: slot.gx,
                gy: slot.gy,
                cellW: calibCellW,
                cellH: calibCellH,
                leftOffset: calibLeftOff,
                topOffset: calibTopOff
            )

            guard let cellCrop = hintCrop.cropping(to: cellRect) else { continue }

            if let art = artifact {
                let result = classifyDigitByTemplate(cell: cellCrop, artifact: art)
                if let (digit, confidence) = result {
                    if confidence > 0.20 {
                        assignHint(&hints, edge: slot.edge, index: slot.index, digit: digit)
                        print("[TowersDetector]   \(slot.edge)[\(slot.index)] = \(digit)  (template, conf=\(String(format:"%.2f",confidence)))")
                        continue
                    } else {
                        print("[TowersDetector]   \(slot.edge)[\(slot.index)]: template low conf \(String(format:"%.2f",confidence)) best=\(digit)")
                    }
                } else {
                    print("[TowersDetector]   \(slot.edge)[\(slot.index)]: no gold pixels in cell")
                }
            }

            if let digit = await ocrSingleCell(cellCrop) {
                assignHint(&hints, edge: slot.edge, index: slot.index, digit: digit)
                print("[TowersDetector]   \(slot.edge)[\(slot.index)] = \(digit)  (OCR fallback)")
            } else if slot.gx == 0, let digit = await ocrSingleCellColor(cellCrop) {
                assignHint(&hints, edge: slot.edge, index: slot.index, digit: digit)
                print("[TowersDetector]   \(slot.edge)[\(slot.index)] = \(digit)  (OCR color fallback - left gutter)")
            } else {
                print("[TowersDetector]   \(slot.edge)[\(slot.index)]: OCR fallback also failed")
            }
        }

        print("[TowersDetector] Hints: \(hints.describe())")
        print("[TowersDetector] Present: \(hints.presentCount)/20")

        guard hints.presentCount >= 4 else {
            print("[TowersDetector] Too few hints read (\(hints.presentCount)/20)")
            return nil
        }

        return TowersState(hints: hints, gridBoundsInImage: playGridRectScreen)
    }

    private static func formatRect(_ r: CGRect) -> String {
        "origin=(\(Int(r.minX)),\(Int(r.minY))) size=\(Int(r.width))×\(Int(r.height))"
    }

    /// Slot rect in **hint-crop** space - must match digit reads and overlay tints.
    /// The left gutter (`gx == 0`) includes a strip of parchment/chrome on the outer edge; digits sit toward the grid, so we discard that leading strip before template/OCR.
    private static func hintSlotRectInHintCrop(
        gx: Int, gy: Int,
        cellW: CGFloat, cellH: CGFloat,
        leftOffset: CGFloat, topOffset: CGFloat
    ) -> CGRect {
        let baseX = CGFloat(gx) * cellW + leftOffset
        let baseY = CGFloat(gy) * cellH + topOffset
        var w = cellW
        var x = baseX
        if gx == 0 {
            var trim = min(max(5, cellW * 0.16), cellW * 0.42)
            trim = min(trim, cellW - 12)
            x += trim
            w = cellW - trim
        }
        return CGRect(x: x, y: baseY, width: w, height: cellH)
    }

    /// Pulls `hintTop` up by `bands × (height/7)` so row `gy == 0` overlaps painted top clues (they often sit above naive title→grid inset).
    private static func expandHintRoiUpward(_ rect: inout CGRect, bands: CGFloat, imageBounds: CGRect) {
        guard bands > 0.01, rect.height > 14 else { return }
        let lift = (rect.height / 7) * bands
        guard lift > 0.5 else { return }
        rect.origin.y -= lift
        rect.size.height += lift
        rect = rect.intersection(imageBounds).integral
        print("[TowersDetector] Hint ROI expanded upward \(Int(lift)) px (~\(String(format: "%.2f", bands))× nominal band); \(Self.formatRect(rect))")
    }

    /// Ensures parchment crop includes pixels above `pbY` when the lifted hint ROI extends past the original dialog top.
    private static func extendDialogTopIfNeeded(dialogBounds: inout CGRect, hintRect: CGRect, imageBounds: CGRect) {
        guard hintRect.minY < dialogBounds.minY - 0.5 else { return }
        let expandUp = dialogBounds.minY - hintRect.minY
        dialogBounds.origin.y -= expandUp
        dialogBounds.size.height += expandUp
        dialogBounds = dialogBounds.intersection(imageBounds).integral
        print("[TowersDetector] Dialog top extended \(Int(expandUp)) px to include lifted hint ROI; \(Self.formatRect(dialogBounds))")
    }

    /// Logs each hint-slot rect in **full-image** coordinates.
    private func logPerCellFrames(
        cellW: CGFloat,
        cellH: CGFloat,
        leftOffset: CGFloat,
        topOffset: CGFloat,
        dialogOrigin: CGPoint,
        hintAreaInDialog: CGRect
    ) {
        let slots: [(String, Int, Int, Int)] = [
            ("top", 0, 1, 0), ("top", 1, 2, 0), ("top", 2, 3, 0), ("top", 3, 4, 0), ("top", 4, 5, 0),
            ("bottom", 0, 1, 6), ("bottom", 1, 2, 6), ("bottom", 2, 3, 6), ("bottom", 3, 4, 6), ("bottom", 4, 5, 6),
            ("left", 0, 0, 1), ("left", 1, 0, 2), ("left", 2, 0, 3), ("left", 3, 0, 4), ("left", 4, 0, 5),
            ("right", 0, 6, 1), ("right", 1, 6, 2), ("right", 2, 6, 3), ("right", 3, 6, 4), ("right", 4, 6, 5)
        ]
        print("[TowersDetector] Hint slot rects (screen space); gx,gy = 7×7 indices (left gutter uses trimmed crop):")
        for (edge, index, gx, gy) in slots {
            let lr = Self.hintSlotRectInHintCrop(
                gx: gx, gy: gy, cellW: cellW, cellH: cellH,
                leftOffset: leftOffset, topOffset: topOffset
            )
            let lx = hintAreaInDialog.minX + lr.minX
            let ly = hintAreaInDialog.minY + lr.minY
            let r = CGRect(
                x: dialogOrigin.x + lx,
                y: dialogOrigin.y + ly,
                width: lr.width,
                height: lr.height
            )
            print("[TowersDetector]   \(edge)[\(index)] gx=\(gx) gy=\(gy): \(Self.formatRect(r))")
        }
    }

    // MARK: - Hint assignment helper

    private func assignHint(_ hints: inout TowersHints, edge: String, index: Int, digit: Int) {
        switch edge {
        case "top":    hints.top[index]    = digit
        case "bottom": hints.bottom[index] = digit
        case "left":   hints.left[index]   = digit
        case "right":  hints.right[index]  = digit
        default: break
        }
    }

    // MARK: - Cell dimension calibration

    private struct CellDimensions {
        let cellW: CGFloat
        let cellH: CGFloat
        let topOffset: CGFloat
        /// Horizontal alignment vs naive 7×7 origin (from interior vertical-line run).
        let leftOffset: CGFloat
    }

    private struct TowersCalibrationReport {
        let modeDescription: String
        let rawBrightRowCount: Int
        let rawBrightColCount: Int
        let clusteredLineCount: Int
        let clusteredLineYs: [Int]
        let clusteredLineXs: [Int]
        let medianSpacingPx: Int?
        let appliedMedianRejectedReason: String?
        let detailLogLines: [String]
    }

    private struct CellCalibrationOutcome {
        let dims: CellDimensions
        let report: TowersCalibrationReport
    }

    /// Estimates pitch from bright **1px-class** grid lines sampled only over the inner 5×5 band
    /// (avoids yellow side hints and most UI chrome), then picks the most uniform run of 6–8 lines.
    private func calibrateCellDimensions(
        hintCrop: CGImage,
        naiveCellW: CGFloat,
        naiveCellH: CGFloat
    ) -> CellCalibrationOutcome {
        let w = hintCrop.width, h = hintCrop.height
        let naiveDims = CellDimensions(
            cellW: naiveCellW, cellH: naiveCellH, topOffset: 0, leftOffset: 0
        )

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            let report = TowersCalibrationReport(
                modeDescription: "naive (bitmap context failed)",
                rawBrightRowCount: 0,
                rawBrightColCount: 0,
                clusteredLineCount: 0,
                clusteredLineYs: [],
                clusteredLineXs: [],
                medianSpacingPx: nil,
                appliedMedianRejectedReason: nil,
                detailLogLines: []
            )
            return CellCalibrationOutcome(dims: naiveDims, report: report)
        }
        ctx.draw(hintCrop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else {
            let report = TowersCalibrationReport(
                modeDescription: "naive (no pixel buffer)",
                rawBrightRowCount: 0,
                rawBrightColCount: 0,
                clusteredLineCount: 0,
                clusteredLineYs: [],
                clusteredLineXs: [],
                medianSpacingPx: nil,
                appliedMedianRejectedReason: nil,
                detailLogLines: []
            )
            return CellCalibrationOutcome(dims: naiveDims, report: report)
        }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        let marginX = max(4, min(Int((naiveCellW * 0.92).rounded(.down)), w / 3))
        let marginY = max(4, min(Int((naiveCellH * 0.92).rounded(.down)), h / 3))
        let x0 = marginX
        let x1 = w - marginX
        let y0 = marginY
        let y1 = h - marginY
        guard x1 - x0 >= 24, y1 - y0 >= 24 else {
            let report = TowersCalibrationReport(
                modeDescription: "naive (interior strip too narrow)",
                rawBrightRowCount: 0,
                rawBrightColCount: 0,
                clusteredLineCount: 0,
                clusteredLineYs: [],
                clusteredLineXs: [],
                medianSpacingPx: nil,
                appliedMedianRejectedReason: "margins",
                detailLogLines: [
                    "Interior strip collapsed for wxh=\(w)×\(h) naiveCell≈\(Int(naiveCellW))×\(Int(naiveCellH))"
                ]
            )
            return CellCalibrationOutcome(dims: naiveDims, report: report)
        }

        let brightThreshold: UInt8 = 158
        let minBrightRatio = 0.40
        let xSpan = x1 - x0
        let ySpan = y1 - y0

        var hLineYs = [Int]()
        for y in 0..<h {
            var bright = 0
            for x in x0..<x1 {
                let off = (y * w + x) * 4
                let lum = (Int(raw[off]) + Int(raw[off+1]) + Int(raw[off+2])) / 3
                if lum > Int(brightThreshold) { bright += 1 }
            }
            if Double(bright) / Double(xSpan) >= minBrightRatio {
                hLineYs.append(y)
            }
        }

        var vLineXs = [Int]()
        for x in 0..<w {
            var bright = 0
            for y in y0..<y1 {
                let off = (y * w + x) * 4
                let lum = (Int(raw[off]) + Int(raw[off+1]) + Int(raw[off+2])) / 3
                if lum > Int(brightThreshold) { bright += 1 }
            }
            if Double(bright) / Double(ySpan) >= minBrightRatio {
                vLineXs.append(x)
            }
        }

        let hClusters = clusterValues(hLineYs, maxGap: 2).sorted()
        let vClusters = clusterValues(vLineXs, maxGap: 2).sorted()

        var detail: [String] = [
            "Interior strip x∈[\(x0),\(x1)) y∈[\(y0),\(y1)) (~central 5×5 - excludes hint gutters)",
            "H clusters (y): \(hClusters) (n=\(hClusters.count))",
            "V clusters (x): \(vClusters) (n=\(vClusters.count))",
        ]

        var cellH = naiveCellH
        var cellW = naiveCellW
        var topOffset: CGFloat = 0
        var leftOffset: CGFloat = 0
        var medianSpacing: Int?
        var rejectReason: String?

        let hPick = pickBestUniformGridLineRun(clusterCenters: hClusters)
        var hPitchUsed: CGFloat?
        var hCalibrated = false

        if let (hRun, hPitch) = hPick {
            cellH = hPitch
            topOffset = max(0, CGFloat(hRun.first!) - hPitch)
            hPitchUsed = hPitch
            medianSpacing = Int(round(hPitch))
            hCalibrated = true
            let sp = zip(hRun, hRun.dropFirst()).map { $1 - $0 }
            detail.append("H run: n=\(hRun.count) pitch=\(String(format: "%.2f", hPitch)) CV=\(String(format: "%.3f", spacingCoefficientOfVariation(hRun))) topOff=\(Int(topOffset)) sp=\(sp)")
        } else if let fb = inferHorizontalCalibrationFallback(clusterYs: hClusters, cropHeight: h, naiveCellH: naiveCellH) {
            // Strict CV often rejects when the footer adds one oversized gap; without this we leave topOff=0 and the grid sits ~a row too high.
            cellH = fb.pitch
            topOffset = fb.topOffset
            hPitchUsed = fb.pitch
            medianSpacing = Int(round(fb.pitch))
            rejectReason = nil
            hCalibrated = true
            detail.append("H fallback (footer gap trimmed): pitch=\(String(format: "%.2f", fb.pitch)) topOff=\(String(format: "%.2f", fb.topOffset)) lineBase=\(fb.anchorStartGy) fitErr≈\(String(format: "%.1f", fb.fitErr))")
        } else {
            rejectReason = "no uniform horizontal line run"
            detail.append("H calibration rejected (need 6–8 clusters with spacing CV≤0.15, pitch 9…120)")
        }

        if let (vRun, vPitch) = pickBestUniformGridLineRun(clusterCenters: vClusters) {
            var accept = true
            if let hp = hPitchUsed {
                let relDiff = abs(vPitch - hp) / max(vPitch, hp)
                if relDiff > 0.24 {
                    accept = false
                    detail.append("V pitch \(String(format: "%.1f", vPitch)) vs H \(String(format: "%.1f", hp)) Δ=\(String(format: "%.0f%%", relDiff * 100)) - keep naive cellW")
                }
            }
            if accept {
                cellW = vPitch
                leftOffset = max(0, CGFloat(vRun.first!) - vPitch)
                let sp = zip(vRun, vRun.dropFirst()).map { $1 - $0 }
                detail.append("V run: n=\(vRun.count) pitch=\(String(format: "%.2f", vPitch)) CV=\(String(format: "%.3f", spacingCoefficientOfVariation(vRun))) leftOff=\(Int(leftOffset)) sp=\(sp)")
            }
        } else {
            detail.append("V calibration rejected - naive cellW")
        }

        var modeParts = [String]()
        if hCalibrated { modeParts.append("H") }
        if abs(cellW - naiveCellW) > 0.5 { modeParts.append("V") }
        let mode: String
        if modeParts.isEmpty {
            mode = "naive 7×7 (strict line runs rejected)"
        } else {
            mode = "interior band + uniform lines (\(modeParts.joined(separator: "+")))"
        }

        let report = TowersCalibrationReport(
            modeDescription: mode,
            rawBrightRowCount: hLineYs.count,
            rawBrightColCount: vLineXs.count,
            clusteredLineCount: hClusters.count,
            clusteredLineYs: hClusters,
            clusteredLineXs: vClusters,
            medianSpacingPx: medianSpacing,
            appliedMedianRejectedReason: rejectReason,
            detailLogLines: detail
        )
        return CellCalibrationOutcome(
            dims: CellDimensions(cellW: cellW, cellH: cellH, topOffset: topOffset, leftOffset: leftOffset),
            report: report
        )
    }

    /// When `pickBestUniformGridLineRun` fails because one trailing gap (footer/chrome) breaks CV, trim that cluster and fit pitch + origin to the uniform prefix.
    private func inferHorizontalCalibrationFallback(clusterYs: [Int], cropHeight h: Int, naiveCellH: CGFloat) -> (pitch: CGFloat, topOffset: CGFloat, fitErr: CGFloat, anchorStartGy: Int)? {
        guard clusterYs.count >= 4 else { return nil }
        var trimmed = clusterYs.sorted()
        while trimmed.count >= 5 {
            let gaps = zip(trimmed, trimmed.dropFirst()).map { $1 - $0 }
            let sortedGaps = gaps.sorted()
            let med = sortedGaps[sortedGaps.count / 2]
            guard let lg = gaps.last, lg > med + max(10, med / 4) else { break }
            trimmed.removeLast()
        }
        guard trimmed.count >= 4 else { return nil }
        let gaps = zip(trimmed, trimmed.dropFirst()).map { $1 - $0 }
        let g0 = gaps[0]
        guard gaps.allSatisfy({ abs($0 - g0) <= max(10, g0 / 4) }) else { return nil }
        let pitch = CGFloat(gaps.reduce(0, +)) / CGFloat(gaps.count)
        guard pitch >= 9 && pitch <= 120 else { return nil }

        let firstY = CGFloat(trimmed[0])
        // Bright-row centroid ~one pitch below ROI top is almost always the divider under the top clues, not grid line gy=0 - anchoring as 0 lifts the whole overlay one cell.
        let preferLineBase1 = firstY >= pitch * 0.45 && firstY <= pitch * 1.12 && firstY > naiveCellH * 0.28
        let minStartGy = preferLineBase1 ? 1 : 0
        let maxStart = min(6, max(0, 8 - trimmed.count))
        let startRange: ClosedRange<Int> = minStartGy <= maxStart ? minStartGy...maxStart : 0...maxStart

        var bestErr = CGFloat.greatestFiniteMagnitude
        var bestTop: CGFloat = 0
        var bestAnchor = 0
        for startGy in startRange {
            var sum: CGFloat = 0
            for j in 0..<trimmed.count {
                sum += CGFloat(trimmed[j]) - CGFloat(startGy + j) * pitch
            }
            let topOff = sum / CGFloat(trimmed.count)
            var err: CGFloat = 0
            for j in 0..<trimmed.count {
                err += abs(CGFloat(trimmed[j]) - (topOff + CGFloat(startGy + j) * pitch))
            }
            if err < bestErr {
                bestErr = err
                bestTop = topOff
                bestAnchor = startGy
            }
        }
        guard bestErr <= CGFloat(trimmed.count * 20) else { return nil }
        guard bestTop + 7 * pitch <= CGFloat(h) + 48, bestTop >= -pitch - 24 else { return nil }
        return (pitch, bestTop, bestErr, bestAnchor)
    }

    /// Lowest CV wins; ties prefer longer runs (8 over 6).
    private func pickBestUniformGridLineRun(clusterCenters: [Int]) -> ([Int], CGFloat)? {
        let sorted = clusterCenters.sorted()
        guard sorted.count >= 6 else { return nil }
        let ks = [8, 7, 6]
        var bestRun: [Int]?
        var bestPitch: CGFloat?
        var bestCV: CGFloat = .greatestFiniteMagnitude
        for k in ks {
            guard sorted.count >= k else { continue }
            for i in 0...(sorted.count - k) {
                let run = Array(sorted[i..<(i + k)])
                let cv = spacingCoefficientOfVariation(run)
                let sp = zip(run, run.dropFirst()).map { $1 - $0 }
                let pitch = CGFloat(sp.reduce(0, +)) / CGFloat(sp.count)
                guard pitch >= 9 && pitch <= 120 else { continue }
                guard cv <= 0.15 else { continue }
                let better = cv < bestCV - 1e-4
                    || (abs(cv - bestCV) <= 1e-4 && k > (bestRun?.count ?? 0))
                if better {
                    bestCV = cv
                    bestRun = run
                    bestPitch = pitch
                }
            }
        }
        guard let br = bestRun, let bp = bestPitch else { return nil }
        return (br, bp)
    }

    private func spacingCoefficientOfVariation(_ run: [Int]) -> CGFloat {
        let sp = zip(run, run.dropFirst()).map { $1 - $0 }
        guard !sp.isEmpty else { return .greatestFiniteMagnitude }
        let mean = CGFloat(sp.reduce(0, +)) / CGFloat(sp.count)
        guard mean > 2 else { return .greatestFiniteMagnitude }
        let varSum = sp.map { pow(CGFloat($0) - mean, 2) }.reduce(0, +)
        let sd = sqrt(varSum / CGFloat(sp.count))
        return sd / mean
    }

    private func clusterValues(_ values: [Int], maxGap: Int) -> [Int] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        var groups = [[Int]]()
        var current = [sorted[0]]
        for v in sorted.dropFirst() {
            if v - current.last! <= maxGap {
                current.append(v)
            } else {
                groups.append(current)
                current = [v]
            }
        }
        groups.append(current)
        return groups.map { $0.reduce(0, +) / $0.count }
    }

    // MARK: - Gold pixel isolation

    /// HSV-based gold filter - robust to monitor color profiles and gamma.
    /// RuneScape gold digits have hue ≈ 35-55°, high saturation, moderate+ value.
    private func isGoldPixel(r: Int, g: Int, b: Int) -> Bool {
        let rf = Float(r) / 255.0, gf = Float(g) / 255.0, bf = Float(b) / 255.0
        let cMax = max(rf, gf, bf)
        let cMin = min(rf, gf, bf)
        let delta = cMax - cMin

        let value = cMax
        guard value > 0.35 else { return false }

        let saturation = cMax > 0 ? delta / cMax : 0
        guard saturation > 0.30 else { return false }

        var hue: Float = 0
        if delta > 0 {
            if cMax == rf {
                hue = 60.0 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            } else if cMax == gf {
                hue = 60.0 * (((bf - rf) / delta) + 2)
            } else {
                hue = 60.0 * (((rf - gf) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }

        return hue >= 25 && hue <= 60
    }

    /// Extracts gold/yellow pixels from a cell crop and returns a binary float
    /// vector (1.0 = gold, 0.0 = background) resized to the given dimensions.
    private func goldIsolatedVector(
        from image: CGImage,
        targetW: Int,
        targetH: Int,
        filter: TowersDigitTemplateArtifact.GoldFilter
    ) -> [Float]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        let scale = 4
        let sw = w * scale, sh = h * scale
        guard let ctx = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: sw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        var goldPixels = Set<Int>()
        for y in 0..<sh {
            for x in 0..<sw {
                let off = (y * sw + x) * 4
                let r = Int(raw[off]), g = Int(raw[off+1]), b = Int(raw[off+2])
                if isGoldPixel(r: r, g: g, b: b) {
                    goldPixels.insert(y * sw + x)
                }
            }
        }
        guard !goldPixels.isEmpty else { return nil }

        let bestBlob = bestDigitBlob(pixels: goldPixels, width: sw, height: sh)
        guard !bestBlob.isEmpty else { return nil }

        var mask = [Float](repeating: 0, count: sw * sh)
        var minX = sw, maxX = 0, minY = sh, maxY = 0
        for idx in bestBlob {
            mask[idx] = 1.0
            let x = idx % sw, y = idx / sw
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }

        let pad = 2
        minX = max(0, minX - pad); maxX = min(sw - 1, maxX + pad)
        minY = max(0, minY - pad); maxY = min(sh - 1, maxY + pad)
        let bw = maxX - minX + 1, bh = maxY - minY + 1

        var result = [Float](repeating: 0, count: targetW * targetH)
        for ty in 0..<targetH {
            for tx in 0..<targetW {
                let sx = minX + tx * bw / targetW
                let sy = minY + ty * bh / targetH
                result[ty * targetW + tx] = mask[sy * sw + sx]
            }
        }
        return result
    }

    /// Finds connected components in the gold pixel set and returns the one
    /// most likely to be a digit glyph (rejects horizontal lines, picks tallest).
    private func bestDigitBlob(pixels: Set<Int>, width: Int, height: Int) -> Set<Int> {
        var visited = Set<Int>()
        var best = Set<Int>()
        var bestScore = 0

        for start in pixels {
            guard !visited.contains(start) else { continue }
            var blob = Set<Int>()
            var stack = [start]
            while let p = stack.popLast() {
                guard !visited.contains(p) else { continue }
                visited.insert(p)
                guard pixels.contains(p) else { continue }
                blob.insert(p)
                let x = p % width, y = p / width
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let ni = ny * width + nx
                        if !visited.contains(ni) && pixels.contains(ni) {
                            stack.append(ni)
                        }
                    }
                }
            }

            guard blob.count >= 5 else { continue }
            let xs = blob.map { $0 % width }
            let ys = blob.map { $0 / width }
            let bw = (xs.max()! - xs.min()!) + 1
            let bh = (ys.max()! - ys.min()!) + 1

            guard bh >= 4, bw < bh * 3 else { continue }

            if blob.count > bestScore {
                bestScore = blob.count
                best = blob
            }
        }
        return best
    }

    /// Returns a gold-isolated CGImage (white digits on black) for OCR fallback.
    private func goldIsolatedImage(from image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let scale = 4
        let sw = w * scale, sh = h * scale
        guard let ctx = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: sw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let data = ctx.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)

        for y in 0..<sh {
            for x in 0..<sw {
                let off = (y * sw + x) * 4
                let r = Int(raw[off]), g = Int(raw[off+1]), b = Int(raw[off+2])
                let v: UInt8 = isGoldPixel(r: r, g: g, b: b) ? 255 : 0
                raw[off] = v; raw[off+1] = v; raw[off+2] = v; raw[off+3] = 255
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Template matching

    /// Classifies a hint-cell crop by gold-isolating it and comparing against
    /// reference digit templates via normalized cross-correlation.
    private func classifyDigitByTemplate(
        cell: CGImage,
        artifact: TowersDigitTemplateArtifact
    ) -> (digit: Int, confidence: Float)? {
        guard let vec = goldIsolatedVector(
            from: cell,
            targetW: artifact.templateWidth,
            targetH: artifact.templateHeight,
            filter: artifact.goldFilter
        ) else { return nil }

        var bestDigit = 0
        var bestScore: Float = -1
        var secondScore: Float = -1

        for (key, template) in artifact.templates {
            guard let digit = Int(key), (1...5).contains(digit) else { continue }
            let score = zncc(vec, template)
            if score > bestScore {
                secondScore = bestScore
                bestScore = score
                bestDigit = digit
            } else if score > secondScore {
                secondScore = score
            }
        }

        guard bestDigit > 0, bestScore > 0 else { return nil }
        return (bestDigit, bestScore)
    }

    /// Zero-mean normalized cross-correlation.
    private func zncc(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }

        var sumA: Float = 0, sumB: Float = 0
        for i in 0..<n { sumA += a[i]; sumB += b[i] }
        let meanA = sumA / Float(n), meanB = sumB / Float(n)

        var dot: Float = 0, varA: Float = 0, varB: Float = 0
        for i in 0..<n {
            let da = a[i] - meanA, db = b[i] - meanB
            dot += da * db
            varA += da * da
            varB += db * db
        }
        let denom = sqrt(varA * varB)
        return denom > 1e-6 ? dot / denom : 0
    }

    // MARK: - Per-cell OCR fallback

    /// OCR on the **original** cell (yellow digit on parchment). Left gutter crops often confuse gold isolation; Vision can still read the glyph without binarisation.
    private func ocrSingleCellColor(_ cell: CGImage) async -> Int? {
        guard cell.width >= 8, cell.height >= 8 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.customWords = ["1", "2", "3", "4", "5"]
            req.recognitionLanguages = ["en-US"]
            try? VNImageRequestHandler(cgImage: cell, options: [:]).perform([req])
            for obs in (req.results as? [VNRecognizedTextObservation] ?? []) {
                guard let top = obs.topCandidates(1).first else { continue }
                let s = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                if let d = Int(s), (1...5).contains(d) { return d }
            }
            return nil
        }.value
    }

    /// Runs Vision OCR on a single gold-isolated cell crop to recognize a digit 1–5.
    private func ocrSingleCell(_ cell: CGImage) async -> Int? {
        guard let isolated = goldIsolatedImage(from: cell) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.customWords = ["1", "2", "3", "4", "5"]
            req.recognitionLanguages = ["en-US"]

            try? VNImageRequestHandler(cgImage: isolated, options: [:]).perform([req])

            for obs in (req.results as? [VNRecognizedTextObservation] ?? []) {
                guard let top = obs.topCandidates(1).first else { continue }
                let s = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                if let d = Int(s), (1...5).contains(d) { return d }
            }
            return nil
        }.value
    }

    // MARK: - Debug image export

    private func saveTowersDebugArtifacts(
        dialogCrop: CGImage,
        dialogOriginInScreen: CGPoint,
        hintAreaRectInDialog: CGRect,
        cellW: CGFloat,
        cellH: CGFloat,
        leftOffset: CGFloat,
        topOffset: CGFloat,
        report: TowersCalibrationReport,
        naiveCellW: CGFloat,
        naiveCellH: CGFloat,
        playGridRectInDialog: CGRect,
        playGridRectScreen: CGRect,
        screenCaptureSize: (width: Int, height: Int)
    ) {
        guard let dir = AppSettings.debugSubfolder(named: "TowersDebug") else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = [
            "TowersDetector debug - \(stamp)",
            "--- overlay legend ---",
            "dialog_overlay: parchment crop + magenta 7×7 ROI + gold grid + green play + tinted rectangles = per-edge hint sampling cells (same crops as OCR/templates)",
            "hint_area_overlay: square-for-square crop of dialog_overlay to magenta (zoom - must match dialog patch)",
            "hint_area.png: raw screen pixels inside magenta - only input to classifyDigit / gold isolation (no second geometry pass)",
            "Left gutter (gx=0) crops trim ~16% from the outer edge (parchment chrome) - matches template/OCR input and violet tints.",
            "--- pipeline (anchor path) ---",
            "1) Screen frame → close-X + anchored title crop → Vision title text.",
            "2) hintTop/hintBottom (screen) define magenta ROI; cell pitch calibrated inside that bitmap.",
            "3) dialog_crop is parchment chrome for debug/overlays; math converts screen ↔ dialog-local via dialog origin.",
            "4) Each hint digit reads one cell crop from hint_area.png (template match then OCR).",
            "---",
            "Screen capture: \(screenCaptureSize.width)×\(screenCaptureSize.height) px",
            "Dialog origin on screen: (\(Int(dialogOriginInScreen.x)), \(Int(dialogOriginInScreen.y)))",
            "Dialog crop size: \(dialogCrop.width)×\(dialogCrop.height) px",
            "Hint area (dialog-local): \(Self.formatRect(hintAreaRectInDialog))",
            "Hint area (screen): \(Self.formatRect(hintAreaRectInDialog.offsetBy(dx: dialogOriginInScreen.x, dy: dialogOriginInScreen.y)))",
            "Play grid (dialog-local): \(Self.formatRect(playGridRectInDialog))",
            "Play grid (screen): \(Self.formatRect(playGridRectScreen))",
            "Naive 7×7 cell: \(String(format: "%.3f×%.3f", naiveCellW, naiveCellH)) px",
            "Applied cell: \(String(format: "%.3f×%.3f", cellW, cellH)) px  leftOff=\(String(format: "%.3f", leftOffset))  topOff=\(String(format: "%.3f", topOffset))",
            "Calibration: \(report.modeDescription)",
            "Bright-line raw: rows=\(report.rawBrightRowCount) cols=\(report.rawBrightColCount)",
            "Clusters: H n=\(report.clusteredLineCount) Y=\(report.clusteredLineYs) | V X=\(report.clusteredLineXs)",
            "Median spacing (H): \(report.medianSpacingPx.map(String.init) ?? "-")",
            "---",
        ]
        lines.append(contentsOf: report.detailLogLines)
        lines.append("--- hint slot rects (screen coords) ---")
        let slots: [(String, Int, Int, Int)] = [
            ("top", 0, 1, 0), ("top", 1, 2, 0), ("top", 2, 3, 0), ("top", 3, 4, 0), ("top", 4, 5, 0),
            ("bottom", 0, 1, 6), ("bottom", 1, 2, 6), ("bottom", 2, 3, 6), ("bottom", 3, 4, 6), ("bottom", 4, 5, 6),
            ("left", 0, 0, 1), ("left", 1, 0, 2), ("left", 2, 0, 3), ("left", 3, 0, 4), ("left", 4, 0, 5),
            ("right", 0, 6, 1), ("right", 1, 6, 2), ("right", 2, 6, 3), ("right", 3, 6, 4), ("right", 4, 6, 5)
        ]
        let ox = dialogOriginInScreen.x, oy = dialogOriginInScreen.y
        for (edge, index, gx, gy) in slots {
            let lr = Self.hintSlotRectInHintCrop(
                gx: gx, gy: gy, cellW: cellW, cellH: cellH,
                leftOffset: leftOffset, topOffset: topOffset
            )
            let r = CGRect(
                x: ox + hintAreaRectInDialog.minX + lr.minX,
                y: oy + hintAreaRectInDialog.minY + lr.minY,
                width: lr.width,
                height: lr.height
            )
            lines.append("\(edge)[\(index)] gx=\(gx) gy=\(gy) \(Self.formatRect(r))")
        }
        let txtURL = dir.appendingPathComponent("towers_debug.txt")
        try? lines.joined(separator: "\n").write(to: txtURL, atomically: true, encoding: .utf8)

        let dialogExtent = CGRect(x: 0, y: 0, width: CGFloat(dialogCrop.width), height: CGFloat(dialogCrop.height))
        let hintPatchRect = hintAreaRectInDialog.intersection(dialogExtent).integral

        if let dialogOverlay = renderDialogCropGridOverlay(
            dialogCrop: dialogCrop,
            hintAreaRectInDialog: hintAreaRectInDialog,
            cellW: cellW,
            cellH: cellH,
            leftOffset: leftOffset,
            topOffset: topOffset,
            playGridRectInDialog: playGridRectInDialog
        ) {
            writeDebugPNG(dialogOverlay, to: dir.appendingPathComponent("dialog_overlay.png"))
            if hintPatchRect.width >= 24, hintPatchRect.height >= 24,
               let zoomed = dialogOverlay.cropping(to: hintPatchRect) {
                writeDebugPNG(zoomed, to: dir.appendingPathComponent("hint_area_overlay.png"))
            }
        }
    }

    /// Hint grid overlay on the **dialog crop** (same pixel basis as digit pipeline input).
    private func renderDialogCropGridOverlay(
        dialogCrop: CGImage,
        hintAreaRectInDialog: CGRect,
        cellW: CGFloat,
        cellH: CGFloat,
        leftOffset: CGFloat,
        topOffset: CGFloat,
        playGridRectInDialog: CGRect
    ) -> CGImage? {
        let w = dialogCrop.width, h = dialogCrop.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(dialogCrop, in: CGRect(x: 0, y: 0, width: w, height: h))

        ctx.setLineWidth(4)
        ctx.setStrokeColor(red: 1, green: 0.08, blue: 0.85, alpha: 1)
        ctx.stroke(hintAreaRectInDialog)

        let x0 = hintAreaRectInDialog.minX
        let y0 = hintAreaRectInDialog.minY
        let x1 = hintAreaRectInDialog.maxX
        let y1 = hintAreaRectInDialog.maxY

        // Without clipping, horizontal lines use fixed cellH - the 8th line can sit below maxY while verticals stop at y1, so the grid looked “longer” than magenta.
        ctx.saveGState()
        ctx.clip(to: hintAreaRectInDialog)

        ctx.setLineWidth(1)
        ctx.setStrokeColor(red: 1, green: 0.95, blue: 0.25, alpha: 0.9)
        ctx.beginPath()
        for gx in 0...7 {
            let x = x0 + CGFloat(gx) * cellW + leftOffset + 0.5
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
        }
        for gy in 0...7 {
            let y = y0 + CGFloat(gy) * cellH + topOffset + 0.5
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addLine(to: CGPoint(x: x1, y: y))
        }
        ctx.strokePath()

        ctx.setLineWidth(3)
        ctx.setStrokeColor(red: 0.25, green: 1, blue: 0.45, alpha: 1)
        ctx.stroke(playGridRectInDialog)

        // Tinted cells = exact regions passed to template / OCR for each edge (20 slots).
        func drawHintSampleCell(gx: Int, gy: Int, rf: CGFloat, gf: CGFloat, bf: CGFloat) {
            let lr = Self.hintSlotRectInHintCrop(
                gx: gx, gy: gy, cellW: cellW, cellH: cellH,
                leftOffset: leftOffset, topOffset: topOffset
            )
            let r = CGRect(
                x: x0 + lr.minX + 0.25,
                y: y0 + lr.minY + 0.25,
                width: max(1, lr.width - 0.5),
                height: max(1, lr.height - 0.5)
            )
            ctx.setFillColor(red: rf, green: gf, blue: bf, alpha: 0.22)
            ctx.fill(r)
            ctx.setStrokeColor(red: min(1, rf + 0.12), green: min(1, gf + 0.12), blue: min(1, bf + 0.12), alpha: 0.92)
            ctx.setLineWidth(1.25)
            ctx.stroke(r)
        }
        for gx in 1...5 { drawHintSampleCell(gx: gx, gy: 0, rf: 0.22, gf: 0.78, bf: 1.0) }
        for gx in 1...5 { drawHintSampleCell(gx: gx, gy: 6, rf: 1.0, gf: 0.52, bf: 0.14) }
        for gy in 1...5 { drawHintSampleCell(gx: 0, gy: gy, rf: 0.68, gf: 0.36, bf: 1.0) }
        for gy in 1...5 { drawHintSampleCell(gx: 6, gy: gy, rf: 0.32, gf: 0.95, bf: 0.42) }

        ctx.restoreGState()

        return ctx.makeImage()
    }

    private func writeDebugPNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func saveDebugImage(_ image: CGImage, name: String) {
        guard let dir = AppSettings.debugSubfolder(named: "TowersDebug") else { return }
        writeDebugPNG(image, to: dir.appendingPathComponent(name))
    }
}
