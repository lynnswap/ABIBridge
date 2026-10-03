import ABIBridgeCore

final class SwiftClosureCodeOwner {
    let value: Any?
    let codeLifetime: SwiftValueCodeLifetime?
    init?(_ value: Any?, codeLifetime: SwiftValueCodeLifetime? = nil) {
        guard value != nil || codeLifetime != nil else { return nil }
        self.value = value
        self.codeLifetime = codeLifetime
    }
}

final class SwiftClosureBody {
    let codeOwner: SwiftClosureCodeOwner?
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void
    init(retainingCode codeOwner: Any? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer) -> Void) {
        self.codeOwner = SwiftClosureCodeOwner(codeOwner, codeLifetime: codeLifetime)
        self.invoke = { arguments, result in
            SwiftValueCodeLifetime.withCurrent(codeLifetime) { invoke(arguments, result) }
        }
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

    case borrowed(resolve: (Bool) throws -> SwiftClosureCall, copy: () throws -> SwiftClosureCall)
    case failure(any Error)

    func resolved(asynchronous: Bool = false) throws -> SwiftClosureCall {
        if case .borrowed(let resolve, _) = self { return try resolve(asynchronous) }
        if case .failure(let error) = self { throw error }
        return self
    }

    func encoded() throws -> NativeValueStorage {
        switch self {
        case .synchronous(let storage, _): storage.encoded()
        case .asynchronous(let storage, _): storage.encoded()
        case .borrowed, .failure: try resolved().encoded()
        }
    }
}

/// A native Swift closure described by its complete function signature.
///
/// Use this value in a function or member signature to pass a callback or receive
/// a returned closure. Copies preserve its captured context, authenticated entry,
/// and implementation images. The signature carries native errors and async
/// effects; invocation can also throw bridge errors. Values are not assumed Sendable.
/// An ordinary closure callback input borrows that callback's scope. Saved copies
/// throw NativeSwiftBorrowError.expiredBorrow after the callback returns.
/// A NativeSwiftConsuming input owns its native context and may outlive the callback.
/// If preparing that owned input fails, invocation, copy(), and passing the handle
/// back to native code throw the preparation error; the incoming context is released.
/// Use copy() during the callback to retain an input declared @escaping.
/// Async callbacks must await operations on borrowed inputs before returning.
/// See <doc:SwiftClosureValues>.
public struct NativeSwiftClosure<Signature> {
    let call: SwiftClosureCall

    init(call: SwiftClosureCall) { self.call = call }

    /// Retains an owned reference to this closure's captured state and code.
    /// A borrowed callback input must still be active and have a native @escaping
    /// declaration. Copying a nonescaping input throws; ordinary assignment keeps
    /// the original borrow scope. Preparing native code ownership can also throw.
    public func copy() throws -> Self {
        if case .borrowed(_, let copy) = call { return Self(call: try copy()) }
        return Self(call: try call.resolved())
    }

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
        let codeLifetime = SwiftValueCodeLifetime([])
        let factory = SwiftClosureBodyFactory(signature: Signature.self, synchronous: { plan, factory, owner in
            let inputs = try SwiftCallbackValues(signature, arguments: plan?.parameters.arguments ?? [])
            let result = try SwiftCallbackResult<Result>(failure: Failure.self, generic: plan?.result ?? .concrete)
            return SwiftThrowingClosureBody(retainingCode: owner, codeLifetime: codeLifetime, callbackFactory: factory) { native, output, errorOutput in
                let decoded = plan?.decodeArguments(native)
                defer { withExtendedLifetime(decoded) {} }
                func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                    let scope = inputs.makeScope(asynchronous: false)
                    defer { withExtendedLifetime(scope) {} }
                    var index = 0
                    func decode<Value>(_ type: Value.Type) -> Value {
                        defer { index += 1 }
                        return inputs.decode(arguments![index]!, at: index, scope: scope, as: type)
                    }
                    let values = (repeat decode((each Argument).self))
                    do {
                        let value = try body(repeat each values)
                        let convertedResult = plan?.makeCallbackResultStorage()
                        try result.initialize(value, at: convertedResult?.address ?? output)
                        return plan?.encodeCallbackResult(convertedResult, to: output, errorOutput: errorOutput) ?? false
                    } catch {
                        errorOutput!.initializeMemory(as: Failure.self, repeating: error as! Failure, count: 1)
                        return true
                    }
                }
                if let decoded { return decoded.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } }
                return invoke(native)
            }
        })
        let callback = try throwingClosureOwner(prepared.interface, body: factory.synchronous(plan: nil, retainingCode: nil))
        call = .synchronous(try Self.storage(callback, discriminator: discriminator), prepared)
    }

    private static func storage(_ callback: SwiftClosureCallbackOwner, discriminator: UInt16,
                                codeLifetime: SwiftValueCodeLifetime? = nil) throws -> SwiftClosureStorage {
        try SwiftClosureStorage(adopting: ABISwiftClosureValue(
            function: ABISignSwiftClosureFunction(callback.function, discriminator),
            context: Unmanaged.passRetained(callback).toOpaque()), discriminator: discriminator, retaining: nil,
            codeLifetime: codeLifetime)
    }

    /// Calls the retained native closure. Native errors are surfaced as NativeSwiftError.
    /// The caller satisfies the native signature's ABI, ownership, and actor/thread requirements.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let storage, let prepared) = try call.resolved() else { preconditionFailure("A synchronous closure has a synchronous call plan.") }
        return try unsafe prepared.unsafeInvoke(function: storage.implementation.function,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let storage, let prepared) = try call.resolved() else { preconditionFailure("A synchronous closure has a synchronous call plan.") }
        return try unsafe prepared.unsafeInvoke(function: storage.implementation.function,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }
}

