import Foundation
import Opt1Detection

extension DetectionConfiguration {
    static var appDefault: DetectionConfiguration {
        DetectionConfiguration(
            resources: BundleResourceProvider(bundle: .main),
            debugDirectory: { AppSettings.debugSubfolder(named: $0) },
            puzzleUIScalePercent: AppSettings.puzzleUIScalePercent,
            supportedPuzzleUIScales: AppSettings.supportedPuzzleUIScales,
            defaultPuzzleUIScale: AppSettings.defaultPuzzleUIScale
        )
    }
}
