import ABIBridgeCore

private final class SwiftThrowingClosureBody {
    let codeOwner: SwiftClosureCodeOwner?
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool
    init(retainingCode codeOwner: Any? = nil, _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool) {
        self.codeOwner = codeOwner.map(SwiftClosureCodeOwner.init)
        self.invoke = invoke
    }
}
private func throwingClosureOwner(_ interface: SwiftCallInterface, body: SwiftThrowingClosureBody) throws -> SwiftClosureCallbackOwner {
    var functions = ABISwiftThrowingClosureCallbackFunctions()
    functions.invoke = { context, arguments, result, error in
        Unmanaged<SwiftThrowingClosureBody>.fromOpaque(context!).takeUnretainedValue().invoke(arguments, result!, error)
    }
    functions.releaseContext = { Unmanaged<SwiftThrowingClosureBody>.fromOpaque($0!).release() }
    functions.copyCodeOwner = { context in
        let owner = Unmanaged<SwiftThrowingClosureBody>.fromOpaque(context!).takeUnretainedValue().codeOwner
        return owner.map { Unmanaged.passRetained($0).toOpaque() }
    }
    let context = Unmanaged.passRetained(body)
    var failure: OpaquePointer?
    guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, context.toOpaque(), &failure) else {
        context.release()
        throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
    }
    return SwiftClosureCallbackOwner(handle: handle)
}

/// An owned concrete synchronous Swift closure with a declared native error type.
///
/// Failure may be a concrete Error type, any Error, or Never. Values use their
/// actual Swift representations and ownership. Native failures are surfaced by
/// unsafeInvoke as NativeSwiftError; generated callbacks throw the body's original
/// declared error into native code. See <doc:SwiftClosureValues>.
public struct NativeSwiftThrowingClosure<Result, Failure: Error, each Argument> {
    let closureStorage: SwiftClosureStorage
    private let call: SwiftCall<Result, repeat each Argument>

    /// Creates a throwing callback whose captures may escape into native storage.
    ///
    /// The body must be safe on the native caller's thread, including concurrent calls.
    public init(_ body: @escaping @Sendable (repeat each Argument) throws(Failure) -> Result) throws {
        let prepared = try Self.prepare()
        let callback = try throwingClosureOwner(prepared.call.interface, body: SwiftThrowingClosureBody { arguments, result, errorOutput in
            var index = 0
            func decode<Value>(_ type: Value.Type) -> Value {
                defer { index += 1 }
                return arguments![index]!.load(as: type)
            }
            let values = (repeat decode((each Argument).self))
            do throws(Failure) {
                let value = try body(repeat each values)
                result.initializeMemory(as: Result.self, repeating: value, count: 1)
                return false
            } catch {
                errorOutput!.initializeMemory(as: Failure.self, repeating: error, count: 1)
                return true
            }
        })
        closureStorage = try Self.storage(callback, discriminator: prepared.discriminator)
        call = prepared.call
    }

    private init(storage: SwiftClosureStorage, call: SwiftCall<Result, repeat each Argument>) {
        closureStorage = storage
        self.call = call
    }

    private static func storage(_ owner: SwiftClosureCallbackOwner, discriminator: UInt16) throws -> SwiftClosureStorage {
        try SwiftClosureStorage(adopting: ABISwiftClosureValue(
            function: ABISignSwiftClosureFunction(owner.function, discriminator),
            context: Unmanaged.passRetained(owner).toOpaque()), discriminator: discriminator, retaining: nil)
    }

    private static func prepare() throws -> (call: SwiftCall<Result, repeat each Argument>, discriminator: UInt16) {
        var parameters: [String] = []
        for type in repeat (each Argument).self {
            if type != Void.self { parameters.append(try swiftClosureAuthType(type)) }
        }
        let result = Result.self == Void.self ? nil : try swiftClosureAuthType(Result.self)
        return (try SwiftCall(errorPlan: SwiftErrorPlan.make(Failure.self)),
                swiftClosureDiscriminator(parameters: parameters, result: result))
    }

    /// Calls the native closure, preserving owned errors and code lifetime.
    ///
    /// The caller satisfies its actual ABI and actor/thread requirements.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe call.unsafeInvoke(function: closureStorage.implementation.function,
            context: closureStorage.value.context.map { UnsafeRawPointer($0) },
            retaining: closureStorage, retainingCode: closureStorage.codeOwner, repeat each values)
    }
}

extension NativeSwiftThrowingClosure: SwiftClosureValue {
    func encodeClosure() -> NativeValueStorage { closureStorage.encoded() }
    static var swiftFunctionType: Any.Type { ((repeat each Argument) throws(Failure) -> Result).self }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        let prepared = try prepare()
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer])) { value, owner, taking in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftClosureStorage(adopting: value, discriminator: prepared.discriminator, retaining: owner)
            if ABIIsSwiftClosureCallbackFunction(original.implementation.function) {
                return Self(storage: original, call: prepared.call)
            }
            let callback = try throwingClosureOwner(prepared.call.interface, body: SwiftThrowingClosureBody(retainingCode: original.codeOwner) { arguments, result, failure in
                var didThrow = false
                let succeeded = ABIUnsafeInvokeSwiftThrowingCallInterface(
                    prepared.call.interface.handle, original.implementation.function,
                    result, arguments, original.value.context, failure, &didThrow, nil)
                precondition(succeeded, "The prepared throwing closure forwarding call must be valid.")
                return didThrow
            })
            return Self(storage: try storage(callback, discriminator: prepared.discriminator), call: prepared.call)
        }
    }
}