extension NativeSwiftClosure: SwiftClosureValue {
    func encodeClosure() throws -> NativeValueStorage {
        let native: SwiftGenericClosurePlan?
        let resolved = try call.resolved()
        switch resolved {
        case .synchronous(_, let prepared): native = prepared.closure
        case .asynchronous(_, let prepared): native = prepared.closure
        case .borrowed, .failure: preconditionFailure("Resolving a closure produces a native call.")
        }
        guard native == nil else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "The runtime closure's native value declaration", found: [String(reflecting: Signature.self)]))
        }
        return try resolved.encoded()
    }
    func encodeClosureResult() throws -> NativeValueStorage {
        try encodeClosureResult(generic: nil, retainingCode: nil)
    }
    func encodeClosureResult(generic: SwiftGenericClosurePlan?, retainingCode owner: Any?) throws -> NativeValueStorage {
        if case .borrowed = call {
            throw ABIResolutionError.unsupportedDeclaration("A borrowed nonescaping closure cannot be returned as an owned native result.")
        }
        if let generic { return try encodeGenericClosure(plan: generic, retainingCode: owner) }
        return try encodeClosure()
    }
    static var swiftFunctionType: Any.Type { Signature.self }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        try makeClosureCodec(generic: nil)
    }

    static func makeClosureCodec(generic: SwiftGenericClosurePlan?) throws -> SwiftClosureCodec {
        let signature = try SwiftFunctionSignature(Signature.self)
        if signature.isAsync { return try makeAsyncClosureCodec(signature: signature, generic: generic) }
        let discriminator = try signature.closureDiscriminator()
        let prepared = try SwiftCall(signature: Signature.self,
            errorPlan: generic?.convertsValues == true ? generic?.errorPlan : signature.makeErrorPlan(), closure: generic?.convertsValues == true ? generic : nil)
        let interface: SwiftCallInterface
        if let generic {
            guard case .synchronous(let original) = generic.transport else {
                preconditionFailure("The prepared closure effects must agree.")
            }
            interface = original
        } else { interface = prepared.interface }
        let borrowedCall = try generic.map { try SwiftCall(signature: Signature.self, errorPlan: $0.errorPlan, closure: $0) } ?? prepared
        let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any = { value, owner, taking, codeLifetime in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftClosureStorage(adopting: value, discriminator: generic?.discriminator ?? discriminator,
                retaining: owner, codeLifetime: codeLifetime)
            if ABIIsSwiftClosureCallbackFunction(original.implementation.function) {
                return Self(call: .synchronous(original, borrowedCall))
            }
            // Native copies retain only the closure's heap context. Forwarding keeps
            // implementation images alive until the final native copy is destroyed.
            let callback = try throwingClosureOwner(prepared.interface, body: SwiftThrowingClosureBody(
                retainingCode: original.codeOwner, codeLifetime: original.codeLifetime) { arguments, result, failure in
                var didThrow = false
                let encoded = prepared.closure == nil && generic?.parameters.needsEncoding == true
                    ? generic!.parameters.encode(arguments) : nil
                // throws(E) keeps its error output when E is bound to Never.
                let unusedError = prepared.errorPlan == nil ? generic?.errorPlan?.makeStorage() : nil
                func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                    if generic?.errorPlan != nil || prepared.errorPlan != nil {
                        return ABIUnsafeInvokeSwiftThrowingCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context,
                            failure ?? unusedError?.address, &didThrow, nil)
                    }
                    return ABIUnsafeInvokeSwiftCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context, nil)
                }
                let succeeded = withExtendedLifetime((encoded, unusedError)) {
                    encoded.map { $0.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } } ?? invoke(arguments)
                }
                precondition(succeeded, "The prepared Swift closure forwarding call must be valid.")
                return didThrow
            })
            return Self(call: .synchronous(try storage(callback, discriminator: prepared.closure?.discriminator ?? discriminator,
                codeLifetime: original.codeLifetime), prepared))
        }
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer]), nativeValueTypes: generic?.nativeValueTypes ?? [], nativePlan: generic,
            encoding: { value, owner in try (value as! Self).encodeClosureResult(generic: generic, retainingCode: owner) }, borrowing: { borrow, lifetime in
            Self(call: .borrowed(resolve: { asynchronous in
                let access = try borrow.access(asynchronous: asynchronous, codeLifetime: lifetime)
                let value = access.address.load(as: ABISwiftClosureValue.self)
                let storage = try SwiftClosureStorage(adopting: value, discriminator: generic?.discriminator ?? discriminator,
                    retaining: access, codeLifetime: lifetime, ownsContext: false)
                return .synchronous(storage, borrowedCall)
            }, copy: {
                let access = try borrow.access(asynchronous: false, codeLifetime: lifetime)
                guard generic?.isEscaping == true else {
                    throw ABIResolutionError.unsupportedDeclaration("Copying a borrowed closure requires a native @escaping parameter.")
                }
                return try withExtendedLifetime(access) {
                    (try makeValue(access.address.load(as: ABISwiftClosureValue.self), nil, false, lifetime) as! Self).call
                }
            }))
        }, taking: { value, lifetime in
            do { return try makeValue(value, nil, true, lifetime) }
            catch { return Self(call: .failure(error)) }
        }, makeValue: makeValue)
    }
}

