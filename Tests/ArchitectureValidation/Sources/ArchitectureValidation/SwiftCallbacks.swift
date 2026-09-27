import ABIBridge
import ABIBridgeCore
import Foundation
import SwiftReplacementCaller
import SwiftReplacementFixtures
import Synchronization

private final class CallbackValidationBox {
    let invoke: (OpaquePointer) throws -> Void
    let destroy: ((UnsafeMutableRawPointer) -> Void)?
    let failures = Mutex<[String]>([])
    init(destroy: ((UnsafeMutableRawPointer) -> Void)? = nil, invoke: @escaping (OpaquePointer) throws -> Void) {
        self.destroy = destroy; self.invoke = invoke
    }
}
private func callbackFailure(_ error: OpaquePointer?) -> ArchitectureValidationFailure {
    guard let error else { return .init(description: "Swift callback failed without a message") }
    defer { ABIReleaseResolutionFailure(error) }
    return .init(description: String(cString: ABIResolutionFailureMessage(error)!))
}
private func requireCallback(_ value: Bool, _ message: String) throws {
    if !value { throw ArchitectureValidationFailure(description: message) }
}
private func readCallbackValue<T>(_ call: OpaquePointer, argument: Int?, as: T.Type) throws -> T {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(1, MemoryLayout<T>.size), alignment: MemoryLayout<T>.alignment)
    defer { pointer.deallocate() }
    var error: OpaquePointer?
    let read = argument.map { ABISwiftIncomingReadArgument(call, $0, pointer, MemoryLayout<T>.size, &error) }
        ?? ABISwiftIncomingCopyResult(call, pointer, MemoryLayout<T>.size, &error)
    guard read else { throw callbackFailure(error) }
    return pointer.load(as: T.self)
}
private func setCallbackValue<T>(_ call: OpaquePointer, _ value: T) throws {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    pointer.initialize(to: value)
    var error: OpaquePointer?
    guard ABISwiftIncomingSetResult(call, pointer, MemoryLayout<T>.size, &error) else {
        pointer.deinitialize(count: 1); throw callbackFailure(error)
    }
}
private func proceedCallbackValue<T>(_ call: OpaquePointer, _ value: T) throws {
    var value = value
    var error: OpaquePointer?
    let result = withUnsafeMutablePointer(to: &value) { pointer in
        let arguments: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(pointer)]
        return arguments.withUnsafeBufferPointer {
            ABISwiftIncomingProceed(call, $0.baseAddress, $0.count, ABISwiftIncomingContext(call), &error)
        }
    }
    if !result { throw callbackFailure(error) }
}
private final class CallbackValidationType {
    let handle: OpaquePointer
    init(_ scalar: Int) throws {
        var error: OpaquePointer?
        guard let handle = ABICreateScalarType(Int32(scalar), &error) else { throw callbackFailure(error) }
        self.handle = handle
    }
    init(_ fields: [CallbackValidationType]) throws {
        let fields: [OpaquePointer?] = fields.map(\.handle)
        var error: OpaquePointer?
        guard let handle = fields.withUnsafeBufferPointer({ ABICreateStructType($0.baseAddress, $0.count, &error) }) else { throw callbackFailure(error) }
        self.handle = handle
    }
    deinit { ABIReleaseValueType(handle) }
}

@MainActor private func withValidationCallback(
    address: UInt, flags: UInt32, result: CallbackValidationType, arguments: [CallbackValidationType],
    box: CallbackValidationBox, _ body: @MainActor (OpaquePointer) throws -> Void
) throws {
    let slot = UnsafeMutableRawPointer(bitPattern: address)!, before = slot.load(as: UInt.self)
    let authenticated = ABIUsesPointerAuthentication()
    let key = Int32(authenticated ? ABIAuthenticationInstructionA : ABIAuthenticationUnsigned), discriminator = UInt(flags >> 16)
    var error: OpaquePointer?
    guard let target = ABICopyVirtualCallTarget(slot, key, discriminator, authenticated, &error) else { throw callbackFailure(error) }
    var targetTransferred = false
    defer { if !targetTransferred { ABIReleaseVirtualCallTarget(target) } }
    let arguments: [OpaquePointer?] = arguments.map(\.handle)
    guard let interface = arguments.withUnsafeBufferPointer({ ABICreateSwiftCallInterface(result.handle, $0.baseAddress, $0.count, &error) }) else { throw callbackFailure(error) }
    defer { ABIReleaseSwiftCallInterface(interface) }
    var functions = ABISwiftCallbackFunctions()
    functions.invoke = { context, call in
        let box = Unmanaged<CallbackValidationBox>.fromOpaque(context!).takeUnretainedValue()
        do { try box.invoke(call!) } catch { box.failures.withLock { $0.append(String(describing: error)) } }
    }
    functions.releaseContext = { Unmanaged<CallbackValidationBox>.fromOpaque($0!).release() }
    functions.destroyResult = { context, result in Unmanaged<CallbackValidationBox>.fromOpaque(context!).takeUnretainedValue().destroy?(result!) }
    let context = Unmanaged.passRetained(box)
    guard let callback = ABICreateSwiftCallback(interface, ABIVirtualCallTargetFunction(target), functions, context.toOpaque(),
        UnsafeMutableRawPointer(target), { ABIReleaseVirtualCallTarget(OpaquePointer($0!)) }, &error) else {
        context.release(); throw callbackFailure(error)
    }
    targetTransferred = true
    var canRelease = true
    defer { if canRelease { ABIReleaseSwiftCallback(callback) } }
    var after: UInt = 0
    try requireCallback(ABIEncodePointerSlotFunction(ABISwiftCallbackFunction(callback), slot, key, discriminator, authenticated, &after), "Sign callback for virtual slot")
    let mutation = ABICompareExchangePointerSlot(slot, before, after)
    let outcome = Result {
        try requireCallback(mutation.status == ABIPointerSlotComplete && mutation.didWrite, "Callback publication: \(mutation.status)")
        try body(callback)
        try requireCallback(box.failures.withLock { $0.isEmpty }, "Callback failures: \(box.failures.withLock { $0 })")
    }
    if mutation.didWrite {
        let restored = ABICompareExchangePointerSlot(slot, after, before)
        if restored.status != ABIPointerSlotComplete {
            canRelease = false; ABIClearSwiftCallback(callback)
            throw ArchitectureValidationFailure(description: "Callback restoration: \(restored.status); body: \(outcome)")
        }
    }
    try outcome.get()
}

