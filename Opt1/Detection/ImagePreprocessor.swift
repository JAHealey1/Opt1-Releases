import CoreImage
import CoreGraphics

/// Preprocessing pipeline that converts a clue scroll crop into a high-contrast
/// black-on-white image for Vision OCR.
struct ImagePreprocessor {

    // CIContext reuse is important - creating one per call is expensive.
    private static let shared = CIContext(options: [.useSoftwareRenderer: false])

    /// Desaturates, boosts contrast, then binarizes the image.
    /// Returns the processed CGImage, or the original if any step fails.
    func preprocess(_ image: CGImage) -> CGImage {
        var ci = CIImage(cgImage: image)

        ci = colorControls(ci, saturation: 0.0, contrast: 2.8, brightness: -0.05) ?? ci

        // Binarize: parchment background (~0.5 luminance) → white,
        // dark text (~0.15 luminance) → black. Threshold sits between them.
        ci = threshold(ci, value: 0.42) ?? ci

        let ctx = ImagePreprocessor.shared
        return ctx.createCGImage(ci, from: ci.extent) ?? image
    }

    // MARK: - Filter Helpers

    private func colorControls(
        _ input: CIImage,
        saturation: Double,
        contrast: Double,
        brightness: Double
    ) -> CIImage? {
        CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey:       input,
            kCIInputSaturationKey:  NSNumber(value: saturation),
            kCIInputContrastKey:    NSNumber(value: contrast),
            kCIInputBrightnessKey:  NSNumber(value: brightness)
        ])?.outputImage
    }

    private func threshold(_ input: CIImage, value: Double) -> CIImage? {
        CIFilter(name: "CIColorThreshold", parameters: [
            kCIInputImageKey: input,
            "inputThreshold": NSNumber(value: value)
        ])?.outputImage
    }
}
