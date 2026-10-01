import ABIBridge
import ArchitectureFixtures
import Foundation
import Synchronization

public final class MethodExtractionReceiver {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }
    @inline(never) public func adding(_ extra: Int64) -> Int64 { value + extra }
    @inline(never) nonisolated(nonsending)
    public func addingLater(_ extra: Int64) async throws -> Int64 {
        await Task.yield()
        if extra < 0 { throw NSError(domain: "MethodExtraction", code: 42) }
        return value + extra
    }
}

@MainActor private final class MethodExtractionObject: NSObject {
    let value: Int64
    init(_ value: Int64) { self.value = value }
    @objc dynamic func adding(_ extra: Int64) -> Int64 { value + extra }
}

private final class ExtractedCounterOwner {
    let pointer = ABIValidationCreateCounter()!
    deinit { ABIValidationDeleteCounter(pointer) }
    func storage() throws -> NativeValue {
        try unsafe NativeValue(borrowing: pointer,
            as: .opaque(named: "ABIArchitecture::Counter", size: Int(ABIValidationCounterSize()), alignment: Int(ABIValidationCounterAlignment())),
            retaining: self)
    }
}

@MainActor func validateMethodExtraction() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    weak var originalSwift: MethodExtractionReceiver?
    let sync: NativeSwiftMethod<Int64, Int64>
    let async: NativeSwiftAsyncMethod<Int64, Int64>
    do {
        let receiver = MethodExtractionReceiver(1)
        originalSwift = receiver
        sync = try await runtime.object(receiver).method(named: "adding(_:)", as: ((Int64) -> Int64).self).method
        async = try await runtime.object(receiver).method(named: "addingLater(_:)",
            as: (nonisolated(nonsending) (Int64) async throws -> Int64).self).method
    }
    try check(originalSwift == nil, "Extracted synchronous and async Swift methods release their original receiver")
    let receiver = MethodExtractionReceiver(35)
    try check(try unsafe sync.unsafeInvoke(on: receiver, 7) == 42, "Extracted Swift method invokes a different compatible receiver")
    let bound = try sync.bind(to: receiver)
    try check(try unsafe bound.unsafeInvoke(8) == 43, "Swift rebinding reuses the prepared implementation")
    let asyncBound = try async.bind(to: receiver)
    let result = try unsafe await asyncBound.unsafeInvoke(7)
    try check(result == 42, "Extracted async method rebinds and preserves suspension and its result")
    do {
        _ = try unsafe await async.unsafeInvoke(on: receiver, -1)
        throw ArchitectureValidationFailure(description: "Reused async method lost its native error")
    } catch let error as NativeSwiftError {
        var code = 0
        error.withUnderlyingError { code = ($0 as NSError).code }
        try check(code == 42, "Extracted async method preserves native errors")
    }

    weak var originalObject: MethodExtractionObject?
    let message: NativeObjCMethod<Int64, Int64> = try autoreleasepool {
        let object = MethodExtractionObject(1)
        originalObject = object
        return try runtime.object(object).method(selector: "adding:", as: ((Int64) -> Int64).self).method
    }
    try check(originalObject == nil, "Extracted Objective-C message releases the source binding")
    let object = MethodExtractionObject(35)
    let rebound = try message.bind(to: object)
    let captured = try runtime.objcImplementation(on: MethodExtractionObject.self, selector: "adding:", as: ((Int64) -> Int64).self)
    try check(try unsafe rebound.unsafeInvoke(7) == 42, "Extracted Objective-C message binds another receiver")
    let failures = Mutex<[String]>([])
    let hook = try unsafe runtime.hookMethod(on: MethodExtractionObject.self, selector: "adding:",
        as: ((Int64) -> Int64).self, onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in try call.proceed(value) + 100 }
    defer { hook.invalidate() }
    try check(try unsafe message.unsafeInvoke(on: object, 7) == 142, "Extracted Objective-C message observes current dispatch")
    try check(try unsafe captured.unsafeInvoke(on: object, 7) == 42, "Captured Objective-C implementation preserves its selected entry")
    hook.invalidate()
    try check(failures.withLock { $0.isEmpty }, "Reused Objective-C messages complete without callback failures")

    weak var originalCounter: ExtractedCounterOwner?
    let direct: NativeCXXMethod<Int32, Int32>
    let virtual: NativeCXXMethod<Int32>
    do {
        let owner = ExtractedCounterOwner()
        originalCounter = owner
        let storage = try owner.storage()
        let counter = runtime.cxxObject(storage, typeNamed: "ABIArchitecture::Counter")
        direct = try await counter.method(named: "add(int)", as: ((Int32) -> Int32).self).method
        let table = try unsafe NativeVTable(readingFrom: storage, entryCount: 1,
            authentication: .cxxVTablePointer(discriminator: ABIValidationTableDiscriminator()))
        let entry = try await table.entry(named: "ABIArchitecture::Counter::current() const", using: runtime)
        virtual = try unsafe counter.virtualMethod(entry, as: (() -> Int32).self).method
    }
    try check(originalCounter == nil, "Extracted C++ direct and vtable methods release the source receiver")
    let other = ExtractedCounterOwner()
    let storage = try other.storage()
    try check(try unsafe direct.unsafeInvoke(on: storage, 2) == 42, "Extracted C++ implementation uses an explicit new receiver")
    let reboundCounter = direct.bind(to: storage)
    try check(try unsafe reboundCounter.unsafeInvoke(3) == 45, "C++ binding shares the captured implementation")
    try check(try unsafe virtual.unsafeInvoke(on: storage) == 45, "Captured vtable entry remains authenticated after source release")
    if let error = ABIValidateExtractedObjCImplementations() {
        throw ArchitectureValidationFailure(description: String(cString: error))
    }
    checks.append("C and Objective-C++ captured implementations preserve receiver independence, rebinding, dispatch and assignment reentry")
    return checks
}
