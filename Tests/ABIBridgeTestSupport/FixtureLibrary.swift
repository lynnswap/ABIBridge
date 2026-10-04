#if os(macOS)
import Foundation
import Darwin
import Testing

package final class FixtureLibrary {
    package let directory: URL
    package let libraryURL: URL
    package let namespace: String
    private let buildArguments: [String]
    private var handle: UnsafeMutableRawPointer?

    package init(
        namespace: String? = nil,
        load: Bool = true,
        swiftModule: String? = nil,
        swiftSource: String? = nil,
        threadLocal: Bool = false,
        stripped: Bool = false,
        cxxSource: String? = nil,
        linkArguments: [String] = []
    ) throws {
        self.namespace =
            namespace ?? "Fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        libraryURL = directory.appendingPathComponent("fixture.dylib")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(
            swiftModule == nil ? "fixture.cpp" : "fixture.swift"
        )
        let cxxSource =
            cxxSource ?? """
                #include <cstdint>
                namespace \(self.namespace) {
                int counter = 42;
                \(threadLocal ? "thread_local int localCounter = 42;" : "")
                int add(int a, int b) { return a + b; }
                class Counter {
                public:
                    virtual ~Counter();
                    virtual int value() const;
                };
                Counter::~Counter() {}
                int Counter::value() const { return counter; }
                Counter object;
                }
                extern "C" int _ABIFixtureUnderscore = 73;
                extern "C" int exactComposed asm("_ABIBridgeUTF8_\u{00E9}") = 31;
                extern "C" int exactDecomposed asm("_ABIBridgeUTF8_e\u{0301}") = 32;
                extern "C" uintptr_t ABIFixtureAddress(int kind) {
                    \(threadLocal ? "if (kind == 3) return reinterpret_cast<uintptr_t>(&\(self.namespace)::localCounter);" : "")
                    if (kind == 0) return reinterpret_cast<uintptr_t>(&\(self.namespace)::add);
                    if (kind == 1) return reinterpret_cast<uintptr_t>(&\(self.namespace)::counter);
                    return *reinterpret_cast<uintptr_t *>(&\(self.namespace)::object) - 2 * sizeof(void *);
                }
                """
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        if let swiftModule {
            let target = "\(architecture)-apple-macosx15.4"
            try (swiftSource ?? "public func echo() {}").write(
                to: source,
                atomically: true,
                encoding: .utf8
            )
            buildArguments =
                [
                    "--sdk", "macosx", "swiftc", "-module-name", swiftModule, "-target", target,
                    "-emit-library", source.path, "-o", libraryURL.path,
                ] + linkArguments
        } else {
            try cxxSource.write(to: source, atomically: true, encoding: .utf8)
            buildArguments =
                [
                    "--sdk", "macosx", "clang++", "-arch", architecture, "-std=c++20",
                    "-mmacosx-version-min=15.4",
                    "-dynamiclib", source.path, "-o", libraryURL.path,
                ] + linkArguments
        }
        try Self.run(buildArguments)
        if stripped { try Self.run(["--sdk", "macosx", "strip", "-u", "-r", libraryURL.path]) }
        if load { try self.load() }
    }

    package static var toolEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        // xcodebuild removes DEVELOPER_DIR from the test host's environment.
        // The selected host still identifies the Xcode used for this test run.
        if environment["DEVELOPER_DIR"] == nil,
            let executable = Bundle.main.executableURL?.path,
            let developer = executable.range(of: "/Contents/Developer/")
        {
            environment["DEVELOPER_DIR"] = String(executable[..<developer.upperBound].dropLast())
        }
        return environment
    }

    package func rebuild(linkingWith arguments: [String]) throws {
        try Self.run(buildArguments + arguments)
    }

    package static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // XCTest injects loader paths for its own Xcode. A child compiler must
        // resolve its own libraries, even when xcode-select points elsewhere.
        process.environment = toolEnvironment
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    package func exportedSymbols() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.environment = Self.toolEnvironment
        process.arguments = ["--sdk", "macosx", "nm", "-gUj", libraryURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(
            String.init
        )
    }

    package func load() throws {
        handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL)
        try #require(
            handle != nil,
            Comment(rawValue: dlerror().map { String(cString: $0) } ?? "dlopen failed")
        )
    }

    package func address(kind: Int32) throws -> UInt {
        let symbol = try #require(dlsym(handle, "ABIFixtureAddress"))
        let function = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> UInt).self)
        return function(kind)
    }

    package func close() {
        if let handle { dlclose(handle) }
        handle = nil
    }

    package func cleanup() {
        close()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