@MainActor func validateSwiftCallbacks() async throws -> [String] {
    let runtime = ABIRuntime(), receiver = ReplacementRenderer()
    let type = try await runtime.swiftType(named: "SwiftReplacementFixtures.ReplacementRenderer")
    let integer = try CallbackValidationType(ABIValueInt64)
    var checks: [String] = []
    func flags(_ declaration: NativeDeclaration) async throws -> UInt32 {
        let descriptor = try await runtime.resolve(.init(name: "method descriptor for " + declaration.name, language: .swift, kind: .data))
        return unsafe descriptor.withUnsafeAddress { $0.load(as: UInt32.self) }
    }
    let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
    let plan = try unsafe method.prepareVirtualReplacement(with: method)
    let scalarBox = CallbackValidationBox { call in
        let value = try readCallbackValue(call, argument: 0, as: Int64.self)
        try proceedCallbackValue(call, value + 1)
        let result = try readCallbackValue(call, argument: nil, as: Int64.self)
        try setCallbackValue(call, result + 10)
    }
    try withValidationCallback(address: plan.address, flags: await flags(method.symbol.declaration), result: integer, arguments: [integer], box: scalarBox) { callback in
        try requireCallback(classScalar(receiver, 40) == 53, "Compiled caller uses edited callback arguments and result")
        ABIClearSwiftCallback(callback)
        try requireCallback(classScalar(receiver, 40) == 42, "Invalidated Swift callback passes through")
    }
    checks.append("Compiled class dispatch, typed continuation, edited scalar result and invalidation passed")
    let word = try CallbackValidationType(MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32)
    let string = try CallbackValidationType(Array(repeating: word, count: MemoryLayout<String>.size / MemoryLayout<UInt>.size))
    let text = try await type.method(named: "text(_:)", as: ((String) -> String).self)
    let textPlan = try unsafe text.prepareVirtualReplacement(with: text)
    let stringBox = CallbackValidationBox(destroy: { $0.assumingMemoryBound(to: String.self).deinitialize(count: 1) }) { call in
        let value = try readCallbackValue(call, argument: 0, as: String.self)
        try proceedCallbackValue(call, value + "-first")
        try proceedCallbackValue(call, value + "-second")
        let result = try readCallbackValue(call, argument: nil, as: String.self)
        try setCallbackValue(call, "callback:" + result)
    }
    let input = String(repeating: "owned Swift data", count: 100)
    try withValidationCallback(address: textPlan.address, flags: await flags(text.symbol.declaration), result: string, arguments: [string], box: stringBox) { _ in
        for _ in 0..<20 { try requireCallback(classText(receiver, input) == "callback:method:" + input + "-second", "Owned String callback result") }
    }
    checks.append("Heap-backed String arguments, repeated continuation, result destruction and transfer passed")
    try requireCallback(classText(receiver, input) == "method:" + input, "String method restored")
    checks.append("Native Swift callback slots restored after releasing scoped code owners")
    let payloadType = try CallbackValidationType(Array(repeating: integer, count: 5))
    let payload = try await type.method(named: "payload(Swift.Int64) -> SwiftReplacementFixtures.ReplacementPayload",
        as: ((Int64) -> VirtualPayload).self)
    let payloadPlan = try unsafe payload.prepareVirtualReplacement(with: payload)
    let payloadBox = CallbackValidationBox { call in
        let value = try readCallbackValue(call, argument: 0, as: Int64.self)
        try proceedCallbackValue(call, value + 1)
        var result = try readCallbackValue(call, argument: nil, as: VirtualPayload.self)
        result.a += 1000
        try setCallbackValue(call, result)
    }
    try withValidationCallback(address: payloadPlan.address, flags: await flags(payload.symbol.declaration),
        result: payloadType, arguments: [integer], box: payloadBox) { _ in
        try requireCallback(classPayload(receiver, 40) == 1225, "Callback writes the compiler-provided indirect result")
    }
    checks.append("Compiler-provided indirect result storage preserves edited payloads")
    return checks
}
