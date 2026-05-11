import CoreGraphics
import Foundation
import ImageIO
import Opt1Solvers
import Opt1Detection

// MARK: - Detector

/// Detects the lockbox puzzle in a captured game frame and classifies all 25 cells.
struct LockboxDetector: PuzzleDetector {
    private let lockboxCellModel = LockboxCellModelArtifact.loadFromBundle()

    func detect(in image: CGImage) async -> LockboxState? {
        let reader = ClueTextReader()
        guard let located = try? await reader.readLocatedObservations(from: image) else { return nil }

        // PRIMARY TRIGGER: instruction text is uniquely present in lockboxes and
        // is reliably OCR'd even when the title is garbled ("LOCKKOX" etc.).
        let instrKeywords = ["combat style", "match them all", "cycle through",
                             "click on the combat", "unlock the lockbox"]
        let instrMatches = located.filter { obs in
            let l = obs.text.lowercased()
            return instrKeywords.contains { l.contains($0) }
        }
        guard !instrMatches.isEmpty else { return nil }

        // Log every matched observation so we can diagnose anchor drift across resolutions.
        print("[LockboxDetector] instrMatches (\(instrMatches.count)) in \(image.width)×\(image.height):")
        for m in instrMatches {
            print("  '\(m.text)'  minY=\(String(format: "%.1f", m.bounds.minY))  maxY=\(String(format: "%.1f", m.bounds.maxY))  w=\(String(format: "%.1f", m.bounds.width))  h=\(String(format: "%.1f", m.bounds.height))")
        }

        let instrMinY  = instrMatches.map { $0.bounds.minY }.min()!
        let instrMidX  = instrMatches.map { $0.bounds.midX }.reduce(0, +) / CGFloat(instrMatches.count)
        let instrMaxW  = instrMatches.map { $0.bounds.width }.max() ?? 100

        // Title: used for diagnostic logging only (its bounding box can extend into
        // the grid area due to game-font decorations, making it unreliable for height).
        let titleObs = located.first { obs in
            let u = obs.text.uppercased().replacingOccurrences(of: " ", with: "")
            return u.contains("LOCK") && u.count <= 10 && obs.bounds.maxY < instrMinY
        }

        // The instruction text may wrap across two lines, and the topmost line can be
        // garbled by OCR (missing leading character, stylised font) so it fails keyword
        // matching.  When only the lower line is matched, instrMinY is one text-line too
        // far down, shifting the entire grid rect down by ~one cell and clipping row 0.
        //
        // Fix: after identifying the instruction cluster, also scan for observations
        // that sit just above it with a similar horizontal centre.  These are very
        // likely the first (unmatched) instruction line and should be included when
        // computing the true top edge of the instruction block.
        // Search window: use the larger of (4 × tallest matched line) or 2.5% of image
        // height.  The game's stylised font makes the first instruction line (e.g.
        // "Click on the combat styles to cycle") easy for Vision to garble, so it
        // routinely fails keyword matching even though it sits only ~30 px above the
        // matched second line.  A window of 2× instrLineH was too narrow on 2560×1440
        // (missed by 5.3 px); 4× gives comfortable headroom across all tested scales.
        let instrLineH   = instrMatches.map { $0.bounds.height }.max() ?? 20
        let instrXLeft   = instrMidX - instrMaxW * 0.6
        let instrXRight  = instrMidX + instrMaxW * 0.6
        let searchWindow = max(instrLineH * 4, CGFloat(image.height) * 0.025)
        let extendedTop  = instrMinY - searchWindow

        let instrAbove = located.filter { obs in
            let withinX = obs.bounds.midX > instrXLeft && obs.bounds.midX < instrXRight
            let justAbove = obs.bounds.minY >= extendedTop && obs.bounds.maxY <= instrMinY
            return withinX && justAbove
        }

        // Recompute width from the full cluster (keyword-matched + spatially adjacent
        // lines above) so instrMaxW reflects the widest instruction line, not just the
        // one that happened to keyword-match.  This matters when line 1 is wider than
        // line 2 (common when the text wraps unevenly).
        let allInstrObs  = instrMatches + instrAbove
        let effectiveMaxW = allInstrObs.map { $0.bounds.width }.max() ?? instrMaxW

        let effectiveInstrMinY: CGFloat
        if instrAbove.isEmpty {
            effectiveInstrMinY = instrMinY
        } else {
            let aboveMinY = instrAbove.map { $0.bounds.minY }.min()!
            effectiveInstrMinY = min(instrMinY, aboveMinY)
            print("[LockboxDetector] Extended instr anchor: found \(instrAbove.count) candidate(s) above matched text:")
            for a in instrAbove {
                print("  '\(a.text)'  minY=\(String(format: "%.1f", a.bounds.minY))  maxY=\(String(format: "%.1f", a.bounds.maxY))  w=\(String(format: "%.1f", a.bounds.width))")
            }
            print("[LockboxDetector] effectiveInstrMinY adjusted \(String(format: "%.1f", instrMinY)) → \(String(format: "%.1f", effectiveInstrMinY))  effectiveMaxW \(String(format: "%.1f", instrMaxW)) → \(String(format: "%.1f", effectiveMaxW))")
        }

        // Grid bounds: the widest instruction line ≈ actual 5-cell grid width.
        let gridW      = max(effectiveMaxW * 1.0, CGFloat(image.width) * 0.07)
        let gridH      = gridW
        let gridBottom = effectiveInstrMinY - 8
        let gridTop    = max(0, gridBottom - gridH)
        let gridX      = max(0, instrMidX - gridW / 2)

        guard gridW > 30, gridH > 30 else {
            print("[LockboxDetector] Grid bounds too small (\(Int(gridW))×\(Int(gridH)))")
            return nil
        }

        let gridRect = CGRect(x: gridX, y: gridTop, width: gridW, height: gridH)
        let cellPx = Int(gridW / 5)
        print("[LockboxDetector] instrMinY=\(String(format: "%.1f", instrMinY))  effectiveInstrMinY=\(String(format: "%.1f", effectiveInstrMinY))  instrMaxW=\(String(format: "%.1f", instrMaxW))  effectiveMaxW=\(String(format: "%.1f", effectiveMaxW))  searchWindow=\(String(format: "%.1f", searchWindow))  instrMidX=\(String(format: "%.1f", instrMidX))")
        print("[LockboxDetector] Grid: \(gridRect)  cell≈\(cellPx)px  (title OCR: \(titleObs?.text ?? "–"))")

        // Dump all OCR observations to a debug file - this lets us diagnose anchor
        // drift on new resolutions without trawling the full app log.
        if let dir = AppSettings.debugSubfolder(named: "LockboxDebug") {
            var txt = "Image: \(image.width)×\(image.height)\n"
            txt += "instrMinY=\(String(format: "%.1f", instrMinY))  effectiveInstrMinY=\(String(format: "%.1f", effectiveInstrMinY))  instrMaxW=\(String(format: "%.1f", instrMaxW))  effectiveMaxW=\(String(format: "%.1f", effectiveMaxW))  searchWindow=\(String(format: "%.1f", searchWindow))\n"
            txt += "gridRect: x=\(String(format: "%.1f", gridRect.minX)) y=\(String(format: "%.1f", gridRect.minY)) w=\(String(format: "%.1f", gridRect.width)) h=\(String(format: "%.1f", gridRect.height))  cell≈\(cellPx)px\n\n"
            txt += "All Vision observations (CGImage coords, origin top-left):\n"
            let sortedObs = located.sorted { $0.bounds.minY < $1.bounds.minY }
            for obs in sortedObs {
                let marker = instrMatches.contains(where: { $0.text == obs.text && $0.bounds == obs.bounds }) ? " ← INSTR" : ""
                txt += "  y=\(String(format: "%6.1f", obs.bounds.minY))–\(String(format: "%.1f", obs.bounds.maxY))  x=\(String(format: "%6.1f", obs.bounds.minX))–\(String(format: "%.1f", obs.bounds.maxX))  '\(obs.text)'\(marker)\n"
            }
            try? txt.write(to: dir.appendingPathComponent("lockbox_debug.txt"),
                           atomically: true, encoding: .utf8)
        }

        let cells = classifyCells(in: image, gridBounds: gridRect)
        return LockboxState(cells: cells, gridBoundsInImage: gridRect)
    }

