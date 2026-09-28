import ABIBridgeCore

private final class SwiftAsyncClosureStorage {
    let value: ABISwiftClosureValue
    let entry: SwiftAsyncEntry
    let codeOwner: Any

    init(adopting value: ABISwiftClosureValue, discriminator: UInt16, retaining owner: Any?) throws {
        do {
            guard let descriptor = ABIAuthenticateSwiftAsyncClosureDescriptor(value.function, discriminator) else {
                throw ABIInvocationError.unexpectedNilResult(expected: "an async Swift closure")
            }
            entry = try SwiftAsyncEntry(descriptor: descriptor)
        } catch {
            withExtendedLifetime(owner) { ABIReleaseSwiftClosureContext(value.context) }
            throw error
        }
        self.value = value
        let callbackOwner = ABICopySwiftAsyncClosureCallbackCodeOwner(entry.function).map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        codeOwner = (owner, entry, callbackOwner)
    }

    deinit { withExtendedLifetime(codeOwner) { ABIReleaseSwiftClosureContext(value.context) } }
    func encoded() -> NativeValueStorage { SwiftClosureStorage.copy(value, retaining: self) }
}

// Each invocation owns distinct buffers. The public body's Sendable contract
// permits concurrent native callers; no task or executor is created here.
private final class SwiftAsyncClosureBody: @unchecked Sendable {
    let codeOwner: SwiftClosureCodeOwner?
    let inheritsCallerIsolation: Bool
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) async -> Bool
    init(inheritsCallerIsolation: Bool, retainingCode codeOwner: Any? = nil,
         _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) async -> Bool) {
        self.codeOwner = codeOwner.map(SwiftClosureCodeOwner.init)
        self.inheritsCallerIsolation = inheritsCallerIsolation
        self.invoke = invoke
    }
}

private final class SwiftAsyncClosureInvocation: @unchecked Sendable {
    let body: SwiftAsyncClosureBody
    let arguments: UnsafePointer<UnsafeMutableRawPointer?>?
    let result: UnsafeMutableRawPointer
    let error: UnsafeMutableRawPointer?
    let didThrow: UnsafeMutablePointer<Bool>
    init(_ body: SwiftAsyncClosureBody, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>?,
         _ result: UnsafeMutableRawPointer, _ error: UnsafeMutableRawPointer?, _ didThrow: UnsafeMutablePointer<Bool>) {
        self.body = body; self.arguments = arguments; self.result = result; self.error = error; self.didThrow = didThrow
    }
    nonisolated(nonsending) func run() async {
        didThrow.pointee = await body.invoke(arguments, result, error)
    }
}

private func retainedValue<Body>(_ operation: Body) -> ABISwiftClosureValue {
    withUnsafeBytes(of: operation) { bytes in
        let value = bytes.load(as: ABISwiftClosureValue.self)
        ABIRetainSwiftClosureContext(value.context)
        return value
    }
}

private final class SwiftAsyncClosureCallbackOwner {
    let handle: OpaquePointer
    init(interface: SwiftAsyncCallInterface, body: SwiftAsyncClosureBody) throws {
        var functions = ABISwiftAsyncClosureCallbackFunctions()
        functions.createBody = { context, arguments, result, error, didThrow in
            let body = Unmanaged<SwiftAsyncClosureBody>.fromOpaque(context!).takeUnretainedValue()
            let invocation = SwiftAsyncClosureInvocation(body, arguments, result!, error, didThrow!)
            if body.inheritsCallerIsolation {
                let operation: (nonisolated(nonsending) @Sendable () async -> Void) = { await invocation.run() }
                return retainedValue(operation)
            }
            let operation: @Sendable @concurrent () async -> Void = { await invocation.run() }
            return retainedValue(operation)
        }
        functions.releaseContext = { Unmanaged<SwiftAsyncClosureBody>.fromOpaque($0!).release() }
        functions.copyCodeOwner = { context in
            let owner = Unmanaged<SwiftAsyncClosureBody>.fromOpaque(context!).takeUnretainedValue().codeOwner
            return owner.map { Unmanaged.passRetained($0).toOpaque() }
        }
        let context = Unmanaged.passRetained(body)
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftAsyncClosureCallback(interface.handle, functions, context.toOpaque(), &failure) else {
            context.release()
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftAsyncClosureCallback(handle) }
}

private struct SwiftAsyncClosureCore<Result, Failure: Error, each Argument> {
    let storage: SwiftAsyncClosureStorage
    let call: SwiftAsyncCall<Result, repeat each Argument>

    init(_ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result,
         inheritsCallerIsolation: Bool) throws {
        let prepared = try Self.prepare(inheritsCallerIsolation: inheritsCallerIsolation)
        let callback = try SwiftAsyncClosureCallbackOwner(interface: prepared.call.interface, body: SwiftAsyncClosureBody(inheritsCallerIsolation: inheritsCallerIsolation) { arguments, result, errorOutput in
            var index = 0
            func decode<Value>(_ type: Value.Type) -> Value {
                defer { index += 1 }
                return arguments![index]!.load(as: type)
            }
            let values = (repeat decode((each Argument).self))
            do throws(Failure) {
                let value = try await body(repeat each values)
                result.initializeMemory(as: Result.self, repeating: value, count: 1)
                return false
            } catch {
                errorOutput!.initializeMemory(as: Failure.self, repeating: error, count: 1)
                return true
            }
        })
        storage = try Self.storage(callback, discriminator: prepared.discriminator)
        call = prepared.call
    }

    private init(storage: SwiftAsyncClosureStorage, call: SwiftAsyncCall<Result, repeat each Argument>) {
        self.storage = storage; self.call = call
    }

