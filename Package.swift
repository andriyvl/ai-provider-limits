// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProviderLimitsCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ProviderLimitsCore",
            targets: ["ProviderLimitsCore"]
        ),
        .executable(
            name: "provider-limits",
            targets: ["ProviderLimitsCLI"]
        )
    ],
    targets: [
        .target(
            name: "ProviderLimitsCore",
            dependencies: [],
            path: "Sources/ProviderLimitsCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ProviderLimitsCLI",
            dependencies: ["ProviderLimitsCore"],
            path: "Sources/ProviderLimitsCLI"
        ),
        .testTarget(
            name: "ProviderLimitsCoreTests",
            dependencies: ["ProviderLimitsCore"],
            path: "Tests/ProviderLimitsCoreTests"
        )
    ]
)
