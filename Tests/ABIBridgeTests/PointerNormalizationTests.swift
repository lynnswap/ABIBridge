#if os(macOS)
import Foundation
import Testing

struct PointerNormalizationTests {
    @Test func automaticNormalizationWithAndWithoutCPUCapability() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let core = root.appendingPathComponent("Sources/ABIBridgeCore")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let object = directory.appendingPathComponent("PointerSearch.o")
        let executable = directory.appendingPathComponent("normalization-test")
        try run([
            "--sdk", "macosx", "clang++", "-std=c++20", "-mmacosx-version-min=15.4",
            "-I", core.appendingPathComponent("include").path, "-Dsysctlbyname=ABIPointerTestSysctl",
            "-c", core.appendingPathComponent("PointerSearch.cpp").path, "-o", object.path,
        ])
        try run([
            "--sdk", "macosx", "clang++", "-std=c++20", "-mmacosx-version-min=15.4",
            "-I", core.appendingPathComponent("include").path,
            root.appendingPathComponent("Tests/NativeConsumer/PointerNormalizationFixture.cpp").path,
            core.appendingPathComponent("Memory.cpp").path, object.path, "-o", executable.path,
        ])
        // Each subprocess gets a fresh capability cache in the native scanner.
        for capability in ["unsupported", "unavailable", "host"] {
            try run([executable.path, capability])
        }
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, Comment(rawValue: arguments.joined(separator: " ")))
    }
}
#endif
