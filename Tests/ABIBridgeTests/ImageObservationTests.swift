#if os(macOS)
import ABIBridgeCore
import Darwin
import Foundation
import Synchronization
import Testing

private struct ObservedImage: Sendable {
    let generation: UInt64
    let path: String
}

private final class ObservationCallback: Sendable {
    let receive: @Sendable ([ObservedImage]) -> Void
    let released: @Sendable () -> Void
    init(_ receive: @escaping @Sendable ([ObservedImage]) -> Void, released: @escaping @Sendable () -> Void) {
        self.receive = receive
        self.released = released
    }
    deinit { released() }
}

private final class CatalogObservation: @unchecked Sendable {
    let handle: OpaquePointer
    init(released: @escaping @Sendable () -> Void = {}, receive: @escaping @Sendable ([ObservedImage]) -> Void) throws {
        let callback = ObservationCallback(receive, released: released)
        var error: OpaquePointer?
        let handle = ABIObserveLoadedImages(Unmanaged.passRetained(callback).toOpaque(), { context, list in
            guard let list else { Issue.record("Missing catalog snapshot"); return }
            let images = (0..<ABIImageListCount(list)).map { index in
                let value = ABIImageListGet(list, index)
                return ObservedImage(generation: value.generation, path: String(cString: value.path))
            }
            Unmanaged<ObservationCallback>.fromOpaque(context!).takeUnretainedValue().receive(images)
        }, { context in
            Unmanaged<ObservationCallback>.fromOpaque(context!).release()
        }, &error)
        defer { if let error { ABIReleaseResolutionFailure(error) } }
        self.handle = try #require(handle, Comment(rawValue: error.map { String(cString: ABIResolutionFailureMessage($0)) } ?? "No observer"))
    }
    func invalidate() { ABIInvalidateImageObservation(handle) }
    deinit { ABIReleaseImageObservation(handle) }
}

