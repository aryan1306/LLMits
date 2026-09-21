// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LLMits",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LLMitsCore", targets: ["LLMitsCore"]),
        .executable(name: "LLMits", targets: ["LLMitsApp"]),
    ],
    targets: [
        .target(
            name: "LLMitsCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(name: "LLMitsApp", dependencies: ["LLMitsCore"]),
        .testTarget(name: "LLMitsCoreTests", dependencies: ["LLMitsCore"]),
    ]
)
