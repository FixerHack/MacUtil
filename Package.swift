// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacUtil",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacUtil", targets: ["MacUtilApp"]),
        .executable(name: "mucli", targets: ["mucli"]),
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "SecurityCore", targets: ["SecurityCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CleanerCore"),
        .target(name: "SecurityCore", dependencies: ["CleanerCore"]),
        .executableTarget(name: "MacUtilApp", dependencies: ["CleanerCore", "SecurityCore"]),
        .executableTarget(
            name: "mucli",
            dependencies: [
                "CleanerCore", "SecurityCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
        .testTarget(name: "SecurityCoreTests", dependencies: ["SecurityCore"]),
    ]
)
