// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleanerApp"]),
        .executable(name: "mccli", targets: ["mccli"]),
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
    ],
    targets: [
        .target(name: "CleanerCore"),
        .executableTarget(name: "MacCleanerApp", dependencies: ["CleanerCore"]),
        .executableTarget(name: "mccli", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
