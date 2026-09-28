// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ArchitectureValidation",
    platforms: [.macOS("15.4"), .iOS("18.4")],
    products: [
        .library(name: "ArchitectureValidation", targets: ["ArchitectureValidation"]),
        .library(name: "ABIBridgeLoadingFixture", type: .dynamic, targets: ["ABIBridgeLoadingFixture"]),
    ],
    dependencies: [
        .package(name: "ABIBridge", path: "../.."),
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.53.0"),
    ],
    targets: [
        .target(
            name: "ABIBridgeLoadingFixture",
            // This fixture tests loading and constructor execution, not coverage.
            // Xcode instruments C-only dynamic products without linking the profile runtime.
            cSettings: [.unsafeFlags(["-fno-profile-instr-generate", "-fno-coverage-mapping"])]
        ),
        .target(name: "ArchitectureFixtures", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .target(name: "SwiftReplacementFixtures"),
        .target(name: "SwiftOpaqueExtensions", dependencies: ["SwiftValueFixtures"]),
        .target(name: "SwiftValueFixtures", swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .target(name: "SwiftReplacementCaller", dependencies: ["SwiftReplacementFixtures"]),
        .target(name: "ArchitectureValidation", dependencies: ["ArchitectureFixtures", "SwiftReplacementFixtures", "SwiftReplacementCaller", "SwiftValueFixtures", "SwiftOpaqueExtensions", .product(name: "ABIBridge", package: "ABIBridge"), .product(name: "MachOKit", package: "MachOKit")]),
        .executableTarget(name: "ArchitectureProbe", dependencies: ["ArchitectureValidation"]),
        .testTarget(name: "ArchitectureValidationTests", dependencies: ["ArchitectureValidation"]),
    ],
    cxxLanguageStandard: .cxx20
)
