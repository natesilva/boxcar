// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerCore", targets: ["ContainerCore"]),
        .library(name: "ContainerUI", targets: ["ContainerUI"]),
        .library(name: "DockerRuntime", targets: ["DockerRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.7"),
    ],
    targets: [
        .target(name: "ContainerCore"),
        .target(
            name: "ContainerUI",
            dependencies: [
                "ContainerCore",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .target(
            name: "DockerRuntime",
            dependencies: [
                "ContainerCore",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .testTarget(name: "ContainerCoreTests", dependencies: ["ContainerCore"]),
        .testTarget(name: "DockerRuntimeTests", dependencies: ["DockerRuntime"]),
    ]
)
