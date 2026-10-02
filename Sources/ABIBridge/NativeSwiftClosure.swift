import ABIBridgeCore

final class SwiftClosureCodeOwner {
    let value: Any
    init(_ value: Any) { self.value = value }
}

final class SwiftClosureBody {
    let codeOwner: SwiftClosureCodeOwner?
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void
    init(retainingCode codeOwner: Any? = nil, _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void) {
        self.codeOwner = codeOwner.map(SwiftClosureCodeOwner.init)
        self.invoke = invoke
    }
}

final class SwiftClosureCallbackOwner {
    let handle: OpaquePointer
    var function: ABIUnmanagedFunction { ABISwiftClosureCallbackFunction(handle)! }

    init(handle: OpaquePointer) { self.handle = handle }

    init(interface: SwiftCallInterface, body: SwiftClosureBody) throws {
        var functions = ABISwiftClosureCallbackFunctions()
        functions.invoke = { context, arguments, result in
            Unmanaged<SwiftClosureBody>.fromOpaque(context!).takeUnretainedValue().invoke(arguments, result!)
        }
        functions.releaseContext = { Unmanaged<SwiftClosureBody>.fromOpaque($0!).release() }
        functions.copyCodeOwner = { context in
            let owner = Unmanaged<SwiftClosureBody>.fromOpaque(context!).takeUnretainedValue().codeOwner
            return owner.map { Unmanaged.passRetained($0).toOpaque() }
        }
        let context = Unmanaged.passRetained(body)
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftClosureCallback(interface.handle, functions, context.toOpaque(), &failure) else {
            context.release()
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftClosureCallback(handle) }
}

enum SwiftClosureCall {
    case synchronous(SwiftClosureStorage, SwiftCall)
    case asynchronous(SwiftAsyncClosureStorage, SwiftAsyncCall)

    func encoded() -> NativeValueStorage {
        switch self {
        case .synchronous(let storage, _): storage.encoded()
        case .asynchronous(let storage, _): storage.encoded()
        }
    }
}

/// An owned native Swift closure described by its complete function signature.
///
/// Use this value in a function or member signature to pass a callback or receive
/// a returned closure. Copies preserve its captured context, authenticated entry,
/// and implementation images. The signature carries native errors and async
/// effects; invocation can also throw bridge errors. Values are not assumed Sendable.
/// See <doc:SwiftClosureValues>.
public struct NativeSwiftClosure<Signature> {
    let call: SwiftClosureCall

    init(call: SwiftClosureCall) { self.call = call }

    /// Creates a synchronous callback whose Sendable body may escape into native storage.
    /// The body must be safe on the native caller's thread, including concurrent calls.
    /// Its original declared errors are returned to native code.
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) throws(Failure) -> Result
    ) throws where Signature == (repeat each Argument) throws(Failure) -> Result {
        try self.init(scopedBody: body)
    }

    @_disfavoredOverload
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) throws(Failure) -> Result
    ) throws where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try self.init(scopedBody: body)
    }

    /// Borrows a caller-isolated body for a synchronous native nonescaping parameter.
    /// Neither native code nor use may retain or return the callback. Calls stay on this executor.
    @unsafe public static func withUnsafeNonescaping<Output, Result, each Argument>(
        _ body: (repeat each Argument) -> Result, _ use: (Self) throws -> Output
    ) throws -> Output where Signature == (repeat each Argument) -> Result {
        try withoutActuallyEscaping(body) { escaped in try use(Self(scopedBody: escaped)) }
    }

    /// Borrows a Sendable body while preserving that attribute in the native signature.
    /// The callback remains nonescaping and synchronous on the caller's executor.
    @_disfavoredOverload
    @unsafe public static func withUnsafeNonescaping<Output, Result, each Argument>(
        _ body: @Sendable (repeat each Argument) -> Result, _ use: (Self) throws -> Output
    ) throws -> Output where Signature == @Sendable (repeat each Argument) -> Result {
        try withoutActuallyEscaping(body) { escaped in try use(Self(scopedBody: escaped)) }
    }

    private init<Result, Failure: Error, each Argument>(
        scopedBody body: @escaping (repeat each Argument) throws(Failure) -> Result
    ) throws {
        let signature = try SwiftFunctionSignature(Signature.self)
        let discriminator = try signature.closureDiscriminator()
        let prepared = try SwiftCall(signature: Signature.self, errorPlan: signature.makeErrorPlan())
        let callback = try throwingClosureOwner(prepared.interface, body: SwiftThrowingClosureBody { arguments, output, errorOutput in
            var index = 0
            func decode<Value>(_ type: Value.Type) -> Value {
                defer { index += 1 }
                return arguments![index]!.load(as: type)
            }
            let values = (repeat decode((each Argument).self))
            do throws(Failure) {
                let value = try body(repeat each values)
                output.initializeMemory(as: Result.self, repeating: value, count: 1)
                return false
            } catch {
                errorOutput!.initializeMemory(as: Failure.self, repeating: error, count: 1)
                return true
            }
        })
        call = .synchronous(try Self.storage(callback, discriminator: discriminator), prepared)
    }

    private static func storage(_ callback: SwiftClosureCallbackOwner, discriminator: UInt16) throws -> SwiftClosureStorage {
        try SwiftClosureStorage(adopting: ABISwiftClosureValue(
            function: ABISignSwiftClosureFunction(callback.function, discriminator),
            context: Unmanaged.passRetained(callback).toOpaque()), discriminator: discriminator, retaining: nil)
    }

    /// Calls the retained native closure. Native errors are surfaced as NativeSwiftError.
    /// The caller satisfies the native signature's ABI, ownership, and actor/thread requirements.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let storage, let prepared) = call else { preconditionFailure("A synchronous closure has a synchronous call plan.") }
        return try unsafe prepared.unsafeInvoke(function: storage.implementation.function,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let storage, let prepared) = call else { preconditionFailure("A synchronous closure has a synchronous call plan.") }
        return try unsafe prepared.unsafeInvoke(function: storage.implementation.function,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }
}

