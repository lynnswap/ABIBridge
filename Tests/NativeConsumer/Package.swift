// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeConsumer",
    platforms: [.macOS("15.4")],
    dependencies: [.package(name: "ABIBridge", path: "../..")],
    targets: [
        .executableTarget(
            name: "CXXInspectionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "ObjCXXInspectionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "MRCXXInspectionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "CInspectionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "ObjCInspectionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "SwiftMemberConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "SwiftFunctionConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "SwiftObjectConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "SwiftConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
        ),
        .executableTarget(
            name: "DynamicConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
        .executableTarget(
            name: "NativeConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
        .executableTarget(
            name: "ObjCConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "MRCConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            cxxSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        )
    ],
    cxxLanguageStandard: .cxx20
)
