import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Darwin
import Foundation
import Synchronization

/// Runs against the three separately built frameworks embedded by ArchitectureTestHost.
@MainActor public func runSwiftFunctionHookValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    func path(_ name: String) -> ImageSelector {
        .path(root.appendingPathComponent("\(name).framework/\(name)"))
    }
    let provider = path("SwiftImportProvider")
    let control = path("SwiftImportCallerControl")
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let failures = Mutex<[String]>([])
    let failure: @Sendable (any Error) -> Void = { error in
        failures.withLock { $0.append(String(describing: error)) }
    }
    let target = try await runtime.swiftFunction(named: "SwiftImportProvider.scalar(_:)",
        as: ((Int64) -> Int64).self, in: provider)
    let normal = try await runtime.swiftFunction(named: "SwiftImportCaller.importedScalar(_:)",
        as: ((Int64) -> Int64).self, in: path("SwiftImportCaller"))
    do {
        let hook = try await unsafe target.hookImportedCalls(in: path("SwiftImportCaller"), using: runtime,
            onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
        try check(try unsafe normal.unsafeInvoke(40) == 52, "Normal import accepts a typed Swift closure")
        hook.invalidate()
        try check(try unsafe normal.unsafeInvoke(40) == 41, "Normal import passes through after invalidation")
    } catch let error as NativeSwiftHookInstallationError {
        guard !error.registration.slots.isEmpty,
              error.registration.slots.allSatisfy({ slot in
                  guard let mutation = slot.mutation else { return false }
                  return !mutation.didWrite && mutation.status == ABIPointerSlotProtectFailed
                      && mutation.systemErrorCode == KERN_PROTECTION_FAILURE
                      && mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0
              }) else { throw error }
        try check(try unsafe normal.unsafeInvoke(40) == 41, "Normal import reports TPRO refusal without mutation")
    }

    let scalar = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedScalar(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let first = try await unsafe target.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        try call.proceed(value + 1) + 10
    }
    defer { first.invalidate() }
    let second = try await unsafe target.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        try call.proceed(value * 2) + 100
    }
    defer { second.invalidate() }
    try check(try unsafe scalar.unsafeInvoke(40) == 192, "Typed Swift imported closures share an ordered chain")
    first.invalidate()
    try check(try unsafe scalar.unsafeInvoke(40) == 181, "Independent invalidation preserves the other callback")
    second.invalidate()
    try check(try unsafe scalar.unsafeInvoke(40) == 41, "Empty generated Swift entries call their retained predecessor")

    let opaqueScalar = try await runtime.swiftFunction(named: "SwiftImportProvider.opaqueScalar(Swift.Int64) -> some",
        as: ((Int64) -> Int64).self, declaredAs: "(Swift.Int64) -> some", in: provider)
    let opaqueScalarCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedOpaqueScalar(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let opaqueScalarHook = try await unsafe opaqueScalar.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
    defer { opaqueScalarHook.invalidate() }
    try check(try unsafe opaqueScalarCaller.unsafeInvoke(40) == 52,
        "Opaque scalar hooks preserve the declared indirect return convention")
    opaqueScalarHook.invalidate()
    try check(try unsafe opaqueScalarCaller.unsafeInvoke(40) == 41,
        "Opaque scalar fallback preserves the original indirect result")
    let opaqueText = try await runtime.swiftFunction(named: "SwiftImportProvider.opaqueText(Swift.String) -> some",
        as: ((String) -> String).self, declaredAs: "(Swift.String) -> some", in: provider)
    let opaqueTextCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedOpaqueText(_:)",
        as: ((String) -> String).self, in: control)
    let opaqueTextHook = try await unsafe opaqueText.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            _ = try call.proceed(value + " discarded")
            return try call.proceed(value + " edited") + " returned"
        }
    defer { opaqueTextHook.invalidate() }
    let opaqueInput = String(repeating: "owned opaque value ", count: 100)
    for _ in 0..<10 {
        guard try unsafe opaqueTextCaller.unsafeInvoke(opaqueInput) == opaqueInput + " edited original returned" else {
            throw ArchitectureValidationFailure(description: "Opaque String hook lost its owned result")
        }
    }
    checks.append("Repeated opaque continuations retain independent managed results")
    opaqueTextHook.invalidate()
    try check(try unsafe opaqueTextCaller.unsafeInvoke(opaqueInput) == opaqueInput + " original",
        "Opaque managed-result fallback survives invalidation")

    let text = try await runtime.swiftFunction(named: "SwiftImportProvider.text(_:)",
        as: ((String) -> String).self, in: provider)
    let textCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedText(_:)",
        as: ((String) -> String).self, in: control)
    let textHook = try await unsafe text.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        _ = try call.proceed(value + " discarded")
        return try call.proceed(value + " edited") + " returned"
    }
    defer { textHook.invalidate() }
    let input = String(repeating: "owned Swift argument", count: 100)
    for _ in 0..<20 {
        guard try unsafe textCaller.unsafeInvoke(input) == "original:" + input + " edited returned" else {
            throw ArchitectureValidationFailure(description: "Owned String callback result")
        }
    }
    checks.append("Heap String arguments and repeated continuation transfer independent owned results")
    textHook.invalidate()
    try check(try unsafe textCaller.unsafeInvoke(input) == "original:" + input, "String fallback survives logical invalidation")

    let payload = try await runtime.swiftFunction(named: "SwiftImportProvider.payload(Swift.Int64) -> SwiftImportProvider.ReplacementPayload",
        as: ((Int64) -> VirtualPayload).self, in: provider)
    let payloadCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedPayload(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let payloadHook = try await unsafe payload.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        var result = try call.proceed(value + 1)
        result.a += 100
        return result
    }
    defer { payloadHook.invalidate() }
    try check(try unsafe payloadCaller.unsafeInvoke(40) == 315, "Imported Swift closure preserves caller-provided indirect result storage")
    payloadHook.invalidate()
    try check(try unsafe payloadCaller.unsafeInvoke(40) == 210, "Indirect-result fallback survives logical invalidation")

    let genericInteger = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((Int64) -> Int64).self, genericArguments: [.type(Int64.self)], in: provider)
    let genericText = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((String) -> String).self, genericArguments: [.type(String.self)], in: provider)
    let genericObject = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)], in: provider)
    let integerCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookInteger(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let stringCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookString(_:)",
        as: ((String) -> String).self, in: control)
    let objectCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookObject(_:)",
        as: ((NSObject) -> NSObject).self, in: control)
    let booleanCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookBoolean(_:)",
        as: ((Bool) -> Bool).self, in: control)
    _ = try unsafe integerCaller.unsafeInvoke(40)
    let integerHook = try unsafe await genericInteger.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
    defer { integerHook.invalidate() }
    let stringHook = try unsafe await genericText.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + " hook") }
    defer { stringHook.invalidate() }
    let objectCalls = Mutex(0)
    let objectHook = try unsafe await genericObject.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            objectCalls.withLock { $0 += 1 }
            return try call.proceed(value)
        }
    defer { objectHook.invalidate() }
    try check(try unsafe integerCaller.unsafeInvoke(40) == 51, "Generic scalar hooks select their bound native metadata")
    try check(try unsafe stringCaller.unsafeInvoke(input) == input + " hook", "A second generic binding preserves owned String values")
    let object = NSObject()
    try check(try unsafe objectCaller.unsafeInvoke(object) === object && objectCalls.withLock { $0 } == 1,
        "An unconstrained class substitution retains indirect argument passing")
    try check(try unsafe booleanCaller.unsafeInvoke(false) == false, "Unmatched generic metadata forwards the untouched native frame")
    integerHook.invalidate(); stringHook.invalidate(); objectHook.invalidate()

    let genericFactory = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookFactory(_:)",
        as: ((Int64) -> NativeSwiftClosure<() -> Int64>).self, genericArguments: [.type(Int64.self)], in: provider)
    let factoryCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookFactoryResult(_:)",
        as: ((Int64) -> Int64).self, in: control)
    _ = try unsafe factoryCaller.unsafeInvoke(40)
    let factoryHook = try unsafe await genericFactory.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) }
    defer { factoryHook.invalidate() }
    try check(try unsafe factoryCaller.unsafeInvoke(40) == 41, "Returned generic closures preserve their declared ABI and pointer authentication")
    factoryHook.invalidate()

    let throwing = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookError(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: provider)
    let throwingCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookErrorResult(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: control)
    _ = try unsafe throwingCaller.unsafeInvoke(40)
    let throwingHook = try unsafe await throwing.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            if value == 99 { throw NSError(domain: "callback-hook", code: 99) }
            return try call.proceed(value) + 10
        }
    defer { throwingHook.invalidate() }
    try check(try unsafe throwingCaller.unsafeInvoke(40) == 51, "Typed-error hooks preserve ordinary successful results")
    for (value, domain) in [(Int64(-7), "native-hook"), (Int64(99), "callback-hook")] {
        do {
            _ = try unsafe throwingCaller.unsafeInvoke(value)
            throw ArchitectureValidationFailure(description: "Expected the declared native error channel")
        } catch let error as NativeSwiftError {
            try error.withUnderlyingError {
                try check(($0 as NSError).domain == domain && ($0 as NSError).code == Int(value),
                    "Typed error channel preserves " + domain + " ownership")
            }
        }
    }
    throwingHook.invalidate()
    checks += try await validateRuntimeHookOwnership(runtime: runtime, provider: provider, caller: control)
    checks += try await validateAsyncFunctionHooks(runtime: runtime, provider: provider, caller: control)
    try check(failures.withLock { $0.isEmpty }, "No unexpected Swift callback failures")
    return ArchitectureReport(mode: "swift-function-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(),
        checks: checks, allocationTag: nil)
}

