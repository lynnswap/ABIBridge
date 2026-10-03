import ABIBridge
import CoreGraphics
import SwiftReplacementFixtures
import SwiftValueFixtures
import Synchronization

extension ExplicitVector: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitVector", fields: [.pointer, .double, .double])
    }
}
extension ExplicitChoice: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitChoice", fields: Array(repeating: .uint, count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size) + [.uint8])
    }
}
extension ExplicitLarge: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitLarge", fields: [.pointer, .int64, .int64, .int64, .int64])
    }
}

extension ResilientValue: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { try! .opaque(named: "ResilientValue") }
}
extension GenericValue: ABIBridgeSwiftValue where Value == Int64 {
    public static var swiftABIType: NativeType { .int64 }
}
extension Namespace.箱: ABIBridgeSwiftValue where Value == Int64 {
    public static var swiftABIType: NativeType { .int64 }
}

private final class ClosureProbeCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureProbeCapture: Sendable {
    let counter: ClosureProbeCounter
    let bias: Int64 = 7
    init(_ counter: ClosureProbeCounter) { self.counter = counter }
    deinit { counter.increment() }
}

private final class NestedClosureProbeCapture: @unchecked Sendable {
    var value: NativeSwiftClosure<(Int64) -> Int64>?
    var asyncValue: NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>?
}