    // MARK: - Cell classification

    private func classifyCells(in image: CGImage, gridBounds: CGRect) -> [[CombatStyle]] {
        let cellW = gridBounds.width  / 5
        let cellH = gridBounds.height / 5
        let embVersionOk = lockboxCellModel?.embeddingVersion == PuzzleEmbeddingExtractor.version
        print(
            "[LockboxDetector] Cell model: artifact=\(lockboxCellModel != nil) embeddingVersionOk=\(embVersionOk)"
        )

        let debugDir: URL? = AppSettings.debugSubfolder(named: "LockboxDebug")

        func sym(_ c: CombatStyle) -> String { c == .melee ? "M" : c == .ranged ? "R" : "G" }
        var log = "[LockboxDetector] Cell grid (M=melee R=ranged G=magic):\n"
        guard let fullGrid = image.cropping(to: gridBounds) else {
            print("[LockboxDetector] Failed to crop grid bounds \(gridBounds) from \(image.width)×\(image.height)")
            return (0..<5).map { _ in [CombatStyle](repeating: .melee, count: 5) }
        }
        if let dir = debugDir { savePNG(fullGrid, to: dir.appendingPathComponent("grid_full.png")) }
        let result = (0..<5).map { row -> [CombatStyle] in
            let rowCells = (0..<5).map { col -> CombatStyle in
                let ox = gridBounds.minX + CGFloat(col) * cellW
                let oy = gridBounds.minY + CGFloat(row) * cellH

                let fullRect = CGRect(x: ox, y: oy, width: cellW, height: cellH)

                if let dir = debugDir, let fullCrop = image.cropping(to: fullRect) {
                    savePNG(fullCrop, to: dir.appendingPathComponent("cell_r\(row)c\(col)_full.png"))
                }

                let sample = CGRect(
                    x: ox + cellW * 0.25,
                    y: oy + cellH * 0.25,
                    width:  cellW * 0.50,
                    height: cellH * 0.50
                )

                if let dir = debugDir, let sampleCrop = image.cropping(to: sample) {
                    savePNG(sampleCrop, to: dir.appendingPathComponent("cell_r\(row)c\(col)_sample.png"))
                }

                return classifyCell(in: image, cellRect: fullRect)
            }
            log += "  row \(row): \(rowCells.map(sym).joined(separator: " "))\n"
            return rowCells
        }
        print(log)
        if debugDir != nil { print("[LockboxDetector] Debug images saved to LockboxDebug/") }
        return result
    }

