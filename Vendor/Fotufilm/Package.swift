// swift-tools-version: 5.9
import PackageDescription

// Stock selection builds the spectral tables on first use, including in development builds.
let spectralOptimization: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "Fotufilm",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "FotufilmMetal", targets: ["FotufilmCore", "FotufilmMetal"])],
    targets: [
        .binaryTarget(name: "FotufilmHalide", path: "FotufilmHalide.xcframework"),
        .target(name: "FotufilmCore", dependencies: ["FotufilmHalide"], resources: [.process("Resources")],
                swiftSettings: spectralOptimization),
        .target(name: "FotufilmMetal", dependencies: ["FotufilmCore", "FotufilmHalide"],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Metal"), .linkedFramework("Accelerate")])
    ], cxxLanguageStandard: .cxx17
)