extension NativeSwiftClosure: SwiftClosureValue {
    func encodeClosure() -> NativeValueStorage { call.encoded() }
    static var swiftFunctionType: Any.Type { Signature.self }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        try makeClosureCodec(generic: nil)
    }

    static func makeClosureCodec(generic: SwiftGenericClosurePlan?) throws -> SwiftClosureCodec {
        let signature = try SwiftFunctionSignature(Signature.self)
        if signature.isAsync { return try makeAsyncClosureCodec(signature: signature, generic: generic) }
        let discriminator = try signature.closureDiscriminator()
        let prepared = try SwiftCall(signature: Signature.self, errorPlan: signature.makeErrorPlan())
        let interface: SwiftCallInterface
        if let generic {
            guard case .synchronous(let original) = generic.transport else {
                preconditionFailure("The prepared closure effects must agree.")
            }
            interface = original
        } else { interface = prepared.interface }
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer])) { value, owner, taking in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftClosureStorage(adopting: value, discriminator: generic?.discriminator ?? discriminator, retaining: owner)
            if generic == nil && ABIIsSwiftClosureCallbackFunction(original.implementation.function) {
                return Self(call: .synchronous(original, prepared))
            }
            // Native copies retain only the closure's heap context. Forwarding keeps
            // implementation images alive until the final native copy is destroyed.
            let callback = try throwingClosureOwner(prepared.interface, body: SwiftThrowingClosureBody(retainingCode: original.codeOwner) { arguments, result, failure in
                var didThrow = false
                let encoded = generic?.parameters.hasPacks == true ? generic!.parameters.encode(arguments) : nil
                func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                    if prepared.errorPlan != nil {
                        return ABIUnsafeInvokeSwiftThrowingCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context, failure, &didThrow, nil)
                    }
                    return ABIUnsafeInvokeSwiftCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context, nil)
                }
                let succeeded = withExtendedLifetime(encoded) {
                    encoded.map { $0.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } } ?? invoke(arguments)
                }
                precondition(succeeded, "The prepared Swift closure forwarding call must be valid.")
                return didThrow
            })
            return Self(call: .synchronous(try storage(callback, discriminator: discriminator), prepared))
        }
    }
}

extension NativeSwiftClosure: SwiftGenericClosureValue {
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec {
        try makeClosureCodec(generic: plan)
    }

    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage {
        if case .asynchronous = plan.transport {
            return try encodeGenericAsyncClosure(plan: plan, retainingCode: owner)
        }
        guard case .synchronous(let interface) = plan.transport,
              case .synchronous(let original, let prepared) = call else {
            preconditionFailure("The prepared callback and its formal transport must agree.")
        }
        let callback = try throwingClosureOwner(interface, body: SwiftThrowingClosureBody(retainingCode: (original.codeOwner, owner)) { arguments, output, error in
            var didThrow = false
            func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                if prepared.errorPlan != nil {
                    return ABIUnsafeInvokeSwiftThrowingCallInterface(prepared.interface.handle,
                        original.implementation.function, output, arguments, original.value.context, error, &didThrow, nil)
                }
                return ABIUnsafeInvokeSwiftCallInterface(prepared.interface.handle, original.implementation.function,
                        output, arguments, original.value.context, nil)
            }
            let success = plan.parameters.hasPacks
                ? plan.parameters.unpack(arguments).withUnsafeBufferPointer { invoke($0.baseAddress) }
                : invoke(arguments)
            precondition(success, "A prepared closure reabstraction must have a valid call frame.")
            return didThrow
        })
        let value = ABISwiftClosureValue(function: ABISignSwiftClosureFunction(callback.function, plan.discriminator),
            context: Unmanaged.passRetained(callback).toOpaque())
        let adapted = try SwiftClosureStorage(adopting: value, discriminator: plan.discriminator, retaining: original)
        return adapted.encoded()
    }
}
