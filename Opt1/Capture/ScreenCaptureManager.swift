import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

// MARK: - Errors

enum CaptureError: Error, LocalizedError {
    case noDisplay
    case frameDecodeFailed
    case timeout
    case cropOutOfBounds(requested: CGRect, frame: CGSize)
    case streamStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found - is RuneScape on a connected monitor?"
        case .frameDecodeFailed:
            return "Could not decode captured frame"
        case .timeout:
            return "Capture timed out - is RuneScape visible on screen?"
        case .cropOutOfBounds(let requested, let frame):
            return "Capture crop \(requested) is outside the captured frame (\(Int(frame.width))×\(Int(frame.height))) - the window may have moved, minimised, or changed displays"
        case .streamStartFailed(let err):
            return "Screen capture failed to start: \(err.localizedDescription). Check System Settings → Privacy & Security → Screen Recording."
        }
    }
}

// MARK: - Manager

class ScreenCaptureManager {

    func captureWindow(_ window: SCWindow, excludingWindowIDs: [CGWindowID] = []) async throws -> CGImage {
        let content = try await SCShareableContent.current

        let windowCentre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(windowCentre) })
                         ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        print("[Opt1] Capturing display \(display.width)×\(display.height) px" +
              " (window '\(window.title ?? "?")')")

        let config = SCStreamConfiguration()
        config.width         = display.width
        config.height        = display.height
        config.capturesAudio = false
        config.showsCursor   = false
        config.pixelFormat   = kCVPixelFormatType_32BGRA

        let windowsToExclude = excludingWindowIDs.isEmpty ? [] :
            content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        if !windowsToExclude.isEmpty {
            print("[Opt1] Excluding \(windowsToExclude.count) window(s) from capture")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: windowsToExclude
        )

        let capturer = OneShotStreamCapturer(filter: filter, config: config)
        let full = try await capturer.captureFirstFrame()

        print("[Opt1] Full display frame: \(full.width)×\(full.height) px")

        // display.frame is in logical screen points (CG coords, Y=0 top-left).
        // window.frame is also in logical CG screen points.
        // The captured image is display.width × display.height pixels.
        let scaleX = CGFloat(display.width)  / display.frame.width
        let scaleY = CGFloat(display.height) / display.frame.height

        let requestedCrop = CGRect(
            x: (window.frame.minX - display.frame.minX) * scaleX,
            y: (window.frame.minY - display.frame.minY) * scaleY,
            width:  window.frame.width  * scaleX,
            height: window.frame.height * scaleY
        )

        let frameBounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let clippedCrop = requestedCrop.intersection(frameBounds)
        let frameSize = CGSize(width: full.width, height: full.height)

        // Reject crops that don't meaningfully overlap the captured frame -
        // returning the full display silently would just feed shite to detectors
        guard !clippedCrop.isNull, !clippedCrop.isEmpty,
              clippedCrop.width >= 20, clippedCrop.height >= 20 else {
            throw CaptureError.cropOutOfBounds(requested: requestedCrop, frame: frameSize)
        }

        if clippedCrop != requestedCrop {
            print("[Opt1] Crop rect (px): \(clippedCrop) (clipped from \(requestedCrop))")
        } else {
            print("[Opt1] Crop rect (px): \(clippedCrop)")
        }

        guard let cropped = full.cropping(to: clippedCrop) else {
            throw CaptureError.cropOutOfBounds(requested: requestedCrop, frame: frameSize)
        }
        return cropped
    }
}

// MARK: - Single-frame stream helper

private final class OneShotStreamCapturer: NSObject, SCStreamOutput {

    private let stream:  SCStream
    private let lock   = NSLock()
    private var cont:    CheckedContinuation<CGImage, Error>?
    private var stopped = false
    private var timeoutItem: DispatchWorkItem?

    init(filter: SCContentFilter, config: SCStreamConfiguration) {
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
    }

    func captureFirstFrame() async throws -> CGImage {
        // Register output here so we can surface errors instead of silencing them.
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )

        return try await withCheckedThrowingContinuation { [self] continuation in
            lock.lock()
            cont = continuation
            lock.unlock()

            Task { [self] in
                do {
                    try await stream.startCapture()
                    print("[Opt1] SCStream started (display capture), waiting for frame…")
                } catch {
                    print("[Opt1] SCStream startCapture error: \(error)")
                    finish(with: .failure(CaptureError.streamStartFailed(error)))
                }
            }

            let item = DispatchWorkItem { [self] in
                stopOnce()
                finish(with: .failure(CaptureError.timeout))
            }
            lock.lock()
            timeoutItem = item
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
        }
    }

    // MARK: SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        // Skip frames that arrive after stopOnce() has already fired
        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        guard !alreadyStopped else { return }

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            print("[Opt1] Warning: sample buffer has no image buffer")
            return
        }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)

        stopOnce()

        finish(with: image.map { .success($0) } ?? .failure(CaptureError.frameDecodeFailed))
    }

    // MARK: Private

    private func stopOnce() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        Task { try? await stream.stopCapture() }
    }

    private func finish(with result: Result<CGImage, Error>) {
        lock.lock()
        let c = cont
        cont  = nil
        let t = timeoutItem
        timeoutItem = nil
        lock.unlock()
        t?.cancel()
        c?.resume(with: result)
    }
}
