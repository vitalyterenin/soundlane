// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundLane",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "SoundLane", targets: ["SoundLane"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "AudioBridge", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "SoundLane", dependencies: [
            "AudioBridge", .product(name: "Sparkle", package: "Sparkle")
        ], swiftSettings: [.swiftLanguageMode(.v5)],
           linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ],
    cxxLanguageStandard: .cxx17
)
