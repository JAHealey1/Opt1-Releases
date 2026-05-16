import Testing
import CoreGraphics
import Foundation
import Opt1Solvers
import Opt1Matching
@testable import Opt1

@Suite("ClueOrchestrator")
@MainActor
struct ClueOrchestratorTests {

    // MARK: - Initial state

    @Test("isSolveRunning is false after init")
    func initialStateIdle() {
        let (_, _, _, _, _, _, _, _, session) = makeOrchestratorWithMocks()
        #expect(!session.isSolveRunning)
    }

    @Test("isDataCollectionActive is false after init")
    func initialDataCollectionFalse() {
        let (_, _, _, _, _, _, _, _, session) = makeOrchestratorWithMocks()
        #expect(!session.isDataCollectionActive)
    }

    // MARK: - Data collection guard

    @Test("handleHotkeyAction ignored while data collection is active")
    func hotkeyIgnoredDuringDataCollection() async {
        let (orch, capture, _, _, _, _, _, _, session) = makeOrchestratorWithMocks()
        session.isDataCollectionActive = true
        await orch.handleHotkeyAction(.solveClue)
        #expect(capture.captureCallCount == 0)
    }

    @Test("solvePuzzleSnip hotkey also ignored during data collection")
    func snipHotkeyIgnoredDuringDataCollection() async {
        let (orch, capture, _, _, _, _, _, _, session) = makeOrchestratorWithMocks()
        session.isDataCollectionActive = true
        await orch.handleHotkeyAction(.solvePuzzleSnip)
        #expect(capture.captureCallCount == 0)
    }

    // MARK: - ClueScrollPipeline.clean

    @Test("clean filters strings shorter than 3 characters")
    func cleanFiltersShort() {
        let input = ["ab", "hello", "a", "world", "xy"]
        let result = ClueScrollPipeline.clean(input)
        #expect(result == ["hello", "world"])
    }

    @Test("clean filters low letter-ratio strings")
    func cleanFiltersLowRatio() {
        // "123456" has 0 letters out of 6 chars → ratio 0.0 < 0.40
        // "abc123" has 3 letters out of 6 chars → ratio 0.5 >= 0.40
        let input = ["123456", "abc123", "abcdef"]
        let result = ClueScrollPipeline.clean(input)
        #expect(result.contains("abc123"))
        #expect(result.contains("abcdef"))
        #expect(!result.contains("123456"))
    }

    @Test("clean keeps strings with sufficient letter ratio")
    func cleanKeepsSufficientRatio() {
        let input = ["He who wields the wand", "Varrock", "123"]
        let result = ClueScrollPipeline.clean(input)
        #expect(result.contains("He who wields the wand"))
        #expect(result.contains("Varrock"))
    }

    // MARK: - ClueScrollPipeline.containsScanPhrase

    @Test("containsScanPhrase detects 'orb scan range' variant", arguments: [
        ["This scroll. Orb scan range: 30 paces."],
        ["orb scan range 20"],
        ["Multiple lines", "orb scan range: 10 paces"],
    ])
    func detectsOrbScanRangePhrases(observations: [String]) {
        #expect(ClueScrollPipeline.containsScanPhrase(observations))
    }

    @Test("containsScanPhrase detects 'scan range' variant", arguments: [
        ["scan range: 40"],
        ["Varrock scan range 30"],
    ])
    func detectsScanRangePhrases(observations: [String]) {
        #expect(ClueScrollPipeline.containsScanPhrase(observations))
    }

    @Test("containsScanPhrase returns false for unrelated text")
    func noScanPhraseInUnrelatedText() {
        let observations = ["He who wields the wand", "Speak to the wise old man",
                            "scanning nearby area", "orb glows"]
        #expect(!ClueScrollPipeline.containsScanPhrase(observations))
    }

    // MARK: - ClueScrollPipeline.extractOCRScanRange

    @Test("extractOCRScanRange extracts digits from 'is N paces' pattern", arguments: [
        (["The scan range of this orb is 22 paces."], "22"),
        (["is 11 paces"],                             "11"),
        (["IS 49 PACES"],                             "49"),
    ] as [([String], String)])
    func extractOCRScanRangeFindsValue(observations: [String], expectedRange: String) {
        let result = ClueScrollPipeline.extractOCRScanRange(from: observations)
        #expect(result == expectedRange)
    }

    @Test("extractOCRScanRange joins split Vision observations to find range")
    func extractOCRScanRangeHandlesVisionSplit() {
        // Vision often splits "The scan range of this orb is" and "49 paces." across lines
        let observations = ["The scan range of this orb is", "49 paces."]
        let result = ClueScrollPipeline.extractOCRScanRange(from: observations)
        #expect(result == "49")
    }

    @Test("extractOCRScanRange returns nil when no 'is N paces' pattern present", arguments: [
        ["This scroll will work within the walls of Varrock."],
        ["Orb scan range: 22 paces."],  // corpus clue format, not the in-game reminder
        ["orb scan range: 14"],
        [],
    ] as [[String]])
    func extractOCRScanRangeReturnsNilWhenAbsent(observations: [String]) {
        let result = ClueScrollPipeline.extractOCRScanRange(from: observations)
        #expect(result == nil)
    }

