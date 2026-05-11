import Foundation

public protocol Opt1ResourceProviding {
    func url(forResource name: String, withExtension ext: String?, subdirectory: String?) -> URL?
}

public struct BundleResourceProvider: Opt1ResourceProviding {
    public let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}

public struct DetectionConfiguration {
    public let resources: Opt1ResourceProviding
    public let debugDirectory: ((String) -> URL?)?
    public let puzzleUIScalePercent: Int?
    public let supportedPuzzleUIScales: [Int]
    public let defaultPuzzleUIScale: Int

    public init(
        resources: Opt1ResourceProviding = BundleResourceProvider(),
        debugDirectory: ((String) -> URL?)? = nil,
        puzzleUIScalePercent: Int? = nil,
        supportedPuzzleUIScales: [Int] = [],
        defaultPuzzleUIScale: Int = 100
    ) {
        self.resources = resources
        self.debugDirectory = debugDirectory
        self.puzzleUIScalePercent = puzzleUIScalePercent
        self.supportedPuzzleUIScales = supportedPuzzleUIScales
        self.defaultPuzzleUIScale = defaultPuzzleUIScale
    }

}