extension NativeSwiftClosure: SwiftGenericClosureValue {
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec {
        try makeClosureCodec(generic: plan)
    }

    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage {
        if plan.isEscaping, case .borrowed = call {
            return try copy().encodeGenericClosure(plan: plan, retainingCode: owner)
        }
        if case .asynchronous = plan.transport {
            return try encodeGenericAsyncClosure(plan: plan, retainingCode: owner)
        }
        guard case .synchronous(let interface) = plan.transport,
              case .synchronous(let original, let prepared) = try call.resolved() else {
            preconditionFailure("The prepared callback and its formal transport must agree.")
        }
        if let native = prepared.closure {
            try native.validateNativeValues(for: plan)
            if native.hasSameNativeABI(as: plan) { return original.encoded() }
        }
        else if !plan.convertsValues, interface === prepared.interface { return original.encoded() }
        if let factory = original.callbackFactory, factory.signature == Signature.self {
            try plan.validateCallbackConversion()
            let callback = try throwingClosureOwner(interface,
                body: factory.synchronous(plan: plan, retainingCode: (original.codeOwner, owner)))
            return try Self.storage(callback, discriminator: plan.discriminator,
                codeLifetime: original.codeLifetime).encoded()
        }
        if plan.hasNestedClosures || prepared.closure?.hasNestedClosures == true {
            let source = try prepared.closure ?? SwiftGenericClosurePlan.concrete(Signature.self)
            let adapter = try SwiftNativeClosureAdapter(source: source, target: plan)
            return adapter.encode(original.value, taking: false, escaping: false, retainingValue: original,
                retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime)
        }
        if let native = prepared.closure { try native.validateNativeValues(for: plan) }
        else { try plan.validateCallbackConversion() }
        let callback = try throwingClosureOwner(interface, body: SwiftThrowingClosureBody(
            retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime) { arguments, output, error in
            var didThrow = false
            let convertedResult = prepared.closure == nil ? plan.makeCallbackResultStorage() : nil
            let hostOutput = convertedResult?.address ?? output
            // A Never-bound generic source still has its formal error output.
            let unusedError = plan.errorPlan == nil ? prepared.errorPlan?.makeStorage() : nil
            defer { withExtendedLifetime(unusedError) {} }
            func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                if prepared.errorPlan != nil {
                    return ABIUnsafeInvokeSwiftThrowingCallInterface(prepared.interface.handle,
                        original.implementation.function, hostOutput, arguments, original.value.context,
                        error ?? unusedError?.address, &didThrow, nil)
                }
                return ABIUnsafeInvokeSwiftCallInterface(prepared.interface.handle, original.implementation.function,
                        hostOutput, arguments, original.value.context, nil)
            }
            let decoded = prepared.closure == nil ? plan.decodeArguments(arguments) : nil
            let native = prepared.closure.map { $0.parameters.encode(plan.parameters.unpack(arguments)) }
            let success: Bool
            if let native {
                success = withExtendedLifetime(native) { native.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } }
            } else if let decoded {
                success = withExtendedLifetime(decoded) { decoded.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } }
            } else { success = invoke(arguments) }
            precondition(success, "A prepared closure reabstraction must have a valid call frame.")
            return didThrow || plan.encodeCallbackResult(convertedResult, to: output, errorOutput: error)
        })
        let value = ABISwiftClosureValue(function: ABISignSwiftClosureFunction(callback.function, plan.discriminator),
            context: Unmanaged.passRetained(callback).toOpaque())
        let adapted = try SwiftClosureStorage(adopting: value, discriminator: plan.discriminator, retaining: original,
            codeLifetime: original.codeLifetime)
        return adapted.encoded()
    }
}