    /// Saves a CGImage as a PNG file (debug helper).
    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func classifyCell(in image: CGImage, cellRect: CGRect) -> CombatStyle {
        guard let artifact = lockboxCellModel else {
            print("[LockboxDetector][CellModel] no artifact - defaulting to melee")
            return .melee
        }
        guard artifact.embeddingVersion == PuzzleEmbeddingExtractor.version else {
            print(
                "[LockboxDetector][CellModel] embedding version mismatch " +
                "artifact=\(artifact.embeddingVersion) runtime=\(PuzzleEmbeddingExtractor.version)"
            )
            return .melee
        }
        guard let cell = image.cropping(to: cellRect) else {
            print("[LockboxDetector][CellModel] crop failed")
            return .melee
        }
        return classifyCellWithModel(cell, artifact: artifact) ?? .melee
    }

    private func classifyCellWithModel(_ sample: CGImage, artifact: LockboxCellModelArtifact) -> CombatStyle? {
        guard let embedding = PuzzleEmbeddingExtractor.embedding(for: sample, side: 32) else { return nil }

        var scored: [(label: String, score: Float)] = []
        scored.reserveCapacity(artifact.classToIndex.count)
        for (label, idx) in artifact.classToIndex {
            guard idx >= 0, idx < artifact.centroids.count else { continue }
            let score = MathHelpers.cosine(embedding, artifact.centroids[idx])
            scored.append((label, score))
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.score > $1.score }

        let top = scored[0]
        let secondScore = scored.count > 1 ? scored[1].score : top.score
        let margin = top.score - secondScore
        let temperature = max(0.1, artifact.calibratedTemperature ?? 8.0)
        let topK = Array(scored.prefix(min(3, scored.count)))
        let probs = MathHelpers.softmax(topK.map { $0.score * temperature })
        let topConfidence = probs.first ?? 0

        let minConfidence = artifact.recommendedMinConfidence ?? 0.50
        let minMargin = artifact.recommendedMinMargin ?? 0.02
        let accepted = topConfidence >= minConfidence && margin >= minMargin
        print(
            "[LockboxDetector][CellModel] top=\(top.label) conf=\(String(format: "%.3f", Double(topConfidence))) " +
            "margin=\(String(format: "%.3f", Double(margin))) thresholds=(" +
            "\(String(format: "%.3f", Double(minConfidence)))," +
            "\(String(format: "%.3f", Double(minMargin)))) accepted=\(accepted)"
        )
        guard accepted else { return nil }
        return combatStyle(for: top.label)
    }

    private func combatStyle(for label: String) -> CombatStyle {
        switch label.lowercased() {
        case "ranged": return .ranged
        case "magic": return .magic
        default: return .melee
        }
    }

}
