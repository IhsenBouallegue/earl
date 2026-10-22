// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Earl",
    platforms: [.macOS(.v26)],
    dependencies: [
        // R2-2: speaker diarization on the Neural Engine. Pinned exactly; no
        // traits, so the text-normalization engine used only by its TTS isn't linked.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1", traits: []),
        // D-4: automatic updates from a signed feed. 2.10 is too new to trust.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(name: "Earl", dependencies: [.product(name: "FluidAudio", package: "FluidAudio"),
                                         .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Earl",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "EarlTests", dependencies: ["Earl"], path: "Tests/EarlTests",
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