private func waitForObservation(_ condition: @escaping @Sendable () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

@Suite(.serialized)
struct ImageObservationTests {
    @Test func snapshotsTrackUnloadAndReloadWithoutRetainingImages() async throws {
        let fixture = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int observedValue() { return 42; }")
        let middle = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int middleValue() { return 1; }")
        let last = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int lastValue() { return 2; }")
        defer { fixture.cleanup(); middle.cleanup(); last.cleanup() }
        // Other suites legitimately retain images during automatic symbol
        // lookup. An isolated process gives this test sole loader ownership.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let core = root.appendingPathComponent("Sources/ABIBridgeCore")
        let executable = fixture.directory.appendingPathComponent("image-observation-test")
        try FixtureLibrary.run([
            "--sdk", "macosx", "clang++", "-std=c++20", "-mmacosx-version-min=15.4",
            "-I", core.appendingPathComponent("include").path,
            root.appendingPathComponent("Tests/NativeConsumer/ImageObservationFixture.cpp").path,
            core.appendingPathComponent("LoadedImages.cpp").path,
            core.appendingPathComponent("NativeFailure.cpp").path,
            "-L/usr/lib/swift", "-lswiftCore", "-o", executable.path,
        ])
        try FixtureLibrary.run([executable.path, fixture.libraryURL.path, middle.libraryURL.path, last.libraryURL.path])
    }

    @Test func deliveryAndContextReleaseCanReenterTheCatalog() async throws {
        let fixture = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int nestedValue() { return 7; }")
        defer { fixture.cleanup() }
        let path = fixture.libraryURL.path
        let entered = Mutex(false), completed = Mutex(false), released = Mutex(false)
        let observation = try CatalogObservation(released: {
            let snapshot = ABICopyLoadedImages()
            #expect(snapshot != nil)
            ABIFreeImageList(snapshot)
            released.withLock { $0 = true }
        }) { _ in
            guard entered.withLock({ flag in if flag { return false }; flag = true; return true }) else { return }
            let snapshot = ABICopyLoadedImages()
            #expect(snapshot != nil)
            ABIFreeImageList(snapshot)
            let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            #expect(handle != nil)
            if let handle { dlclose(handle) }
            do {
                let nested = try CatalogObservation { _ in }
                nested.invalidate()
            } catch { Issue.record(error) }
            completed.withLock { $0 = true }
        }
        #expect(try await waitForObservation { completed.withLock { $0 } })
        observation.invalidate()
        #expect(try await waitForObservation { released.withLock { $0 } })
    }

    @Test func constructorCancellationDoesNotWaitForAnInFlightDelivery() async throws {
        let entered = Mutex(false), returned = Mutex(false), released = Mutex(false)
        let finish = DispatchSemaphore(value: 0)
        let observation = try CatalogObservation(released: {
            #expect(returned.withLock { $0 })
            released.withLock { $0 = true }
        }) { _ in
            entered.withLock { $0 = true }
            finish.wait()
            returned.withLock { $0 = true }
        }
        defer { finish.signal(); observation.invalidate() }
        #expect(try await waitForObservation { entered.withLock { $0 } })
        let cancel: @convention(c) (OpaquePointer?) -> Void = ABIInvalidateImageObservation
        let fixture = try FixtureLibrary(load: false, cxxSource: """
        #include <stdint.h>
        __attribute__((constructor)) static void cancelObservation() {
            auto cancel = reinterpret_cast<void(*)(void*)>(uintptr_t(\(unsafeBitCast(cancel, to: UInt.self))));
            cancel(reinterpret_cast<void*>(uintptr_t(\(UInt(bitPattern: observation.handle)))));
        }
        extern "C" int cancellationFixture() { return 1; }
        """)
        defer { fixture.cleanup() }
        let path = fixture.libraryURL.path
        let loaded = Mutex(false)
        Thread.detachNewThread {
            let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            #expect(handle != nil)
            if let handle { dlclose(handle) }
            loaded.withLock { $0 = true }
        }
        let cancelledWithoutWaiting = try await waitForObservation { loaded.withLock { $0 } }
        #expect(cancelledWithoutWaiting)
        #expect(!released.withLock { $0 })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { observation.invalidate() } }
        }
        finish.signal()
        #expect(try await waitForObservation { released.withLock { $0 } })
        // Finish the loader even if a regression made cancellation wait above.
        #expect(try await waitForObservation { loaded.withLock { $0 } })
    }

    @Test func rejectedRegistrationReleasesTransferredContext() {
        let released = Mutex(false)
        do {
            let callback = ObservationCallback({ _ in }, released: { released.withLock { $0 = true } })
            let context = Unmanaged.passRetained(callback).toOpaque()
            var error: OpaquePointer?
            let observation = ABIObserveLoadedImages(context, nil, { pointer in
                Unmanaged<ObservationCallback>.fromOpaque(pointer!).release()
            }, &error)
            #expect(observation == nil)
            #expect(error != nil)
            if let error {
                #expect(ABIResolutionFailureCode(error) == ABIFailureInvalidRequest)
                ABIReleaseResolutionFailure(error)
            }
            withExtendedLifetime(callback) {}
        }
        #expect(released.withLock { $0 })
    }

    @Test func deliveryCanInvalidateItsOwnObservation() async throws {
        let ready = DispatchSemaphore(value: 0)
        let address = Mutex<UInt>(0), completed = Mutex(false), released = Mutex(false)
        let observation = try CatalogObservation(released: { released.withLock { $0 = true } }) { _ in
            ready.wait()
            ABIInvalidateImageObservation(OpaquePointer(bitPattern: address.withLock { $0 }))
            completed.withLock { $0 = true }
        }
        defer { ready.signal(); observation.invalidate() }
        address.withLock { $0 = UInt(bitPattern: observation.handle) }
        ready.signal()
        #expect(try await waitForObservation { completed.withLock { $0 } && released.withLock { $0 } })
    }
}
#endif
