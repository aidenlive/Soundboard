// swift-tools-version: 5.9
// Swift package for the Apple platforms: the shared C++ engine plus the iOS/macOS audio host.
import PackageDescription

let package = Package(
    name: "Soundboard",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SoundboardAudio", targets: ["SoundboardAudio"]),
        .library(name: "SoundboardUI", targets: ["SoundboardUI"]),
    ],
    targets: [
        .target(
            name: "SoundboardEngine",
            path: "engine",
            exclude: ["tests", "tools", "testing", "CMakeLists.txt", "README.md"],
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "SoundboardAudio",
            dependencies: ["SoundboardEngine"],
            path: "platforms/apple/Sources/SoundboardAudio"
        ),
        .target(
            name: "SoundboardUI",
            dependencies: ["SoundboardAudio"],
            path: "platforms/apple/Sources/SoundboardUI",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SoundboardUITests",
            dependencies: ["SoundboardUI"],
            path: "platforms/apple/Tests/SoundboardUITests"
        ),
        .testTarget(
            name: "SoundboardAudioTests",
            dependencies: ["SoundboardAudio"],
            path: "platforms/apple/Tests/SoundboardAudioTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
