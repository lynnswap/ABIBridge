// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "ABIBridge",
    products: [
        .library(name: "ABIBridge", targets: ["ABIBridge"]),
        .library(name: "ABIBridgeCore", targets: ["ABIBridgeCore"]),
        .library(name: "ABIBridgeObjCXX", targets: ["ABIBridgeObjCXX"]),
    ],
    targets: [
        .target(
            name: "ABIBridge",
            dependencies: ["ABIBridgeCore"],
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
