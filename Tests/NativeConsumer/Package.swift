// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeConsumer",
    platforms: [.macOS("15.4")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "NativeConsumer",
            dependencies: [.product(name: "ABIBridgeCore", package: "ABIBridge")]
        )
    ],
    cxxLanguageStandard: .cxx20
)
