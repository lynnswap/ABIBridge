// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RuntimeBenchmarks",
    platforms: [.macOS("15.4")],
    dependencies: [.package(name: "ABIBridge", path: "../..")],
    targets: [
        .target(
            name: "BenchmarkSwiftProvider",
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .target(
            name: "BenchmarkNativeProvider", cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]),
        .target(
            name: "BenchmarkNativeCalls",
            dependencies: [
                "BenchmarkNativeProvider", .product(name: "ABIBridge", package: "ABIBridge"),
            ],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(
            name: "RuntimeBenchmarks",
            dependencies: [
                "BenchmarkSwiftProvider", "BenchmarkNativeProvider", "BenchmarkNativeCalls",
                .product(name: "ABIBridge", package: "ABIBridge"),
            ]),
    ],
    cxxLanguageStandard: .cxx20
)