    private static func prepare(inheritsCallerIsolation: Bool) throws -> (call: SwiftAsyncCall<Result, repeat each Argument>, discriminator: UInt16) {
        // SIL hashes the implicit actor as a class parameter; IRGen expands it
        // into the two-word opaque isolation prefix used by the call interface.
        var parameters = inheritsCallerIsolation ? ["-class"] : []
        for type in repeat (each Argument).self {
            if type != Void.self { parameters.append(try swiftClosureAuthType(type)) }
        }
        let result = Result.self == Void.self ? nil : try swiftClosureAuthType(Result.self)
        return (try SwiftAsyncCall(errorPlan: SwiftErrorPlan.make(Failure.self), inheritsCallerIsolation: inheritsCallerIsolation),
                swiftClosureDiscriminator(parameters: parameters, result: result))
    }

    private static func storage(_ callback: SwiftAsyncClosureCallbackOwner, discriminator: UInt16) throws -> SwiftAsyncClosureStorage {
        try SwiftAsyncClosureStorage(adopting: ABISwiftClosureValue(
            function: ABISignSwiftAsyncClosureDescriptor(ABISwiftAsyncClosureCallbackDescriptor(callback.handle), discriminator),
            context: Unmanaged.passRetained(callback).toOpaque()), discriminator: discriminator, retaining: nil)
    }

    static func codec<Value>(inheritsCallerIsolation: Bool, wrap: @escaping @Sendable (Self) -> Value) throws -> SwiftClosureCodec {
        let prepared = try prepare(inheritsCallerIsolation: inheritsCallerIsolation)
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer])) { value, owner, taking in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftAsyncClosureStorage(adopting: value, discriminator: prepared.discriminator, retaining: owner)
            if ABIIsSwiftAsyncClosureCallbackFunction(original.entry.function) {
                return wrap(Self(storage: original, call: prepared.call))
            }
            let callback = try SwiftAsyncClosureCallbackOwner(interface: prepared.call.interface,
                body: SwiftAsyncClosureBody(inheritsCallerIsolation: inheritsCallerIsolation, retainingCode: original.codeOwner) { arguments, result, error in
                    let invocation = ABICreateSwiftAsyncInvocation(prepared.call.interface.handle, original.entry.function,
                        original.entry.contextSize, result, arguments, original.value.context, error, nil)
                    precondition(invocation != nil, "The prepared async closure forwarding call must be valid.")
                    defer {
                        withExtendedLifetime(original) { ABIReleaseSwiftAsyncInvocation(invocation!) }
                    }
                    await invokeSwiftAsync(invocation!)
                    return ABISwiftAsyncInvocationDidThrow(invocation!)
                })
            return wrap(Self(storage: try storage(callback, discriminator: prepared.discriminator), call: prepared.call))
        }
    }

    @unsafe nonisolated(nonsending) func unsafeInvoke(_ values: repeat each Argument) async throws -> Result {
        try unsafe await call.unsafeInvoke(entry: storage.entry,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }
}

/// An owned caller-isolated native Swift async closure.
/// Failure is a concrete error type, any Error, or Never. Invocation preserves
/// the caller's task and executor; the caller satisfies the native ABI and isolation.
public struct NativeSwiftAsyncClosure<Result, Failure: Error, each Argument> {
    private let core: SwiftAsyncClosureCore<Result, Failure, repeat each Argument>

    /// Creates a callback whose Sendable body runs with the native caller's isolation.
    public init(_ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result) throws {
        core = try SwiftAsyncClosureCore(body, inheritsCallerIsolation: true)
    }
    private init(_ core: SwiftAsyncClosureCore<Result, Failure, repeat each Argument>) { self.core = core }

    /// Awaits the native closure on the original task. Native errors use NativeSwiftError.
    @unsafe public nonisolated(nonsending) func unsafeInvoke(_ values: repeat each Argument) async throws -> Result {
        try unsafe await core.unsafeInvoke(repeat each values)
    }
}
extension NativeSwiftAsyncClosure: SwiftClosureValue {
    static var swiftFunctionType: Any.Type {
        (nonisolated(nonsending) @Sendable (repeat each Argument) async throws(Failure) -> Result).self
    }
    func encodeClosure() -> NativeValueStorage { core.storage.encoded() }
    static func makeClosureCodec() throws -> SwiftClosureCodec {
        try SwiftAsyncClosureCore<Result, Failure, repeat each Argument>.codec(inheritsCallerIsolation: true, wrap: Self.init)
    }
}

/// An owned native Swift async closure using the concurrent calling convention.
/// Native entry runs without a hidden caller-isolation argument. Returned values
/// retain their native actor requirements and are not assumed Sendable.
public struct NativeSwiftConcurrentClosure<Result, Failure: Error, each Argument> {
    private let core: SwiftAsyncClosureCore<Result, Failure, repeat each Argument>

    /// Creates a callback whose Sendable body executes on the generic executor.
    public init(_ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result) throws {
        core = try SwiftAsyncClosureCore(body, inheritsCallerIsolation: false)
    }
    private init(_ core: SwiftAsyncClosureCore<Result, Failure, repeat each Argument>) { self.core = core }

    /// Awaits the native closure and resumes on the caller's executor, preserving its task.
    @unsafe public nonisolated(nonsending) func unsafeInvoke(_ values: repeat each Argument) async throws -> Result {
        try unsafe await core.unsafeInvoke(repeat each values)
    }
}
extension NativeSwiftConcurrentClosure: SwiftClosureValue {
    static var swiftFunctionType: Any.Type {
        (@Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result).self
    }
    func encodeClosure() -> NativeValueStorage { core.storage.encoded() }
    static func makeClosureCodec() throws -> SwiftClosureCodec {
        try SwiftAsyncClosureCore<Result, Failure, repeat each Argument>.codec(inheritsCallerIsolation: false, wrap: Self.init)
    }
}
