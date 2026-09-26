#if os(macOS)
#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ImageLoadingTests {
    @Test func explicitPathInitializesLocalSymbolsAndKeepsIndependentHandles() async throws {
        let name = "Loading_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(namespace: name, load: false, cxxSource: """
        namespace \(name) {
        static int value;
        __attribute__((constructor)) static void initialize() { value = 42; }
        __attribute__((used, noinline, visibility("hidden"))) int answer() { return value; }
        }
        """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        #expect(try await runtime.images(matching: scope).isEmpty)
        let declaration = NativeDeclaration(name: name + "::answer()", language: .cxx)
        await #expect(throws: ABIResolutionError.imageNotLoaded) {
            _ = try await runtime.resolve(declaration, in: scope, loading: .loadedOnly)
        }
        var first: NativeFunction<Int32>? = try await runtime.cxxFunction(named: declaration.name, as: (() -> Int32).self, in: scope)
        #expect(try unsafe first!.unsafeInvoke() == 42)
        var second: NativeFunction<Int32>? = try await runtime.cxxFunction(named: declaration.name, as: (() -> Int32).self, in: first!.symbol.image)
        #expect(first!.symbol.image.identity == second!.symbol.image.identity)
        await runtime.removeCachedResults()
        first = nil
        #expect(try unsafe second!.unsafeInvoke() == 42)
        second = nil
        #expect(try await runtime.images(matching: scope).isEmpty)
    }

    @Test func installNamesAndSymlinksSelectTheActualImage() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let alias = fixture.directory.appendingPathComponent("alias.dylib")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.libraryURL)
        let declaration = NativeDeclaration(name: fixture.namespace + "::add(int, int)", language: .cxx)
        #expect(try await runtime.images(matching: .installName(alias.path)).isEmpty)
        let first = try await runtime.resolve(declaration, in: .installName(alias.path))
        let second = try await runtime.resolve(declaration, in: .path(fixture.libraryURL))
        #expect(first.image.identity == second.image.identity)
        let inspected = try await runtime.images(matching: .installName(alias.path))
        #expect(inspected.map(\.identity) == [first.image.identity])
        let fromLease = try await runtime.resolve(declaration, in: inspected[0])
        #expect(fromLease.image.identity == first.image.identity)
        await runtime.removeCachedResults()
    }

    @Test func aBatchRefreshesAutomaticScopeAfterAnExplicitLoad() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: fixture.namespace + "::counter", language: .cxx, kind: .data)
        let results = await runtime.resolve([
            .init(declaration, loading: .loadedOnly),
            .init(declaration, in: [.path(fixture.libraryURL)]),
            .init(declaration, loading: .loadedOnly)
        ])
        #expect(throws: ABIResolutionError.declarationNotFound(declaration)) { try results[0].get() }
        let loaded = try results[1].get()
        #expect(try results[2].get().image.identity == loaded.image.identity)
        await runtime.removeCachedResults()
    }

    @Test func absentFrameworkScopesAdvanceToTheNextScope() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: fixture.namespace + "::counter", language: .cxx, kind: .data)
        let request = NativeSymbolRequest(declaration, in: [.framework(named: UUID().uuidString), .path(fixture.libraryURL)])
        let result = try await runtime.resolve(request)
        #expect(unsafe result.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        await runtime.removeCachedResults()
    }

    @Test func dependencyFailuresArePreservedAndCanBeRetried() async throws {
        let dependency = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int ABIRequiredValue() { return 42; }")
        defer { dependency.cleanup() }
        let fixture = try FixtureLibrary(load: false, cxxSource: """
        extern "C" int ABIRequiredValue();
        extern "C" int ABILoadedValue() { return ABIRequiredValue(); }
        """, linkArguments: [dependency.libraryURL.path])
        defer { fixture.cleanup() }
        let saved = dependency.directory.appendingPathComponent("saved.dylib")
        try FileManager.default.moveItem(at: dependency.libraryURL, to: saved)
        let runtime = ABIRuntime()
        do {
            _ = try await runtime.cFunction(named: "ABILoadedValue", as: (() -> Int32).self, in: .path(fixture.libraryURL))
            Issue.record("Missing dependency must fail acquisition")
        } catch ABIResolutionError.imageLoadFailed(let target, let message) {
            #expect(target == fixture.libraryURL.path)
            #expect(message.contains(dependency.directory.lastPathComponent))
        }
        try FileManager.default.moveItem(at: saved, to: dependency.libraryURL)
        let function = try await runtime.cFunction(named: "ABILoadedValue", as: (() -> Int32).self, in: .path(fixture.libraryURL))
        #expect(try unsafe function.unsafeInvoke() == 42)
        await runtime.removeCachedResults()
    }

    @Test func invalidTargetsAndMissingFilesHaveDistinctFailures() async throws {
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: "getpid", language: .c)
        let invalid = URL(string: "https://example.invalid/library")!
        await #expect(throws: ABIResolutionError.invalidImageTarget(invalid.absoluteString)) {
            _ = try await runtime.resolve(declaration, in: .path(invalid))
        }
        await #expect(throws: ABIResolutionError.invalidImageTarget("bad\0name")) {
            _ = try await runtime.resolve(declaration, in: .installName("bad\0name"))
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dylib")
        do {
            _ = try await runtime.resolve(.init(declaration, in: [.path(missing), .automatic]))
            Issue.record("Loader failure must not be hidden by automatic fallback")
        } catch ABIResolutionError.imageLoadFailed(let target, let message) {
            #expect(target == missing.path)
            #expect(!message.isEmpty)
        }
    }

    @Test func swiftFunctionAndTypeLookupAcquireTheirModule() async throws {
        let module = "LoadingSwift" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(load: false, swiftModule: module, swiftSource: """
        public struct Box { public init() {} }
        public func answer() -> Int { 42 }
        """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        #expect(try await runtime.images(matching: scope).isEmpty)
        let function = try await runtime.swiftFunction(named: module + ".answer()", as: (() -> Int).self, in: scope)
        #expect(try unsafe function.unsafeInvoke() == 42)
        let type = try await runtime.swiftType(named: module + ".Box", in: scope)
        #expect(type.name == module + ".Box")
        #expect(type.image.identity == function.symbol.image.identity)
        await runtime.removeCachedResults()
    }

    @Test func loadedFrameworkNameAmbiguityRequiresAPath() async throws {
        let name = "LoadingFramework" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fixtures: [FixtureLibrary] = []
        var handles: [UnsafeMutableRawPointer] = []
        defer {
            for handle in handles { dlclose(handle) }
            for fixture in fixtures { fixture.cleanup() }
        }
        for item in ["first", "second"] {
            let framework = directory.appendingPathComponent(item).appendingPathComponent(name + ".framework")
            try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
            let binary = framework.appendingPathComponent(name)
            let fixture = try FixtureLibrary(load: false, linkArguments: ["-Wl,-install_name," + binary.path])
            fixtures.append(fixture)
            try FileManager.default.copyItem(at: fixture.libraryURL, to: binary)
            handles.append(try #require(dlopen(binary.path, RTLD_LAZY | RTLD_LOCAL)))
        }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: fixtures[0].namespace + "::counter", language: .cxx, kind: .data)
        do {
            _ = try await runtime.resolve(declaration, in: .framework(named: name))
            Issue.record("A framework name must not select between two loaded images")
        } catch ABIResolutionError.ambiguousImage(let candidates) { #expect(candidates.count == 2) }
        let inspected = try await runtime.resolve(declaration, in: .framework(named: name), loading: .loadedOnly)
        #expect(unsafe inspected.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        await runtime.removeCachedResults()
    }

    @Test func repeatedAcquisitionReusesTheSymbolIndex() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: fixture.namespace + "::counter", language: .cxx, kind: .data)
        let scope = ImageSelector.path(fixture.libraryURL)
        let clock = ContinuousClock()
        let coldStart = clock.now
        let first = try await runtime.resolve(declaration, in: scope)
        let cold = coldStart.duration(to: clock.now)
        for policy in [ImageLoadingPolicy.loadedOnly, .ifNeeded] {
            let start = clock.now
            for _ in 0..<100 {
                let next = try await runtime.resolve(declaration, in: scope, loading: policy)
                #expect(next.image.identity == first.image.identity)
            }
            print("Image loading: cold=\(cold), policy=\(policy), 100 warm resolutions=\(start.duration(to: clock.now))")
        }
        await runtime.removeCachedResults()
    }

    #if DEBUG
    @Test func frameworkDiscoveryPreservesAmbiguousCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "Framework_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let roots = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        for root in roots {
            let framework = root.appendingPathComponent(name + ".framework")
            try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
            try Data().write(to: framework.appendingPathComponent(name))
        }
        #expect(FrameworkImages.candidates(named: name, bundleDirectories: roots).count == 2)
    }
    #endif
}
#endif