    // MARK: - ClueScrollPipeline.reconcileScanRange

    @Test("reconcileScanRange trusts OCR when it matches base or base+meerkats")
    func reconcileAcceptsExactMatches() {
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "30", knownRange: 30) == "30")
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "35", knownRange: 30) == "35")
    }

    @Test("reconcileScanRange picks meerkats value when OCR is one digit-edit away (e.g. 25 vs 35)")
    func reconcileSingleDigitErrorPrefersBuffedWhenCloserInEdits() {
        // Menaphos base 30 / meerkats 35; Vision misreads tens digit
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "25", knownRange: 30) == "35")
    }

    @Test("reconcileScanRange picks base when tied on edit distance but closer numerically")
    func reconcileTieBreaksTowardNumericCloser() {
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "31", knownRange: 30) == "30")
    }

    @Test("reconcileScanRange falls back to known when OCR is far from both catalogue values")
    func reconcileFallsBackWhenOcrIsUnreconcilable() {
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "99", knownRange: 30) == "30")
    }

    @Test("reconcileScanRange without known defers to OCR or empty")
    func reconcileWithoutKnown() {
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: "22", knownRange: nil) == "22")
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: nil, knownRange: nil).isEmpty)
    }

    @Test("reconcileScanRange without OCR uses catalogue base")
    func reconcileWithoutOcr() {
        #expect(ClueScrollPipeline.reconcileScanRange(ocrRange: nil, knownRange: 30) == "30")
    }

    // MARK: - SnipCoordinateMapper.normalizedSnipToImagePixels

    @Test("Normalised rect (0,0,1,1) maps to full image rect")
    func fullNormalizedMapsToFullImage() {
        let imageSize = CGSize(width: 1920, height: 1080)
        let result = SnipCoordinateMapper.normalizedSnipToImagePixels(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: imageSize
        )
        #expect(result.origin.x == 0)
        #expect(result.origin.y == 0)
        #expect(result.width == 1920)
        #expect(result.height == 1080)
    }

    @Test("Normalised rect (0.25, 0.25, 0.5, 0.5) maps to expected pixel rect")
    func centeredQuarterMapsCorrectly() {
        let imageSize = CGSize(width: 1000, height: 1000)
        // normalized: x=0.25, y=0.25, w=0.5, h=0.5 in screen coords (y=0 at top)
        // Screen y-axis is flipped relative to image: image y = (1 - screen_maxY) * H ... (1 - screen_minY) * H
        let normRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let result = SnipCoordinateMapper.normalizedSnipToImagePixels(normRect, imageSize: imageSize)
        #expect(result.width == 500)
        #expect(result.height == 500)
        #expect(result.origin.x == 250)
    }

    @Test("Values are clamped to image bounds")
    func outOfBoundsValuesClamped() {
        let imageSize = CGSize(width: 100, height: 100)
        let oversized = CGRect(x: -0.5, y: -0.5, width: 2.0, height: 2.0)
        let result = SnipCoordinateMapper.normalizedSnipToImagePixels(oversized, imageSize: imageSize)
        #expect(result.origin.x >= 0)
        #expect(result.origin.y >= 0)
        #expect(result.maxX <= 100)
        #expect(result.maxY <= 100)
    }

    // MARK: - Capture error handling

    @Test("Capture throw routes error through CaptureErrorPresenter")
    func captureErrorsForwardedToPresenter() async {
        let (orch, capture, _, _, _, _, _, captureErrors, _) = makeOrchestratorWithMocks()
        capture.shouldThrow = true

        await orch.solveClueAction()

        #expect(captureErrors.captureErrors.count == 1)
        #expect(captureErrors.windowNotFoundCallCount == 0)
    }
}

// MARK: - CaptureErrorPresenter

@Suite("CaptureErrorPresenter")
@MainActor
struct CaptureErrorPresenterTests {

    /// Classifier input — the SCKit permission-denied error.
    private static let screenRecordingDeniedError = NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3811
    )

    @Test("SCKit permission error invokes onOpenPermissions")
    func permissionErrorInvokesCallback() {
        let presenter = MockPresenter()
        let sut = CaptureErrorPresenter(presenter: presenter)

        var opened = false
        sut.onOpenPermissions = { opened = true }
        sut.showCaptureError(Self.screenRecordingDeniedError)

        #expect(opened)
        #expect(presenter.overlayMessages.last?.message == "Screen Recording not granted")
    }

    @Test("Generic error does NOT invoke onOpenPermissions")
    func genericErrorDoesNotInvokeCallback() {
        struct GenericError: Error {}
        let presenter = MockPresenter()
        let sut = CaptureErrorPresenter(presenter: presenter)

        var opened = false
        sut.onOpenPermissions = { opened = true }
        sut.showCaptureError(GenericError())

        #expect(!opened)
        #expect(presenter.overlayMessages.last?.message == "Capture error")
    }

    @Test("showWindowNotFound shows the RS3 overlay")
    func windowNotFoundShowsOverlay() {
        let presenter = MockPresenter()
        let sut = CaptureErrorPresenter(presenter: presenter)

        sut.showWindowNotFound()

        #expect(presenter.overlayMessages.last?.message == "RuneScape not found")
    }
}
