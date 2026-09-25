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
    ],
    dependencies: [
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.53.0"),
        .package(url: "https://github.com/p-x9/swift-objc-dump.git", exact: "0.9.0"),
        .package(url: "https://github.com/faimin/ZDLibffi.git", exact: "0.380.0"),
    ],
    targets: [
        .target(
            name: "ABIBridge",
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
        .target(
            name: "ObjectiveCFixtures",
            path: "Tests/ObjectiveCFixtures",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "ABIBridgeTests",
            dependencies: ["ABIBridge", "ObjectiveCFixtures"],
            swiftSettings: strictSwiftSettings
        ),
    ],
    cxxLanguageStandard: .cxx20
)
