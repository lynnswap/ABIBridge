// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
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
        .library(name: "ABIBridgeCore", targets: ["ABIBridgeCore", "ABIBridge"]),
        .library(name: "ABIBridgeObjCXX", targets: ["ABIBridgeObjCXX", "ABIBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.52.2"),
    ],
    targets: [
        .target(
            name: "ABIBridge",
            dependencies: ["ABIBridgeCore", .product(name: "MachOKit", package: "MachOKit")],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ABIBridgeCore",
            path: "Sources/ABIBridgeCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "ABIBridgeObjCXX",
            dependencies: ["ABIBridgeCore"],
            path: "Sources/ABIBridgeObjCXX",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "ABIBridgeTests",
            dependencies: ["ABIBridge"],
            swiftSettings: strictSwiftSettings
        ),
    ],
    cxxLanguageStandard: .cxx20
)