@MainActor func validateSwiftClosureValues() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    do {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        let make = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.makeConcreteNestedProducer()",
            as: (() -> NativeSwiftClosure<() -> Inner>).self)
        let native = try unsafe make.unsafeInvoke().unsafeInvoke()
        let receive = try NativeSwiftClosure<(Inner) throws -> Int64> { value in
            try unsafe value.unsafeInvoke(35)
        }
        try check(try unsafe receive.unsafeInvoke(native) == 42,
            "Direct host callback arguments forward a compatible native closure")
        let owner = NestedClosureProbeCapture()
        owner.value = native
        let produce = try NativeSwiftClosure<() throws -> Inner> { owner.value! }
        let returned = try unsafe produce.unsafeInvoke()
        try check(try unsafe returned.unsafeInvoke(35) == 42,
            "Direct host callback results forward a compatible native closure")

        typealias AsyncInner = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias AsyncCaller = NativeSwiftClosure<nonisolated(nonsending) (AsyncInner, Int64) async -> Int64>
        final class AsyncOwner: @unchecked Sendable {
            let value: AsyncCaller
            init(_ value: AsyncCaller) { self.value = value }
        }
        let makeAsync = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.makeConcreteNestedAsyncCaller()", as: (() -> AsyncCaller).self)
        let asyncOwner = AsyncOwner(try unsafe makeAsync.unsafeInvoke())
        let receiveAsync = try NativeSwiftClosure<(AsyncCaller) -> Int64> { _ in 42 }
        try check(try unsafe receiveAsync.unsafeInvoke(asyncOwner.value) == 42,
            "A synchronous host callback accepts a native async closure with nested inputs")
        let produceAsync = try NativeSwiftClosure<() throws -> AsyncCaller> { asyncOwner.value }
        let returnedAsync = try unsafe produceAsync.unsafeInvoke()
        let body: nonisolated(nonsending) @Sendable (Int64) async -> Int64 = { value in
            await Task.yield()
            return value + 7
        }
        try check(try unsafe await returnedAsync.unsafeInvoke(AsyncInner(body), 35) == 42,
            "A synchronous host callback returns a callable native async closure with nested inputs")
    }

    do {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Callback = NativeSwiftClosure<(Inner) throws -> Int64>
        let visit = try await runtime.swiftFunction(
            named: "SwiftReplacementFixtures.visitOwnedNestedClosure(_:_:)",
            as: ((Inner, Callback) throws -> Int64).self)
        let destroyed = ClosureProbeCounter()
        do {
            let capture = ClosureProbeCapture(destroyed)
            let original = try Inner { $0 + capture.bias }
            let callback = try Callback { borrowed in
                let consume = try NativeSwiftClosure<(NativeSwiftConsuming<Inner>) throws -> Int64> { value in
                    try unsafe value.value.unsafeInvoke(35)
                }
                let result = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(borrowed))
                guard result == 42 else { throw ArchitectureValidationFailure(description: "Consuming a borrowed closure changed its result") }
                return try unsafe borrowed.unsafeInvoke(35)
            }
            try check(try unsafe visit.unsafeInvoke(original, callback) == 50,
                "Consuming a copied escaping borrow preserves the provider's original closure")
        }
        try check(destroyed.count == 1, "Consumed closure copies destroy captures exactly once")
        let type = try await runtime.swiftType(named: "SwiftReplacementFixtures.EvaluatedIntegerClosure",
            as: EvaluatedIntegerClosure.self)
        let create = try await type.initializer(named: "init(_:)", as: ((Inner) -> EvaluatedIntegerClosure).self)
        let initializerDeaths = ClosureProbeCounter()
        do {
            let capture = ClosureProbeCapture(initializerDeaths)
            let value = try Inner { $0 + capture.bias }
            try check(try unsafe create.unsafeInvoke(value).value == 42,
                "An initializer evaluates a guaranteed closure argument")
        }
        try check(initializerDeaths.count == 1, "A nonescaping initializer argument releases its temporary context")
        let stack = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitNestedClosure(_:)",
            as: ((Callback) throws -> Int64).self)
        let entered = ClosureProbeCounter()
        let stackBody = try Callback { borrowed in
            let consume = try NativeSwiftClosure<(NativeSwiftConsuming<Inner>) -> Void> { _ in entered.increment() }
            do {
                try unsafe consume.unsafeInvoke(NativeSwiftConsuming(borrowed))
                throw ArchitectureValidationFailure(description: "A consuming call accepted a nonescaping borrow")
            } catch is ABIResolutionError {}
            return try unsafe create.unsafeInvoke(borrowed).value
        }
        try check(try unsafe stack.unsafeInvoke(stackBody) == 72 && entered.count == 0,
            "Stack borrows remain valid for initializers and fail before a consuming callback enters")

        typealias Async = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias AsyncVisitor = NativeSwiftClosure<nonisolated(nonsending) (Async) async throws -> Void>
        let visitAsync = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitEscapingNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (AsyncVisitor) async throws -> Void).self)
        let asyncBody: nonisolated(nonsending) @Sendable (Async) async throws -> Void = { borrowed in
            let synchronous = try NativeSwiftClosure<(NativeSwiftConsuming<Async>) -> Int64> { _ in 42 }
            guard try unsafe synchronous.unsafeInvoke(NativeSwiftConsuming(borrowed)) == 42 else {
                throw ArchitectureValidationFailure(description: "A synchronous consumer rejected an async closure")
            }
            let body: nonisolated(nonsending) @Sendable (NativeSwiftConsuming<Async>) async throws -> Int64 = { value in
                await Task.yield()
                return try unsafe await value.value.unsafeInvoke(35)
            }
            let consume = try NativeSwiftClosure(body)
            guard try unsafe await consume.unsafeInvoke(NativeSwiftConsuming(borrowed)) == 42,
                  try unsafe await borrowed.unsafeInvoke(1) == 43 else {
                throw ArchitectureValidationFailure(description: "Async consumption lost the original borrowed context")
            }
        }
        try unsafe await visitAsync.unsafeInvoke(AsyncVisitor(asyncBody))
        try check(true, "Sync and async consumers retain an escaping async borrow across suspension")
    }
    if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
        typealias Sync = NativeSwiftClosure<(Int64) -> Int64>
        typealias Async = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        let visitSync = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitClosureSynchronously(_:)",
            as: ((NativeSwiftClosure<(Sync) -> Void>) -> Void).self)
        let visitAsync = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitAsyncClosureSynchronously(_:)",
            as: ((NativeSwiftClosure<(Async) -> Void>) -> Void).self)
        let forwardSync = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.applyBorrowedClosureAsync(_:_:)",
            as: (nonisolated(nonsending) (Sync, Int64) async -> Int64).self)
        let forwardAsync = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.applyBorrowedAsyncClosure(_:_:)",
            as: (nonisolated(nonsending) (Async, Int64) async -> Int64).self)
        let inspect = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.inspectAsyncClosureSynchronously(_:)",
            as: ((Async) -> Int64).self)
        var syncTask: Task<Int64, any Error>?
        try unsafe NativeSwiftClosure<(Sync) -> Void>.withUnsafeNonescaping({ value in
            syncTask = Task.immediate { @MainActor in try unsafe await forwardSync.unsafeInvoke(value, 20) }
        }) { try unsafe visitSync.unsafeInvoke($0) }
        do { _ = try await syncTask!.value; throw ArchitectureValidationFailure(description: "A synchronous closure borrow crossed suspension") }
        catch NativeSwiftBorrowError.synchronousBorrow { checks.append("Synchronous closure forwarding rejects a synchronous source borrow before async native entry") }
        var asyncTask: Task<Int64, any Error>?
        var directTask: Task<Int64, any Error>?
        let directBody: nonisolated(nonsending) @Sendable (Async, Int64) async throws -> Int64 = { value, number in
            try unsafe await value.unsafeInvoke(number)
        }
        let direct = try NativeSwiftClosure<nonisolated(nonsending) (Async, Int64) async throws -> Int64>(directBody)
        var inspectionResult: Int64?
        var inspectionError: (any Error)?
        try unsafe NativeSwiftClosure<(Async) -> Void>.withUnsafeNonescaping({ value in
            do { inspectionResult = try unsafe inspect.unsafeInvoke(value) }
            catch { inspectionError = error }
            asyncTask = Task.immediate { @MainActor in try unsafe await forwardAsync.unsafeInvoke(value, 20) }
            directTask = Task.immediate { @MainActor in try unsafe await direct.unsafeInvoke(value, 20) }
        }) { try unsafe visitAsync.unsafeInvoke($0) }
        if let inspectionError { throw inspectionError }
        try check(inspectionResult == 42, "A synchronous native call can receive an async closure borrowed from a synchronous scope")
        do { _ = try await asyncTask!.value; throw ArchitectureValidationFailure(description: "An async closure borrow crossed its synchronous source scope") }
        catch NativeSwiftBorrowError.synchronousBorrow { checks.append("Async closure forwarding rejects a synchronous source borrow before async native entry") }
        do { _ = try await directTask!.value; throw ArchitectureValidationFailure(description: "A direct async call accepted a synchronous source borrow") }
        catch NativeSwiftBorrowError.synchronousBorrow { checks.append("Direct async closure invocation checks the lifetime of closure inputs") }

        typealias Callback = NativeSwiftClosure<nonisolated(nonsending) (Async) async throws -> Int64>
        let visitSuspending = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (Callback) async throws -> Int64).self)
        let body: nonisolated(nonsending) @Sendable (Async) async throws -> Int64 = { value in
            try unsafe await forwardAsync.unsafeInvoke(value, 20)
        }
        try check(try unsafe await visitSuspending.unsafeInvoke(Callback(body)) == 42,
            "Async closure forwarding preserves a valid suspending native borrow")
        let forwardSyncBody: nonisolated(nonsending) @Sendable (Sync) async throws -> Int64 = { value in
            try unsafe await forwardSync.unsafeInvoke(value, 20)
        }
        let receiveSync = try NativeSwiftClosure<nonisolated(nonsending) (Sync) async throws -> Int64>(forwardSyncBody)
        try check(try unsafe await receiveSync.unsafeInvoke(Sync { $0 + 22 }) == 42,
            "A synchronous closure borrowed in an async scope can be forwarded across suspension")
    }
    let nested = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.visitNestedClosure(_:)",
        as: ((NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64>) throws -> Int64).self)
    let saved = NestedClosureProbeCapture()
    let nestedInputBody = try NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64> { value in
        saved.value = value
        return try unsafe value.unsafeInvoke(20)
    }
    try check(try unsafe nested.unsafeInvoke(nestedInputBody) == 42,
              "Nested Swift closure authenticates and borrows a stack capture")
    do { _ = try unsafe saved.value!.unsafeInvoke(1); throw ArchitectureValidationFailure(description: "A nested borrow escaped") }
    catch NativeSwiftBorrowError.expiredBorrow { checks.append("Nested closure expires with its native callback scope") }
    typealias NestedAsync = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
    typealias NestedAsyncBody = NativeSwiftClosure<nonisolated(nonsending) (NestedAsync) async throws -> Int64>
    let nestedAsync = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.visitNestedAsyncClosure(_:)",
        as: (nonisolated(nonsending) (NestedAsyncBody) async throws -> Int64).self)
    let asyncBody: nonisolated(nonsending) @Sendable (NestedAsync) async throws -> Int64 = { value in
        saved.asyncValue = value
        await Task.yield()
        return try unsafe await value.unsafeInvoke(20)
    }
    try check(try unsafe await nestedAsync.unsafeInvoke(NestedAsyncBody(asyncBody)) == 42,
              "Nested async closure authenticates and preserves its borrow across suspension")
    do { _ = try unsafe await saved.asyncValue!.unsafeInvoke(1); throw ArchitectureValidationFailure(description: "An async nested borrow escaped") }
    catch NativeSwiftBorrowError.expiredBorrow { checks.append("Nested async closure expires after native completion") }
    let produceClosure = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callClosureProducer(_:)",
        as: ((NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>>) throws -> Int64).self)
    let producer = try NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>> {
        try NativeSwiftClosure { (value: Int64) in value + 7 }
    }
    try check(try unsafe produceClosure.unsafeInvoke(producer) == 42,
              "Nested closure result transfers its owned authenticated context to native code")
    typealias NativeInner = NativeSwiftClosure<(Int64) -> Int64>
    typealias NativeCaller = NativeSwiftClosure<(NativeInner, Int64) -> Int64>
    typealias NativeProducer = NativeSwiftClosure<() -> NativeInner>
    let concreteFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteNestedCaller()", as: (() -> NativeCaller).self)
    let genericCall = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNestedRuntimeCaller<A>(((A) -> A, A) -> A, A) -> A",
        as: ((NativeCaller, Int64) -> Int64).self, genericArguments: [.type(Int64.self)])
    let concreteCaller = try unsafe concreteFactory.unsafeInvoke()
    try check(try unsafe genericCall.unsafeInvoke(concreteCaller, 42) == 42,
        "Native nested concrete input reabstracts a generic callback and authenticates both entries")
    let genericFactory = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeNestedRuntimeCaller<A>(A.Type) -> ((A) -> A, A) -> A",
        as: ((Int64.Type) -> NativeCaller).self, genericArguments: [.type(Int64.self)])
    let concreteCall = try await runtime.swiftFunction(named: "SwiftValueFixtures.callConcreteNestedCaller(_:)", as: ((NativeCaller) -> Int64).self)
    try check(try unsafe concreteCall.unsafeInvoke(genericFactory.unsafeInvoke(Int64.self)) == 42,
        "Native nested generic input reabstracts a concrete callback")
    let concreteProducer = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteNestedProducer()", as: (() -> NativeProducer).self)
    let genericProduce = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNonthrowingNestedRuntimeProducer<A>(() -> (A) -> A, A) -> A",
        as: ((NativeProducer, Int64) -> Int64).self, genericArguments: [.type(Int64.self)])
    try check(try unsafe genericProduce.unsafeInvoke(concreteProducer.unsafeInvoke(), 35) == 42,
        "Native nested concrete result transfers a generic authenticated closure")
    let genericProducer = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeNestedRuntimeProducer<A>(A.Type) -> () -> (A) -> A",
        as: ((Int64.Type) -> NativeProducer).self, genericArguments: [.type(Int64.self)])
    let concreteProduce = try await runtime.swiftFunction(named: "SwiftValueFixtures.callConcreteNestedProducer(_:)", as: ((NativeProducer) -> Int64).self)
    try check(try unsafe concreteProduce.unsafeInvoke(genericProducer.unsafeInvoke(Int64.self)) == 42,
        "Native nested generic result transfers a concrete authenticated closure")
    typealias NativeAsyncCaller = NativeSwiftClosure<nonisolated(nonsending) (NestedAsync, Int64) async -> Int64>
    let concreteAsyncFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteNestedAsyncCaller()", as: (() -> NativeAsyncCaller).self)
    let genericAsyncCall = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNestedRuntimeAsyncCaller<A>(nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async -> A, A) async -> A",
        as: (nonisolated(nonsending) (NativeAsyncCaller, Int64) async -> Int64).self, genericArguments: [.type(Int64.self)])
    let concreteAsyncCaller = try unsafe concreteAsyncFactory.unsafeInvoke()
    try check(try unsafe await genericAsyncCall.unsafeInvoke(concreteAsyncCaller, 42) == 42,
        "Native nested async concrete input reabstracts a generic callback across suspension")
    let genericAsyncFactory = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeNestedRuntimeAsyncCaller<A>(A.Type) -> nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async -> A",
        as: ((Int64.Type) -> NativeAsyncCaller).self, genericArguments: [.type(Int64.self)])
    let concreteAsyncCall = try await runtime.swiftFunction(named: "SwiftValueFixtures.callConcreteNestedAsyncCaller(_:)",
        as: (nonisolated(nonsending) (NativeAsyncCaller) async -> Int64).self)
    let genericAsyncCaller = try unsafe genericAsyncFactory.unsafeInvoke(Int64.self)
    try check(try unsafe await concreteAsyncCall.unsafeInvoke(genericAsyncCaller) == 42,
        "Native nested async generic input reabstracts a concrete callback across suspension")
    typealias NativeAsyncProducer = NativeSwiftClosure<nonisolated(nonsending) () async -> NestedAsync>
    let asyncProducerFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteNestedAsyncProducer()", as: (() -> NativeAsyncProducer).self)
    let genericAsyncProduce = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNestedRuntimeAsyncProducer<A>(nonisolated(nonsending) () async -> nonisolated(nonsending) (A) async -> A, A) async -> A",
        as: (nonisolated(nonsending) (NativeAsyncProducer, Int64) async -> Int64).self, genericArguments: [.type(Int64.self)])
    let asyncProducer = try unsafe asyncProducerFactory.unsafeInvoke()
    try check(try unsafe await genericAsyncProduce.unsafeInvoke(asyncProducer, 35) == 42,
        "Native nested async result transfers its authenticated generic descriptor")
    typealias NativePackInner = NativeSwiftClosure<(Int64, String) -> Int64>
    typealias NativePackCaller = NativeSwiftClosure<(NativePackInner, Int64, String) -> Int64>
    let packFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteNestedPackCaller()", as: (() -> NativePackCaller).self)
    let packCall = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNestedRuntimePackCaller<each A>(_: repeat A, body: ((repeat A) -> Swift.Int64, repeat A) -> Swift.Int64) -> Swift.Int64",
        as: ((Int64, String, NativePackCaller) -> Int64).self, genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    try check(try unsafe packCall.unsafeInvoke(35, "pack", packFactory.unsafeInvoke()) == 42,
        "Native nested pack callback reabstracts its inner address vector and authentication")
    let copiedInputs = NestedClosureProbeCapture()
    typealias CopyInput = NativeSwiftClosure<(NativeInner) throws -> Void>
    let visitEscaping = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitEscapingNestedClosure(_:)",
        as: ((CopyInput) throws -> Void).self)
    try unsafe visitEscaping.unsafeInvoke(CopyInput { copiedInputs.value = try $0.copy() })
    try check(try unsafe copiedInputs.value!.unsafeInvoke(35) == 42,
        "Copying a native escaping input owns its context after the synchronous callback returns")
    typealias CopyAsyncInput = NativeSwiftClosure<nonisolated(nonsending) (NestedAsync) async throws -> Void>
    let visitAsyncEscaping = try await runtime.swiftFunction(named: "SwiftReplacementFixtures.visitEscapingNestedAsyncClosure(_:)",
        as: (nonisolated(nonsending) (CopyAsyncInput) async throws -> Void).self)
    let copyAsyncBody: nonisolated(nonsending) @Sendable (NestedAsync) async throws -> Void = { value in
        await Task.yield(); copiedInputs.asyncValue = try value.copy()
    }
    try unsafe await visitAsyncEscaping.unsafeInvoke(CopyAsyncInput(copyAsyncBody))
    try check(try unsafe await copiedInputs.asyncValue!.unsafeInvoke(35) == 42,
        "Copying a native escaping async input owns its descriptor and context after suspension")
    let apply = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callClosureValue(_:_:)",
        as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
    )
    let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
    try check(try unsafe apply.unsafeInvoke(callback, 35) == 42,
              "Compiled native caller invokes the generated concrete closure")
    try check(try unsafe callback.unsafeInvoke(35) == 42,
              "The retained closure invokes its entry with the hidden context")

    let echo = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.echoClosureValue(_:)",
        as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftClosure<(Int64) -> Int64>).self
    )
    var roundTrip = callback
    for _ in 0..<10_000 { roundTrip = try unsafe echo.unsafeInvoke(roundTrip) }
    try check(try unsafe roundTrip.unsafeInvoke(35) == 42,
              "Repeated native handoffs reuse the owning callback entry")

    let retain = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.holdClosureValue(_:)",
        as: ((NativeSwiftClosure<(Int64) -> Int64>) -> ClosureValueHolder).self
    )
    let destroyed = ClosureProbeCounter()
    weak var observed: ClosureProbeCapture?
    var holder: ClosureValueHolder?
    do {
        let capture = ClosureProbeCapture(destroyed)
        observed = capture
        let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
        holder = try unsafe retain.unsafeInvoke(callback)
    }
    try withExtendedLifetime(holder) {
        try check(observed != nil && destroyed.count == 0,
                  "Native escaping storage retains the capture and generated entry")
    }
    try check(holder!(35) == 42, "Saved native closure calls after its Swift wrapper is released")
    holder = nil
    try check(observed == nil && destroyed.count == 1, "Final native closure release destroys captures once")

    let factory = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeStringClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<(String) -> String>).self
    )
    let prefix = String(repeating: "owned prefix ", count: 100)
    let returned = try unsafe factory.unsafeInvoke(prefix)
    try check(try unsafe returned.unsafeInvoke("result") == prefix + "result",
              "Returned Swift capture context preserves String ownership and authentication")

    let applyRect = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callRectClosureValue(_:_:)",
        as: ((NativeSwiftClosure<(CGRect) -> CGRect>, CGRect) -> CGRect).self
    )
    let translate = try NativeSwiftClosure { (value: CGRect) in value.offsetBy(dx: 3, dy: 4) }
    let rectangle = CGRect(x: 1, y: 2, width: 5, height: 6)
    try check(try unsafe applyRect.unsafeInvoke(translate, rectangle) == rectangle.offsetBy(dx: 3, dy: 4),
              "Imported value identity and floating aggregate registers match the native closure")

    let applyPointer = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callPointerClosureValue(_:_:)",
        as: ((NativeSwiftClosure<(UnsafePointer<Int64>?) -> Int64>, UnsafePointer<Int64>?) -> Int64).self
    )
    let read = try NativeSwiftClosure { (value: UnsafePointer<Int64>?) -> Int64 in value?.pointee ?? -1 }
    var number: Int64 = 42
    let result = try withUnsafePointer(to: &number) { try unsafe applyPointer.unsafeInvoke(read, $0) }
    try check(result == 42, "Typed-pointer substitution matches the native closure discriminator")
    try check(try unsafe applyPointer.unsafeInvoke(read, nil) == -1, "Optional pointer preserves its nil representation")

    let applyVoid = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callVoidClosureValue(_:)",
        as: ((NativeSwiftClosure<() -> Void>) -> Void).self
    )
    let calls = ClosureProbeCounter()
    let empty = try NativeSwiftClosure<() -> Void> { calls.increment() }
    try unsafe applyVoid.unsafeInvoke(empty)
    try check(calls.count == 1, "Zero-argument Void closure matches the native signature")
    let applyArray = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callArrayClosureValue(_:_:)",
        as: ((NativeSwiftClosure<([String]) -> [String]>, [String]) -> [String]).self
    )
    let arrayCallback = try NativeSwiftClosure { (value: [String]) in value + ["callback"] }
    try check(try unsafe applyArray.unsafeInvoke(arrayCallback, ["input"]) == ["input", "callback"],
              "Array callback uses the native nominal discriminator and buffer ownership")
    let makeArray = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeArrayClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<([String]) -> [String]>).self
    )
    let returnedArray = try unsafe makeArray.unsafeInvoke(prefix)
    try check(try unsafe returnedArray.unsafeInvoke([]) == [prefix],
              "Returned Array closure retains its capture and transfers its result")
    let optionalArrays = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callOptionalArrayClosureValue(_:_:)",
        as: ((NativeSwiftClosure<([String]?) -> [String]?>, [String]?) -> [String]?).self
    )
    let optionalArrayCallback = try NativeSwiftClosure { (value: [String]?) in value }
    let absentArray = try unsafe optionalArrays.unsafeInvoke(optionalArrayCallback, nil)
    let emptyArray = try unsafe optionalArrays.unsafeInvoke(optionalArrayCallback, [])
    try check(absentArray == nil && emptyArray == [],
              "Optional Array preserves nil and empty with authenticated callback calls")
    let optionalStrings = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callOptionalStringClosureValue(_:_:)",
        as: ((NativeSwiftClosure<(String?) -> String?>, String?) -> String?).self
    )
    let optionalStringCallback = try NativeSwiftClosure { (value: String?) in value.map { $0 + "!" } }
    let absentString = try unsafe optionalStrings.unsafeInvoke(optionalStringCallback, nil)
    let presentString = try unsafe optionalStrings.unsafeInvoke(optionalStringCallback, prefix)
    try check(absentString == nil && presentString == prefix + "!",
              "Optional String callback preserves its spare-bit payload and ownership")
    let makeOptionalString = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeOptionalStringClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<(String?) -> String?>).self
    )
    let returnedOptional = try unsafe makeOptionalString.unsafeInvoke(prefix)
    let absentResult = try unsafe returnedOptional.unsafeInvoke(nil)
    let presentResult = try unsafe returnedOptional.unsafeInvoke("input")
    try check(absentResult == nil && presentResult == "input" + prefix,
              "Returned Optional String closure matches native pointer authentication")
    let vectorCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitVector(_:_:)",
        as: ((NativeSwiftClosure<(ExplicitVector) -> ExplicitVector>, ExplicitVector) -> ExplicitVector).self
    )
    let vectorBody = try NativeSwiftClosure { (value: ExplicitVector) in
        ExplicitVector(token: value.token, x: value.x + 1, y: value.y + 2)
    }
    let token = ExplicitValueToken(42)
    let vector = try unsafe vectorCall.unsafeInvoke(vectorBody, ExplicitVector(token: token, x: 1, y: 2))
    try check(vector.token === token && vector.x == 2 && vector.y == 4,
              "Explicit managed struct preserves mixed registers, ownership, and authentication")
    let choiceCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitChoice(_:_:)",
        as: ((NativeSwiftClosure<(ExplicitChoice) -> ExplicitChoice>, ExplicitChoice) -> ExplicitChoice).self
    )
    let choiceBody = try NativeSwiftClosure<(ExplicitChoice) -> ExplicitChoice> { $0 }
    let choice = try unsafe choiceCall.unsafeInvoke(choiceBody, .number(-42))
    if case .number(let actual) = choice {
        try check(actual == -42, "Explicit enum preserves its payload and tag in an authenticated callback")
    } else { throw ArchitectureValidationFailure(description: "Explicit enum lost its number tag") }
    let choiceFactory = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeExplicitChoice()",
        as: (() -> NativeSwiftClosure<(ExplicitChoice) -> ExplicitChoice>).self
    )
    let returnedChoice = try unsafe choiceFactory.unsafeInvoke()
    weak var observedValue: ExplicitValueToken?
    var heldChoice: ExplicitChoice?
    do {
        let value = ExplicitValueToken(7)
        observedValue = value
        heldChoice = try unsafe returnedChoice.unsafeInvoke(.token(value))
    }
    try withExtendedLifetime(heldChoice) {
        try check(observedValue != nil, "Returned enum closure transfers its reference payload")
    }
    heldChoice = nil
    try check(observedValue == nil, "Explicit enum destruction releases its reference payload")
    let largeCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitLarge(_:_:)",
        as: ((NativeSwiftClosure<(ExplicitLarge) -> ExplicitLarge>, ExplicitLarge) -> ExplicitLarge).self
    )
    let largeBody = try NativeSwiftClosure<(ExplicitLarge) -> ExplicitLarge> { $0 }
    let large = try unsafe largeCall.unsafeInvoke(largeBody, ExplicitLarge(token: token, a: 1, b: 2, c: 3, d: 4))
    try check(large.token === token && large.a == 1 && large.d == 4,
              "Indirect large managed value uses the compiler's closure discriminator")
    let echoResilient = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.echoResilient(_:)", as: ((ResilientValue) -> ResilientValue).self
    )
    let valueToken = ValueToken()
    let resilient = ResilientValue(token: valueToken, number: 35)
    let echoed = try unsafe echoResilient.unsafeInvoke(resilient)
    try check(echoed.token === valueToken && echoed.number == 35,
              "Small resilient value uses declared indirect arguments and results")
    let applyResilient = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.applyResilient(_:_:)",
        as: ((NativeSwiftClosure<(ResilientValue) -> ResilientValue>, ResilientValue) -> ResilientValue).self
    )
    let resilientBody = try NativeSwiftClosure { (value: ResilientValue) in value.advanced(7) }
    let resilientResult = try unsafe applyResilient.unsafeInvoke(resilientBody, resilient)
    try check(resilientResult.token === valueToken && resilientResult.number == 42,
              "Resilient callback reabstracts indirect storage with native authentication")
    let makeResilient = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.returnResilient(_:)",
        as: ((Int64) -> NativeSwiftClosure<(ResilientValue) -> ResilientValue>).self
    )
    let returnedResilient = try unsafe makeResilient.unsafeInvoke(7)
    let indirectResult = try unsafe returnedResilient.unsafeInvoke(resilient)
    try check(indirectResult.token === valueToken && indirectResult.number == 42,
              "Returned resilient closure preserves ownership and authenticated indirect convention")
    let applyGeneric = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.applyGeneric(_:_:)",
        as: ((NativeSwiftClosure<(GenericValue<Int64>) -> GenericValue<Int64>>, GenericValue<Int64>) -> GenericValue<Int64>).self
    )
    let genericBody = try NativeSwiftClosure { (value: GenericValue<Int64>) in GenericValue(value.value + 7) }
    try check(try unsafe applyGeneric.unsafeInvoke(genericBody, GenericValue(35)).value == 42,
              "Generic closure authentication uses the unspecialized nominal declaration")
    let makeGeneric = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.returnGeneric(_:)",
        as: ((Int64) -> NativeSwiftClosure<(GenericValue<Int64>) -> GenericValue<Int64>>).self
    )
    let returnedGeneric = try unsafe makeGeneric.unsafeInvoke(7)
    try check(try unsafe returnedGeneric.unsafeInvoke(GenericValue(35)).value == 42,
              "Returned generic closure uses the same nominal authentication")
    let applyNested = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.applyNested(_:_:)",
        as: ((NativeSwiftClosure<(Namespace.箱<Int64>) -> Namespace.箱<Int64>>, Namespace.箱<Int64>) -> Namespace.箱<Int64>).self
    )
    let nestedBody = try NativeSwiftClosure { (value: Namespace.箱<Int64>) in Namespace.箱(value.value + 7) }
    try check(try unsafe applyNested.unsafeInvoke(nestedBody, Namespace.箱(35)).value == 42,
              "Nested Unicode generic identity matches compiler-authenticated calls")
    return checks
}
