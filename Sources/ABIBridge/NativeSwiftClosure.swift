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

/// An owned concrete, synchronous, nonthrowing Swift closure.
///
/// Use this value in a Swift function or member signature to pass a callback or
/// receive a returned closure. The bridge preserves its captured context,
/// authenticated entry point, and resolved implementation image. Calls stay on
/// their caller's executor; returned closures retain their native isolation
/// requirements and are not assumed Sendable.
///
/// The initial callback subset accepts the built-in Swift representations
/// supported by the direct frontend, plus established ABIBridgeSwiftValue layouts.
/// Custom ABIBridgeValue conversions and
/// nested closures require a compiler adapter. Void values and zero-argument
/// closures are supported.
/// See <doc:SwiftClosureValues>.
public struct NativeSwiftClosure<Result, each Argument> {
    let closureStorage: SwiftClosureStorage
    private let call: SwiftCall<Result, repeat each Argument>

    /// Creates a concrete native callback from a nonisolated Swift closure.
    ///
    /// The native callee may retain and call the callback after the initial call.
    /// Its Swift context keeps both the captured body and entry code alive until
    /// the final native reference is released. The body must be safe to call on
    /// the native caller's thread, including concurrent calls.
    ///
    /// - Parameter body: A synchronous Sendable callback.
    /// - Throws: An unsupported representation or callback allocation error.
    public init(_ body: @escaping @Sendable (repeat each Argument) -> Result) throws {
        try self.init(scopedBody: body)
    }

    /// Borrows a caller-isolated body for a native nonescaping closure parameter.
    ///
    /// Neither the native callee nor `use` may retain or return the callback.
    /// Calls must remain synchronous on this executor. This permits captures
    /// that do not satisfy Sendable without changing the body's isolation.
    @unsafe public static func withUnsafeNonescaping<Output>(
        _ body: (repeat each Argument) -> Result,
        _ use: (Self) throws -> Output
    ) throws -> Output {
        try withoutActuallyEscaping(body) { escaped in
            try use(Self(scopedBody: escaped))
        }
    }

    private init(scopedBody body: @escaping (repeat each Argument) -> Result) throws {
        let prepared = try Self.prepare()
        let callback = try SwiftClosureCallbackOwner(interface: prepared.call.interface, body: SwiftClosureBody { arguments, output in
            var index = 0
            func decode<Value>(_ type: Value.Type) -> Value {
                defer { index += 1 }
                return arguments![index]!.load(as: type)
            }
            // Preparation excludes user-defined conversions. These bytes are
            // native Swift values under the caller's declared ABI contract.
            let values = (repeat decode((each Argument).self))
            let value = body(repeat each values)
            output.initializeMemory(as: Result.self, repeating: value, count: 1)
        })
        let value = ABISwiftClosureValue(
            function: ABISignSwiftClosureFunction(callback.function, prepared.discriminator),
            context: Unmanaged.passRetained(callback).toOpaque()
        )
        closureStorage = try SwiftClosureStorage(adopting: value, discriminator: prepared.discriminator, retaining: nil)
        call = prepared.call
    }

    private init(storage: SwiftClosureStorage, call: SwiftCall<Result, repeat each Argument>) {
        closureStorage = storage
        self.call = call
    }

    private static func prepare() throws -> (call: SwiftCall<Result, repeat each Argument>, discriminator: UInt16) {
        var parameters: [String] = []
        for type in repeat (each Argument).self {
            // SIL flattens an explicit empty-tuple argument into no formal parameters.
            if type != Void.self { parameters.append(try swiftClosureAuthType(type)) }
        }
        let result = Result.self == Void.self ? nil : try swiftClosureAuthType(Result.self)
        let call = try SwiftCall<Result, repeat each Argument>()
        return (call, swiftClosureDiscriminator(parameters: parameters, result: result))
    }

    /// Calls the retained native closure with its concrete Swift ABI.
    ///
    /// The caller must satisfy its original actor/thread and argument contracts.
    /// No executor hop or Sendable guarantee is inferred from the closure's
    /// representation. An invalid ABI or native pointer can corrupt memory.
    ///
    /// - Parameter values: Arguments in declaration order.
    /// - Returns: The native result with its ordinary Swift ownership.
    /// - Throws: An argument conversion or invocation error.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe call.unsafeInvoke(
            function: closureStorage.implementation.function,
            context: closureStorage.value.context.map { UnsafeRawPointer($0) },
            retaining: closureStorage, repeat each values
        )
    }
}

extension NativeSwiftClosure: SwiftClosureValue {
    func encodeClosure() -> NativeValueStorage { closureStorage.encoded() }
    static var swiftFunctionType: Any.Type { ((repeat each Argument) -> Result).self }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        let prepared = try prepare()
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer])) { value, owner, taking in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftClosureStorage(adopting: value, discriminator: prepared.discriminator, retaining: owner)
            if ABIIsSwiftClosureCallbackFunction(original.implementation.function) {
                return Self(storage: original, call: prepared.call)
            }
            // Native copies retain only the two-word closure's heap context.
            // Keep code owners in that context as well, so an escaping callee
            // does not depend on the lifetime of this Swift wrapper.
            let callback = try SwiftClosureCallbackOwner(interface: prepared.call.interface, body: SwiftClosureBody(retainingCode: original.codeOwner) { arguments, output in
                let succeeded = ABIUnsafeInvokeSwiftCallInterface(
                    prepared.call.interface.handle, original.implementation.function,
                    output, arguments, original.value.context, nil
                )
                // Both this entry and the forwarded call use the same prepared
                // signature and frame storage; failure is an internal ABI bug.
                precondition(succeeded, "The prepared Swift closure forwarding call must be valid.")
            })
            let forwarded = ABISwiftClosureValue(
                function: ABISignSwiftClosureFunction(callback.function, prepared.discriminator),
                context: Unmanaged.passRetained(callback).toOpaque()
            )
            let storage = try SwiftClosureStorage(adopting: forwarded, discriminator: prepared.discriminator, retaining: nil)
            return Self(storage: storage, call: prepared.call)
        }
    }
}


extension NativeSwiftClosure: SwiftGenericResultClosure {
    static var resultType: Any.Type { Result.self }
    static var parameterTypes: [Any.Type] {
        var result: [Any.Type] = []
        for type in repeat (each Argument).self { result.append(type) }
        return result
    }

    func encodeGenericResultClosure(retainingCode owner: Any?) throws -> NativeValueStorage {
        // The declaration-level result stays indirect even for scalar substitutions.
        // Forwarding through the concrete interface performs the reabstraction.
        let result = try CValueType(indirectSwiftSize: MemoryLayout<Result>.size, alignment: MemoryLayout<Result>.alignment)
        let interface = try SwiftCallInterface(result: result, parameters: [])
        let original = closureStorage
        let concrete = call.interface
        let callback = try SwiftClosureCallbackOwner(interface: interface, body: SwiftClosureBody(retainingCode: (original.codeOwner, owner)) { arguments, output in
            let success = ABIUnsafeInvokeSwiftCallInterface(concrete.handle, original.implementation.function,
                output, arguments, original.value.context, nil)
            // Preparation established the interface and all required buffers.
            precondition(success, "A prepared closure reabstraction must have a valid call frame.")
        })
        let discriminator = swiftClosureDiscriminator(parameters: [], result: "-indirect")
        let value = ABISwiftClosureValue(function: ABISignSwiftClosureFunction(callback.function, discriminator),
            context: Unmanaged.passRetained(callback).toOpaque())
        let adapted = try SwiftClosureStorage(adopting: value, discriminator: discriminator, retaining: original)
        return adapted.encoded()
    }
}
