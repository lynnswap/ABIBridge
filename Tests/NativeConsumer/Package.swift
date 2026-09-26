// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeConsumer",
    platforms: [.macOS("15.4")],
    dependencies: [.package(name: "ABIBridge", path: "../..")],
    targets: [
        .executableTarget(name: "MixedHookConsumer", dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "HookFixture"]),
        .executableTarget(name: "ObjCXXHookConsumer", dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "HookFixture"], cxxSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "MRCXXHookConsumer", dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "HookFixture"], cxxSettings: [.unsafeFlags(["-fno-objc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "HookFixture", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")], linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "CHookConsumer", dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "HookFixture"]),
        .executableTarget(name: "CXXHookConsumer", dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "HookFixture"]),
        .target(
            name: "InitializerFixture",
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "SwiftInitializerHookConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge"), "InitializerFixture"]
        ),
        .executableTarget(
            name: "LoadingConsumer",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/LoadingFixtures"])]
        ),
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
