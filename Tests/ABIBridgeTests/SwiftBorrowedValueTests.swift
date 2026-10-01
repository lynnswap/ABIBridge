#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import Foundation
import Synchronization
import Testing

private final class BorrowResults: @unchecked Sendable {
    let lock = NSLock()
    var texts: [String] = []
    var errors: [String] = []
    var escaped: NativeSwiftBorrowedValue?
    var returned: AnyObject?
    func record(_ body: () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        do { try body() } catch { errors.append(String(describing: error)) }
    }
}

private final class BorrowDeaths: Sendable { let value = Mutex(0) }
private final class BorrowCapture: Sendable {
    let deaths: BorrowDeaths
    init(_ deaths: BorrowDeaths) { self.deaths = deaths }
    deinit { deaths.value.withLock { $0 += 1 } }
}

@Suite(.serialized)
struct SwiftBorrowedValueTests {
    @Test func runtimeOnlyValuesUseScopedSelfAndOwnedResults() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeRecord")
        let text = try await type.borrowedGetter(named: "text", as: String.self)
        let changed = try await type.borrowedGetter(named: "changed", as: AnyObject?.self)
        let length = try await type.borrowedMethod(named: "length()", as: (() -> Int64).self)
        let cancel = try await type.borrowedMethod(named: "cancel()", as: (() -> Void).self)
        let visit = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.visitRuntimeRecord(Swift.AnyObject, Swift.String, Swift.UnsafeMutablePointer<Swift.Int32>, (ManagedSwiftFixtures.RuntimeRecord) -> ()) -> ()",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftBorrowingClosure<Void>) -> Void).self)
        let reference = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.referenceRuntimeRecord(_:_:_:)",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>) -> String).self)
        let results = BorrowResults()
        let body = try NativeSwiftBorrowingClosure(borrowing: type) { record in
            results.record {
                results.escaped = record
                results.texts.append(try unsafe text.unsafeInvoke(on: record))
                results.returned = try unsafe changed.unsafeInvoke(on: record)
                #expect(try unsafe length.unsafeInvoke(on: record) == 700)
                try unsafe cancel.unsafeInvoke(on: record)
            }
        }
        let input = String(repeating: "managed", count: 100)
        weak var weakObject: NSObject?
        let cancellations = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancellations.initialize(to: 0)
        defer { cancellations.deinitialize(count: 1); cancellations.deallocate() }
        do {
            let object = NSObject()
            weakObject = object
            try unsafe visit.unsafeInvoke(object, input, cancellations, body)
            #expect(cancellations.pointee == 3)
            let expected = try unsafe reference.unsafeInvoke(object, input, cancellations)
            #expect(results.texts.joined() == expected)
            #expect(results.returned === object)
        }
        #expect(results.errors.isEmpty)
        #expect(weakObject != nil)
        results.returned = nil
        #expect(weakObject == nil)
        let expired = try #require(results.escaped)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe text.unsafeInvoke(on: expired)
        }
    }

    @Test func activeBorrowsRejectAnotherThreadAndDifferentNativeType() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeRecord")
        let text = try await type.borrowedGetter(named: "text", as: String.self)
        let other = try await runtime.swiftType(named: "Swift.String")
        let otherMember = try await other.borrowedGetter(named: "count", as: Int.self)
        let visit = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.visitRuntimeRecord(Swift.AnyObject, Swift.String, Swift.UnsafeMutablePointer<Swift.Int32>, (ManagedSwiftFixtures.RuntimeRecord) -> ()) -> ()",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftBorrowingClosure<Void>) -> Void).self)
        let body = try NativeSwiftBorrowingClosure(borrowing: type) { value in
            #expect(throws: ABIInvocationError.self) { try unsafe otherMember.unsafeInvoke(on: value) }
            let box = BorrowBox(value)
            let done = DispatchSemaphore(value: 0)
            Thread {
                #expect(throws: NativeSwiftBorrowError.wrongThread) { try unsafe text.unsafeInvoke(on: box.value) }
                done.signal()
            }.start()
            done.wait()
            #expect(throws: Never.self) { try unsafe text.unsafeInvoke(on: value) }
        }
        var cancellations: Int32 = 0
        try withUnsafeMutablePointer(to: &cancellations) { pointer in
            try unsafe visit.unsafeInvoke(NSObject(), "text", pointer, body)
        }
    }

#if DEBUG
    @Test func formallyIndirectAuthenticationMatchesCompilerEvidence() {
        // check-swift-generic-call-codegen.py records these arm64e call sites.
        #expect(swiftClosureDiscriminator(parameters: ["-indirect"], result: nil) == 18589)
        #expect(swiftClosureDiscriminator(parameters: [], result: "-indirect") == 29199)
    }
#endif

    @Test func nativeRetentionKeepsCallbackAliveAndCreatesFreshBorrows() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeRecord")
        let text = try await type.borrowedGetter(named: "text", as: String.self)
        let save = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.saveRuntimeCallback((ManagedSwiftFixtures.RuntimeRecord) -> ()) -> ()",
            as: ((NativeSwiftBorrowingClosure<Void>) -> Void).self)
        let fire = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.fireRuntimeCallback(_:_:_:)",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>) -> Void).self)
        let clear = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.clearRuntimeCallback()", as: (() -> Void).self)
        let deaths = BorrowDeaths()
        let results = BorrowResults()
        do {
            let capture = BorrowCapture(deaths)
            let callback = try NativeSwiftBorrowingClosure(borrowing: type) { record in
                withExtendedLifetime(capture) {
                    results.record {
                        if let previous = results.escaped {
                            #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try unsafe text.unsafeInvoke(on: previous) }
                        }
                        results.escaped = record
                        results.texts.append(try unsafe text.unsafeInvoke(on: record))
                    }
                }
            }
            try unsafe save.unsafeInvoke(callback)
        }
        #expect(deaths.value.withLock { $0 } == 0)
        let cancellations = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancellations.initialize(to: 0)
        defer { cancellations.deinitialize(count: 1); cancellations.deallocate() }
        try unsafe fire.unsafeInvoke(NSObject(), "first", cancellations)
        try unsafe fire.unsafeInvoke(NSObject(), "second", cancellations)
        try unsafe clear.unsafeInvoke()
        #expect(results.texts == ["first", "second"])
        #expect(results.errors.isEmpty)
        #expect(deaths.value.withLock { $0 } == 1)
    }
}

private final class BorrowBox: @unchecked Sendable {
    let value: NativeSwiftBorrowedValue
    init(_ value: NativeSwiftBorrowedValue) { self.value = value }
}
