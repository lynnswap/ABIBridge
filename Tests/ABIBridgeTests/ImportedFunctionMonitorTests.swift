#if os(macOS)
import ABIBridge
import Darwin
import Foundation
import Synchronization
import Testing

private final class ImportMonitorFixture {
    let provider: FixtureLibrary
    let name: String
    let framework: String
    var consumers: [FixtureLibrary] = []
    var handles: [UnsafeMutableRawPointer] = []
    init() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        name = "ABIMonitored_" + suffix
        framework = "Monitored_" + suffix
        provider = try FixtureLibrary(cxxSource: "extern \"C\" int \(name)(int value) { return value; }")
    }
    func makeConsumer(addend: Bool = false) throws -> URL {
        let declaration = "extern \"C\" int \(name)(int);"
        let source = addend ? """
        \(declaration)
        asm(".data\\n.globl _ABIMonitoredBadSlot\\n_ABIMonitoredBadSlot:\\n.quad _\(name) + 1\\n");
        """ : """
        \(declaration)
        static int (*volatile slot)(int) = \(name);
        extern "C" int ABIMonitoredCall(int value) { return slot(value); }
        """
        let consumer = try FixtureLibrary(load: false, cxxSource: source, linkArguments: [provider.libraryURL.path])
        consumers.append(consumer)
        let directory = consumer.directory.appendingPathComponent("\(framework).framework")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(framework)
        try FileManager.default.copyItem(at: consumer.libraryURL, to: url)
        return url
    }
    func load(_ url: URL) throws { handles.append(try #require(dlopen(url.path, RTLD_NOW | RTLD_LOCAL))) }
    func cleanup() { handles.reversed().forEach { dlclose($0) }; consumers.forEach { $0.cleanup() }; provider.cleanup() }
    var declaration: NativeDeclaration { NativeDeclaration(name: name, language: .c) }
    var scope: ImageSelector { .framework(named: framework) }
}

private func waitForMonitoring(_ predicate: @escaping @Sendable () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    return predicate()
}

private final class MonitorCapture: Sendable {
    let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

@Suite(.serialized)
struct ImportedFunctionMonitorTests {
    private enum CallbackFailure: Error { case expected }
    @Test func hooksCurrentAndSubsequentlyLoadedImages() async throws {
        let fixture = try ImportMonitorFixture(); defer { fixture.cleanup() }
        let current = try fixture.makeConsumer(), future = try fixture.makeConsumer()
        try fixture.load(current)
        let runtime = ABIRuntime()
        let applied = Mutex<[String]>([])
        let monitor = try await unsafe runtime.monitorImportedFunction(fixture.declaration, as: ((Int32) -> Int32).self,
            in: fixture.scope, onFailure: { Issue.record($0) }, onImageUpdate: { update in
                switch update.state {
                case .installed: applied.withLock { $0.append(update.path) }
                case .failed(let error): Issue.record(error)
                default: break
                }
            }) { next, value in try next.proceed(value) + 1 }
        defer { monitor.invalidate() }
        #expect(try await waitForMonitoring { applied.withLock { $0.count == 1 } })
        try fixture.load(future)
        #expect(try await waitForMonitoring { applied.withLock { $0.count == 2 } })
        #expect(monitor.images.count == 2)
        for url in [current, future] {
            let call = try await runtime.cFunction(named: "ABIMonitoredCall", as: ((Int32) -> Int32).self, in: .path(url))
            #expect(try unsafe call.unsafeInvoke(41) == 42)
        }
        monitor.invalidate()
        let call = try await runtime.cFunction(named: "ABIMonitoredCall", as: ((Int32) -> Int32).self, in: .path(future))
        #expect(try unsafe call.unsafeInvoke(42) == 42)
    }

    @Test func reportsOneImageFailureAndContinuesWithOtherImages() async throws {
        let fixture = try ImportMonitorFixture(); defer { fixture.cleanup() }
        let bad = try fixture.makeConsumer(addend: true), good = try fixture.makeConsumer()
        let failed = Mutex(false), installed = Mutex(false)
        let monitor = try await unsafe ABIRuntime().monitorImportedFunction(fixture.declaration, as: ((Int32) -> Int32).self,
            in: fixture.scope, onFailure: { Issue.record($0) }, onImageUpdate: { update in
                switch update.state {
                case .failed: failed.withLock { $0 = true }
                case .installed: installed.withLock { $0 = true }
                default: break
                }
            }) { next, value in try next.proceed(value) + 1 }
        defer { monitor.invalidate() }
        try fixture.load(bad)
        #expect(try await waitForMonitoring { failed.withLock { $0 } })
        try fixture.load(good)
        #expect(try await waitForMonitoring { installed.withLock { $0 } })
        #expect(monitor.images.count == 2)
    }

    @Test func invalidationReleasesCapturesAndPreventsLaterLoadsFromReactivating() async throws {
        let fixture = try ImportMonitorFixture(); defer { fixture.cleanup() }
        let first = try fixture.makeConsumer(), later = try fixture.makeConsumer()
        let released = Mutex(false), applied = Mutex(false)
        let monitor: NativeImportedFunctionMonitor
        do {
            let capture = MonitorCapture { released.withLock { $0 = true } }
            monitor = try await unsafe ABIRuntime().monitorImportedFunction(fixture.declaration, as: ((Int32) -> Int32).self,
                in: fixture.scope, onFailure: { Issue.record($0) }, onImageUpdate: { update in
                    if case .installed = update.state { applied.withLock { $0 = true } }
                }) { next, value in
                    withExtendedLifetime(capture) {}
                    return try next.proceed(value) + 1
                }
        }
        try fixture.load(first)
        #expect(try await waitForMonitoring { applied.withLock { $0 } })
        monitor.invalidate()
        #expect(try await waitForMonitoring { released.withLock { $0 } })
        try fixture.load(later)
        let runtime = ABIRuntime()
        for url in [first, later] {
            let call = try await runtime.cFunction(named: "ABIMonitoredCall", as: ((Int32) -> Int32).self, in: .path(url))
            #expect(try unsafe call.unsafeInvoke(42) == 42)
        }
        #expect(monitor.images.count == 1)
    }

    @Test func invalidationPreservesAnInFlightCallbackAndItsOriginalError() async throws {
        let fixture = try ImportMonitorFixture(); defer { fixture.cleanup() }
        let url = try fixture.makeConsumer(); try fixture.load(url)
        let applied = Mutex(false), entered = Mutex(false), released = Mutex(false), failures = Mutex(0)
        let finish = DispatchSemaphore(value: 0)
        let monitor: NativeImportedFunctionMonitor
        do {
            let capture = MonitorCapture { released.withLock { $0 = true } }
            monitor = try await unsafe ABIRuntime().monitorImportedFunction(fixture.declaration, as: ((Int32) -> Int32).self,
                in: fixture.scope, onFailure: { error in
                    #expect(error is CallbackFailure)
                    failures.withLock { $0 += 1 }
                }, onImageUpdate: { update in
                    if case .installed = update.state { applied.withLock { $0 = true } }
                }) { next, value in
                    entered.withLock { $0 = true }; finish.wait()
                    withExtendedLifetime(capture) {}
                    _ = try next.proceed(value)
                    throw CallbackFailure.expected
                }
        }
        defer { finish.signal(); monitor.invalidate() }
        #expect(try await waitForMonitoring { applied.withLock { $0 } })
        let call = try await ABIRuntime().cFunction(named: "ABIMonitoredCall", as: ((Int32) -> Int32).self, in: .path(url))
        let task = Task.detached { try unsafe call.unsafeInvoke(41) }
        #expect(try await waitForMonitoring { entered.withLock { $0 } })
        monitor.invalidate()
        #expect(!released.withLock { $0 })
        #expect(try unsafe call.unsafeInvoke(42) == 42)
        finish.signal()
        #expect(try await task.value == 41)
        #expect(failures.withLock { $0 } == 1)
        #expect(try await waitForMonitoring { released.withLock { $0 } })
    }
}
#endif
