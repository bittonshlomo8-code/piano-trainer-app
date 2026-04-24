// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PianoTrainer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PianoTranscriptionKit", targets: ["PianoTranscriptionKit"]),
        .executable(name: "MacApp", targets: ["MacApp"]),
    ],
    targets: [
        .target(
            name: "PianoTranscriptionKit",
            path: "Sources/PianoTranscriptionKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "MacApp",
            dependencies: ["PianoTranscriptionKit"],
            path: "Sources/MacApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "PianoTranscriptionKitTests",
            dependencies: ["PianoTranscriptionKit"],
            path: "Tests/PianoTranscriptionKitTests"
        ),
    ]
)
