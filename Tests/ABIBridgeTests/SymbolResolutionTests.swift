#if os(macOS)
import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct SymbolResolutionTests {
    @Test func resolvesFunctionsDataAndVTablesByDeclaration() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let images = try await runtime.images(matching: .path(fixture.libraryURL))
        let image = try #require(images.first)
        #expect(images.count == 1)
        #expect(image.identity.uuid != nil)

        let function = try await runtime.resolve(
            .init(name: "\(fixture.namespace)::add(int, int)", language: .cxx), in: image
        )
        let expected = try fixture.address(kind: 0)
        let actual = unsafe function.withUnsafeAddress { UInt(bitPattern: $0) }
        #expect(actual == expected)
        #expect(function.source == .image)

        let data = try await runtime.resolve(
            .init(name: "\(fixture.namespace)::counter", language: .cxx, kind: .data), in: image
        )
        #expect(unsafe data.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        let vtable = try await runtime.resolve(
            .init(name: "vtable for \(fixture.namespace)::Counter", language: .cxx, kind: .vtable), in: image
        )
        let expectedVTable = try fixture.address(kind: 2)
        #expect(unsafe vtable.withUnsafeAddress { UInt(bitPattern: $0) } == expectedVTable)

        let again = try await runtime.resolve(function.declaration, in: image)
        #expect(unsafe again.withUnsafeAddress { UInt(bitPattern: $0) } == actual)
        await runtime.removeCachedResults()
        let rebuilt = try await runtime.resolve(function.declaration, in: image)
        #expect(unsafe rebuilt.withUnsafeAddress { UInt(bitPattern: $0) } == actual)
        #expect(rebuilt.image.identity == image.identity)
    }

    @Test func missingWrongKindAndAmbiguousDeclarationsRemainDistinct() async throws {
        let first = try FixtureLibrary()
        defer { first.cleanup() }
        let second = try FixtureLibrary(namespace: first.namespace)
        defer { second.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: "\(first.namespace)::add(int, int)", language: .cxx)

        await #expect(throws: ABIResolutionError.declarationNotFound(.init(name: "doesNotExist", language: .c))) {
            _ = try await runtime.resolve(.init(name: "doesNotExist", language: .c), in: .path(first.libraryURL))
        }
        await #expect(throws: ABIResolutionError.invalidAddress) {
            _ = try await runtime.resolve(.init(name: declaration.name, language: .cxx, kind: .data), in: .path(first.libraryURL))
        }
        do {
            _ = try await runtime.resolve(declaration)
            Issue.record("Expected two distinct definitions to be ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
        await runtime.removeCachedResults()
    }

    @Test func lookupRetriesAfterLoadAndImageHandlesKeepAddressesAlive() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let request = NativeDeclaration(name: "\(fixture.namespace)::counter", language: .cxx, kind: .data)
        await #expect(throws: ABIResolutionError.imageNotLoaded) {
            _ = try await runtime.resolve(request, in: .path(fixture.libraryURL))
        }
        try fixture.load()
        let resolved = try await runtime.resolve(request, in: .path(fixture.libraryURL))
        fixture.close()
        await runtime.removeCachedResults()
        #expect(unsafe resolved.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
    }

    @Test func quickStartAndFrameworkScopeUseLoadedSystemImages() async throws {
        let runtime = ABIRuntime()
        let foundations = try await runtime.images(matching: .framework(named: "Foundation"))
        #expect(foundations.count == 1)
        let symbol = try await runtime.resolve(.init(name: "getpid", language: .c))
        #expect(symbol.source == .image)
    }

    @Test func resolvesSwiftSourceDeclarations() async throws {
        #expect(swiftFixtureEcho(41) == 42)
        let path = try #require(Bundle(for: FixtureBundleMarker.self).executableURL)
        let runtime = ABIRuntime()
        let symbol = try await runtime.resolve(
            .init(name: "ABIBridgeTests.swiftFixtureEcho(Swift.Int32) -> Swift.Int32", language: .swift),
            in: .path(path)
        )
        #expect(symbol.source == .image)
    }

    @Test func threadLocalDescriptorsAreNotReturnedAsOrdinaryData() async throws {
        let fixture = try FixtureLibrary(threadLocal: true)
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 3)
        let pointer = try #require(UnsafeRawPointer(bitPattern: address))
        #expect(pointer.load(as: Int32.self) == 42)
        let runtime = ABIRuntime()
        await #expect(throws: ABIResolutionError.invalidAddress) {
            _ = try await runtime.resolve(
                .init(name: "\(fixture.namespace)::localCounter", language: .cxx, kind: .data),
                in: .path(fixture.libraryURL)
            )
        }
    }

    @Test func resolvesCompressedSwiftModuleNames() async throws {
        let fixture = try FixtureLibrary(swiftModule: "FooFoo")
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let symbol = try await runtime.resolve(
            .init(name: "FooFoo.echo() -> ()", language: .swift),
            in: .path(fixture.libraryURL)
        )
        #expect(symbol.source == .image)
    }

    @Test func publicCoreModuleExportsItsCXXDeclarations() throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let include = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ABIBridgeCore/include")
        let client = fixture.directory.appendingPathComponent("consumer.mm")
        try """
        @import ABIBridgeCore;
        static_assert(abi_bridge::image_identity{1, 2, 3}.load_generation == 3);
        """.write(to: client, atomically: true, encoding: .utf8)
        try FixtureLibrary.run([
            "--sdk", "macosx", "clang++", "-std=c++20", "-fmodules", "-fcxx-modules",
            "-fmodule-map-file=" + include.appendingPathComponent("module.modulemap").path,
            "-fmodules-cache-path=" + fixture.directory.appendingPathComponent("ModuleCache").path,
            "-I", include.path, "-fsyntax-only", client.path,
        ])
    }

    @Test func unloadingInvalidatesTheNativeGeneration() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let generation = try await generation(of: fixture.libraryURL, runtime: runtime)
        fixture.close()
        let lease = ABIRetainLoadedImage(generation)
        if let lease { ABIReleaseImage(lease) }
        #expect(lease == nil)
        try fixture.load()
        let reloaded = try await self.generation(of: fixture.libraryURL, runtime: runtime)
        #expect(reloaded != generation)
    }

    private func generation(of url: URL, runtime: ABIRuntime) async throws -> UInt64 {
        let images = try await runtime.images(matching: .path(url))
        return try #require(images.first).identity.loadGeneration
    }
}

