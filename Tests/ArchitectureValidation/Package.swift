// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ArchitectureValidation",
    platforms: [.macOS("15.4"), .iOS("18.4")],
    products: [.library(name: "ArchitectureValidation", targets: ["ArchitectureValidation"])],
    dependencies: [.package(name: "ABIBridge", path: "../..")],
    targets: [
        .target(name: "ArchitectureFixtures", dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]),
        .target(name: "ArchitectureValidation", dependencies: ["ArchitectureFixtures", .product(name: "ABIBridge", package: "ABIBridge")]),
        .executableTarget(name: "ArchitectureProbe", dependencies: ["ArchitectureValidation"]),
        .testTarget(name: "ArchitectureValidationTests", dependencies: ["ArchitectureValidation"]),
    ],
    cxxLanguageStandard: .cxx20
)
