import ABIBridgeCore

private final class SwiftClosureBody {
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void
    init(_ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void) {
        self.invoke = invoke
    }
}

private final class SwiftClosureCallbackOwner {
    let handle: OpaquePointer
    var function: ABIUnmanagedFunction { ABISwiftClosureCallbackFunction(handle)! }

    init(interface: SwiftCallInterface, body: SwiftClosureBody) throws {
        var functions = ABISwiftClosureCallbackFunctions()
        functions.invoke = { context, arguments, result in
            Unmanaged<SwiftClosureBody>.fromOpaque(context!).takeUnretainedValue().invoke(arguments, result!)
        }
        functions.releaseContext = { Unmanaged<SwiftClosureBody>.fromOpaque($0!).release() }
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
/// supported by the direct frontend. Custom ABIBridgeValue conversions and
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
            let callback = try SwiftClosureCallbackOwner(interface: prepared.call.interface, body: SwiftClosureBody { arguments, output in
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