private final class FixtureBundleMarker: NSObject {}

@inline(never)
public func swiftFixtureEcho(_ value: Int32) -> Int32 { value + 1 }

private final class FixtureLibrary {
    let directory: URL
    let libraryURL: URL
    let namespace: String
    private var handle: UnsafeMutableRawPointer?

    init(namespace: String? = nil, load: Bool = true, swiftModule: String? = nil, threadLocal: Bool = false) throws {
        self.namespace = namespace ?? "Fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        libraryURL = directory.appendingPathComponent("fixture.dylib")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(swiftModule == nil ? "fixture.cpp" : "fixture.swift")
        let cxxSource = """
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
        extern "C" uintptr_t ABIFixtureAddress(int kind) {
            \(threadLocal ? "if (kind == 3) return reinterpret_cast<uintptr_t>(&\(self.namespace)::localCounter);" : "")
            if (kind == 0) return reinterpret_cast<uintptr_t>(&\(self.namespace)::add);
            if (kind == 1) return reinterpret_cast<uintptr_t>(&\(self.namespace)::counter);
            return *reinterpret_cast<uintptr_t *>(&\(self.namespace)::object) - 2 * sizeof(void *);
        }
        """
        if let swiftModule {
            #if arch(arm64)
            let target = "arm64-apple-macosx15.4"
            #else
            let target = "x86_64-apple-macosx15.4"
            #endif
            try "public func echo() {}".write(to: source, atomically: true, encoding: .utf8)
            try Self.run(["--sdk", "macosx", "swiftc", "-module-name", swiftModule, "-target", target,
                          "-emit-library", source.path, "-o", libraryURL.path])
        } else {
            try cxxSource.write(to: source, atomically: true, encoding: .utf8)
            try Self.run(["--sdk", "macosx", "clang++", "-std=c++20", "-mmacosx-version-min=15.4",
                          "-dynamiclib", source.path, "-o", libraryURL.path])
        }
        if load { try self.load() }
    }

    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // XCTest injects loader paths for its own Xcode. A child compiler must
        // resolve its own libraries, even when xcode-select points elsewhere.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    func load() throws {
        handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL)
        try #require(handle != nil, Comment(rawValue: dlerror().map { String(cString: $0) } ?? "dlopen failed"))
    }

    func address(kind: Int32) throws -> UInt {
        let symbol = try #require(dlsym(handle, "ABIFixtureAddress"))
        let function = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> UInt).self)
        return function(kind)
    }

    func close() {
        if let handle { dlclose(handle) }
        handle = nil
    }

    func cleanup() {
        close()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
