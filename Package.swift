// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "ABIBridge",
    platforms: [
        .iOS("18.4"),
        .macOS("15.4"),
        .visionOS("2.4"),
        .watchOS("11.4"),
        .tvOS("18.4"),
    ],
    products: [
        .library(name: "ABIBridge", targets: ["ABIBridge"]),
        .library(name: "ABIBridgeSwiftUI", targets: ["ABIBridgeSwiftUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.54.1"),
        .package(url: "https://github.com/p-x9/swift-objc-dump.git", exact: "0.9.0"),
        .package(url: "https://github.com/lynnswap/ZDLibffi.git", exact: "0.380.1"),
    ],
    targets: [
        .target(
            name: "ABIBridgeSwiftUI",
            dependencies: ["ABIBridge"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "HookCoordinationFixtures",
            path: "Tests/HookCoordinationFixtures",
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "ABIBridge",
            dependencies: [
                "ABIBridgeCore", "ABIBridgeObjCXX", "ABIBridgeRuntime",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ABIBridgeRuntime",
            dependencies: [
                "ABIBridgeCore", "ABIBridgeObjCXX",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ABIBridgeCore",
            dependencies: [.product(name: "ZDLibffi", package: "ZDLibffi")],
            path: "Sources/ABIBridgeCore",
            exclude: ["SwiftDemangling"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("SwiftDemangling/Support"),
                .headerSearchPath("SwiftDemangling/Upstream/include"),
            ]
        ),
        .target(
            name: "ABIBridgeObjCXX",
            dependencies: ["ABIBridgeCore"],
            path: "Sources/ABIBridgeObjCXX",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "ObjectiveCFixtures",
            dependencies: ["ABIBridgeCore"],
            path: "Tests/ObjectiveCFixtures",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ManagedSwiftFixtures",
            path: "Tests/ManagedSwiftFixtures",
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"]),
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
        .target(
            name: "ManagedSwiftAdapters",
            dependencies: ["ManagedSwiftFixtures"],
            path: "Tests/ManagedSwiftAdapters"
        ),
        .target(name: "ABIBridgeTestSupport", path: "Tests/ABIBridgeTestSupport"),
        .testTarget(
            name: "ABIBridgeCoreTests",
            dependencies: ["ABIBridgeCore", "ABIBridgeRuntime", "ObjectiveCFixtures"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ABIBridgeRuntimeTests",
            dependencies: ["ABIBridgeRuntime", "ABIBridgeTestSupport", "ObjectiveCFixtures"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ABIBridgeTests",
            dependencies: [
                "ABIBridge", "ABIBridgeRuntime", "ABIBridgeTestSupport", "ObjectiveCFixtures",
                "HookCoordinationFixtures",
                "ManagedSwiftFixtures", "ManagedSwiftAdapters",
            ],
            swiftSettings: strictSwiftSettings
        ),
    ],
    cxxLanguageStandard: .cxx20
)