private final class RuntimeHookOwnershipState: @unchecked Sendable {
    var input: NativeSwiftValue?
    var output: NativeSwiftValue?
}
private struct RuntimeHookProbeError: Error {}

@MainActor private func validateRuntimeHookOwnership(runtime: ABIRuntime, provider: ImageSelector,
    caller: ImageSelector) async throws -> [String] {
    let type = try await runtime.swiftType(named: "SwiftImportProvider.HookTicket", in: provider)
    let consume = try await runtime.swiftFunction(named: "SwiftImportProvider.consumeHookTicket(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self, genericArguments: [.type(type)], in: provider)
    let move = try await runtime.swiftFunction(named: "SwiftImportProvider.moveHookTicket(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: [.type(type)], in: provider)
    let consumeCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callConsumeTicket(_:)",
        as: ((Int64) -> Int64).self, in: caller)
    let moveCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callMoveTicket(_:)",
        as: ((Int64) -> Int64).self, in: caller)
    let counts = try await runtime.swiftFunction(named: "SwiftImportProvider.hookTicketCounts()",
        as: (() -> (Int64, Int64)).self, in: provider)
    let state = RuntimeHookOwnershipState()
    let failures = Mutex(0)
    var checks: [String] = []
    let first = try unsafe await consume.hookImportedCalls(in: caller, using: runtime, onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
        state.input = value.value
        do {
            _ = try unsafe consume.unsafeInvoke(value)
            throw ArchitectureValidationFailure(description: "An independent transfer bypassed recovery ownership")
        } catch NativeSwiftValueError.valueInUse {}
        return try call.proceed(value) + 10
    }
    guard try unsafe consumeCaller.unsafeInvoke(42) == 52, state.input!.isConsumed,
          try unsafe counts.unsafeInvoke() == (1, 1) else {
        throw ArchitectureValidationFailure(description: "Noncopyable input forwarding or destruction failed")
    }
    checks.append("Runtime hook inputs reserve recovery ownership and proceed consumes every saved alias")
    first.invalidate()
    let second = try unsafe await move.hookImportedCalls(in: caller, using: runtime, onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
        state.output = try call.proceed(value)
        do {
            _ = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(state.output!))
            throw ArchitectureValidationFailure(description: "A completed result lost its recovery reservation")
        } catch NativeSwiftValueError.valueInUse {}
        return state.output!
    }
    guard try unsafe moveCaller.unsafeInvoke(43) == 43, state.output!.isConsumed,
          try unsafe counts.unsafeInvoke() == (2, 2) else {
        throw ArchitectureValidationFailure(description: "Noncopyable result publication did not transfer its canonical owner")
    }
    checks.append("Noncopyable hook results share native publication ownership without an extra copy")
    second.invalidate()
    let third = try unsafe await move.hookImportedCalls(in: caller, using: runtime, onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
        state.output = try call.proceed(value)
        throw RuntimeHookProbeError()
    }
    guard try unsafe moveCaller.unsafeInvoke(44) == 44, state.output!.isConsumed,
          try unsafe counts.unsafeInvoke() == (3, 3), failures.withLock({ $0 }) == 1 else {
        throw ArchitectureValidationFailure(description: "Hook failure replayed native effects or lost noncopyable ownership")
    }
    checks.append("A body failure preserves the latest noncopyable native result and executes its effects once")
    third.invalidate()
    let fourth = try unsafe await consume.hookImportedCalls(in: caller, using: runtime, onFailure: { _ in failures.withLock { $0 += 1 } }) { _, value in
        state.input = value.value
        throw RuntimeHookProbeError()
    }
    guard try unsafe consumeCaller.unsafeInvoke(45) == 45, state.input!.isConsumed,
          try unsafe counts.unsafeInvoke() == (4, 4), failures.withLock({ $0 }) == 2 else {
        throw ArchitectureValidationFailure(description: "Failure before continuation lost its incoming owned value")
    }
    checks.append("Failure before continuation forwards the original noncopyable input exactly once")
    fourth.invalidate()
    let renderer = try await runtime.swiftType(named: "SwiftImportProvider.HookTicketRenderer", in: provider)
    let virtualMove = try await renderer.method(named: "move(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: [.type(type)])
    let virtualCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callVirtualMoveTicket(_:)",
        as: ((Int64) -> Int64).self, in: caller)
    let virtual = try unsafe await virtualMove.hookVirtualCalls(onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
        _ = try call.receiver(as: AnyObject.self)
        state.output = try call.proceed(value)
        return state.output!
    }
    defer { virtual.invalidate() }
    guard try unsafe virtualCaller.unsafeInvoke(46) == 46, state.output!.isConsumed,
          try unsafe counts.unsafeInvoke() == (5, 5), failures.withLock({ $0 }) == 2 else {
        throw ArchitectureValidationFailure(description: "Virtual runtime ownership did not match imported hooks")
    }
    checks.append("Virtual generic methods use the same noncopyable ownership plan and authenticated continuation")
    virtual.invalidate()
    let asyncMove = try await runtime.swiftFunction(named: "SwiftImportProvider.moveAsyncHookTicket(_:)",
        as: (@concurrent (NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self,
        genericArguments: [.type(type)], in: provider)
    let asyncCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callAsyncMoveTicket(_:)",
        as: (@concurrent (Int64) async -> Int64).self, in: caller)
    let asyncHook = try unsafe await asyncMove.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
            state.input = value.value
            await Task.yield()
            state.output = try await call.proceed(value)
            await Task.yield()
            throw RuntimeHookProbeError()
        }
    defer { asyncHook.invalidate() }
    guard try unsafe await asyncCaller.unsafeInvoke(47) == 47, state.input!.isConsumed, state.output!.isConsumed,
          try unsafe counts.unsafeInvoke() == (6, 6), failures.withLock({ $0 }) == 3 else {
        throw ArchitectureValidationFailure(description: "Async runtime recovery lost ownership across suspension")
    }
    checks.append("Async runtime hooks transfer noncopyable inputs and recover completed results through suspension")
    asyncHook.invalidate()
    let objectTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.consumeHookObject(_:)",
        as: ((NativeSwiftConsuming<NSObject>) -> Int64).self, in: provider)
    let objectCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callConsumeHookObject(_:)",
        as: ((NativeSwiftConsuming<NSObject>) -> Int64).self, in: caller)
    let objectHook = try unsafe await objectTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in try call.proceed(value) }
    defer { objectHook.invalidate() }
    weak var observedObject: NSObject?
    do {
        let object = NSObject()
        observedObject = object
        guard try unsafe objectCaller.unsafeInvoke(NativeSwiftConsuming(object)) == 42 else {
            throw ArchitectureValidationFailure(description: "A consuming object continuation changed its result")
        }
    }
    guard observedObject == nil else { throw ArchitectureValidationFailure(description: "A consuming continuation leaked its original argument copy") }
    checks.append("Ordinary consuming object arguments release every callback and continuation copy")
    objectHook.invalidate()
    let optionalTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.hookOptionalPointer(Swift.UnsafeMutableRawPointer?) -> Swift.UnsafeMutableRawPointer?",
        as: ((HookPointerValue?) -> HookPointerValue?).self, in: provider)
    let optionalCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callOptionalHookPointer(_:)",
        as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self, in: caller)
    let optionalHook = try unsafe await optionalTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in try call.proceed(value) }
    defer { optionalHook.invalidate() }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    defer { pointer.deallocate() }
    guard try unsafe optionalCaller.unsafeInvoke(nil) == nil,
          try unsafe optionalCaller.unsafeInvoke(pointer) == pointer, failures.withLock({ $0 }) == 3 else {
        throw ArchitectureValidationFailure(description: "An Optional pointer adapter failed to preserve its native representation")
    }
    checks.append("Optional pointer adapters decode and encode nil and nonnil native values through hooks")
    optionalHook.invalidate()
    let borrowingTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.hookBorrowedPointer(Swift.UnsafeMutableRawPointer?) -> Swift.UnsafeMutableRawPointer?",
        as: ((NativeSwiftBorrowing<HookPointerValue?>) -> HookPointerValue?).self, in: provider)
    let borrowingCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callBorrowedHookPointer(_:)",
        as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self, in: caller)
    let borrowingHook = try unsafe await borrowingTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in try call.proceed(value) }
    defer { borrowingHook.invalidate() }
    guard try unsafe borrowingCaller.unsafeInvoke(pointer) == pointer else {
        throw ArchitectureValidationFailure(description: "A borrowed adapter did not use native pointer conversion")
    }
    checks.append("Borrowing wrappers use the shared Optional adapter decoder")
    borrowingHook.invalidate()
    typealias Body = NativeSwiftClosure<() -> Int64>
    let writebackTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.moveHookTicketWithBody(_:_:_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>, NativeSwiftInout<Body>, Body) -> NativeSwiftValue).self,
        genericArguments: [.type(type)], in: provider)
    let writebackCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callMoveTicketWithBody(_:)",
        as: ((Int64) -> (Int64, Int64)).self, in: caller)
    let writebackHook = try unsafe await writebackTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, body, borrowed in
            state.output = try call.proceed(value, body, borrowed)
            body.value = borrowed
            return state.output!
        }
    guard try unsafe writebackCaller.unsafeInvoke(48) == (48, 42), state.output!.isConsumed else {
        throw ArchitectureValidationFailure(description: "A failed inout conversion consumed its noncopyable recovery result")
    }
    checks.append("Inout conversion failure preserves native noncopyable result ownership until recovery publication")
    writebackHook.invalidate()
    let asyncWritebackTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.moveAsyncHookTicketWithBody(_:_:_:)",
        as: (@concurrent (NativeSwiftConsuming<NativeSwiftValue>, NativeSwiftInout<Body>, Body) async -> NativeSwiftValue).self,
        genericArguments: [.type(type)], in: provider)
    let asyncWritebackCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callAsyncMoveTicketWithBody(_:)",
        as: (@concurrent (Int64) async -> (Int64, Int64)).self, in: caller)
    let asyncWritebackHook = try unsafe await asyncWritebackTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, body, borrowed in
            state.output = try await call.proceed(value, body, borrowed)
            body.value = borrowed
            return state.output!
        }
    defer { asyncWritebackHook.invalidate() }
    guard try unsafe await asyncWritebackCaller.unsafeInvoke(49) == (49, 42), state.output!.isConsumed,
          try unsafe counts.unsafeInvoke() == (8, 8), failures.withLock({ $0 }) == 5 else {
        throw ArchitectureValidationFailure(description: "Async inout failure did not preserve the completed result or exact cleanup")
    }
    checks.append("Async result ownership transfers only after inout writeback succeeds")
    let closureTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.consumeHookClosure(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self, in: provider)
    let closureCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callConsumeHookClosure(_:)",
        as: ((NSObject) -> Int64).self, in: caller)
    let closureHook = try unsafe await closureTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
            state.input = value.value
            return try call.proceed(value)
        }
    defer { closureHook.invalidate() }
    do {
        let object = NSObject()
        observedObject = object
        guard try unsafe closureCaller.unsafeInvoke(object) == 42, state.input!.isConsumed else {
            throw ArchitectureValidationFailure(description: "A converted runtime closure did not complete its consuming transfer")
        }
    }
    guard observedObject == nil else { throw ArchitectureValidationFailure(description: "A consumed runtime closure retained its capture") }
    checks.append("Runtime closure conversion consumes saved aliases and releases authenticated captures")
    closureHook.invalidate()
    let asyncClosureTarget = try await runtime.swiftFunction(named: "SwiftImportProvider.consumeAsyncHookClosure(_:)",
        as: (@concurrent (NativeSwiftConsuming<NativeSwiftValue>) async -> Int64).self, in: provider)
    let asyncClosureCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.callConsumeAsyncHookClosure(_:)",
        as: (@concurrent (NSObject) async -> Int64).self, in: caller)
    let asyncClosureHook = try unsafe await asyncClosureTarget.hookImportedCalls(in: caller, using: runtime,
        onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
            state.input = value.value
            return try await call.proceed(value)
        }
    defer { asyncClosureHook.invalidate() }
    do {
        let object = NSObject()
        observedObject = object
        guard try unsafe await asyncClosureCaller.unsafeInvoke(object) == 42, state.input!.isConsumed else {
            throw ArchitectureValidationFailure(description: "An async converted runtime closure did not complete its consuming transfer")
        }
    }
    guard observedObject == nil, failures.withLock({ $0 }) == 5 else {
        throw ArchitectureValidationFailure(description: "Async runtime closure transfer leaked its capture or reported a failure")
    }
    checks.append("Async runtime closure conversion preserves authenticated dispatch and releases transferred ownership")
    return checks
}

private struct HookPointerValue: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let native: NativeValue
    let marker: Int64
    init(nativeValue: NativeValue) { native = nativeValue; marker = 42 }
    static func nativeValue(from value: Self) -> NativeValue { value.native }
}
