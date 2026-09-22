// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeConsumer",
    platforms: [.macOS("15.4")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "DynamicConsumer",
            dependencies: [.product(name: "ABIBridgeCore", package: "ABIBridge")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
        .executableTarget(
            name: "NativeConsumer",
            dependencies: [.product(name: "ABIBridgeCore", package: "ABIBridge")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
        .executableTarget(
            name: "ObjCConsumer",
            dependencies: [.product(name: "ABIBridgeObjCXX", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "MRCConsumer",
            dependencies: [.product(name: "ABIBridgeObjCXX", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        )
    ],
    cxxLanguageStandard: .cxx20
)
