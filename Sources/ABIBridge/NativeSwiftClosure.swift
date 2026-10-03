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

final class SwiftClosureCallbackOwner: @unchecked Sendable {
    let handle: OpaquePointer
    var function: ABIUnmanagedFunction { ABISwiftClosureCallbackFunction(handle)! }

    let implementation: SwiftImplementation
    init(handle: OpaquePointer) throws {
        self.handle = handle
        do { implementation = try SwiftImplementation(function: ABISwiftClosureCallbackFunction(handle)!, retaining: nil) }
        catch { ABIReleaseSwiftClosureCallback(handle); throw error }
    }

    deinit { ABIReleaseSwiftClosureCallback(handle) }
}

enum SwiftClosureCall {
    case host(SwiftClosureHost)
    case synchronous(SwiftClosureStorage, SwiftCall)
    case asynchronous(SwiftAsyncClosureStorage, SwiftAsyncCall)

    indirect case borrowed(resolve: (Bool) throws -> SwiftClosureCall, copy: () throws -> SwiftClosureCall)
    case failure(any Error)

    func resolved(asynchronous: Bool = false) throws -> SwiftClosureCall {
        if case .host(let host) = self { return try host.resolved() }
        if case .borrowed(let resolve, _) = self { return try resolve(asynchronous) }
        if case .failure(let error) = self { throw error }
        return self
    }

    func encoded() throws -> NativeValueStorage {
        switch self {
        case .synchronous(let storage, _): storage.encoded()
        case .asynchronous(let storage, _): storage.encoded()
        case .host, .borrowed, .failure: try resolved().encoded()
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
        if case .failure(let error) = call { throw error }
        return self
    }

    /// Creates a synchronous callback whose Sendable body may escape into native storage.
    /// The body must be safe on the native caller's thread, including concurrent calls.
    /// Its original declared errors are returned to native code. Native entry
    /// preparation occurs on the first invocation or publication.
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
        let codeLifetime = SwiftValueCodeLifetime([])
        let factory = SwiftClosureBodyFactory(signature: Signature.self, synchronous: { plan, factory, owner in
            let parameters = try plan?.parameters ?? SwiftGenericParameters(actual: signature.parameters,
                arguments: SwiftGenericParameters.concreteArguments(signature: signature))
            let inputs = try SwiftCallbackValues(signature, arguments: parameters.arguments)
            let result = try SwiftCallbackResult<Result>(failure: Failure.self, generic: plan?.result ?? .concrete)
            return SwiftThrowingClosureBody(retainingCode: owner, codeLifetime: codeLifetime, callbackFactory: factory,
                initializeResult: result.initializeNativeResult) { native, output, errorOutput in
                let unpacked = parameters.needsEncoding ? parameters.unpack(native) : nil
                func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                    let scope = inputs.makeScope(asynchronous: false, arguments: arguments)
                    defer { withExtendedLifetime(scope) {} }
                    var index = 0
                    func decode<Value>(_ type: Value.Type) throws -> Value {
                        defer { index += 1 }
                        return try inputs.decode(arguments![index]!, at: index, scope: scope, as: type)
                    }
                    do {
                        let values = (repeat try decode((each Argument).self))
                        if scope?.hasWritebacks != true {
                            try result.initialize(body(repeat each values), at: output)
                            return false
                        }
                        let outcome = Swift.Result<(UnsafeMutableRawPointer) -> Void, any Error> {
                            try result.prepare(body(repeat each values))
                        }
                        let initialize = try scope?.finishInvocation(outcome) ?? outcome.get()
                        initialize(output)
                        return false
                    } catch {
                        errorOutput!.initializeMemory(as: Failure.self, repeating: error as! Failure, count: 1)
                        return true
                    }
                }
                if let unpacked { return withExtendedLifetime(unpacked) { unpacked.addresses.withUnsafeBufferPointer { invoke($0.baseAddress) } } }
                return invoke(native)
            }
        })
        call = .host(SwiftClosureHost(factory: factory, codeLifetime: codeLifetime) {
            let discriminator = try signature.closureDiscriminator()
            let prepared = try SwiftCall(signature: Signature.self, errorPlan: signature.makeErrorPlan())
            let canonicalBody = try factory.synchronous(plan: nil, retainingCode: nil)
            let context = try SwiftClosureContext(interface: prepared.interface, body: canonicalBody)
            return .synchronous(try context.storage(discriminator: discriminator), prepared)
        })
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
    func encodeClosure(consuming: Bool = false) throws -> NativeValueStorage {
        if consuming, case .borrowed = call { return try copy().encodeClosure(consuming: true) }
        let native: SwiftGenericClosurePlan?
        let resolved = try call.resolved()
        switch resolved {
        case .synchronous(_, let prepared): native = prepared.closure
        case .asynchronous(_, let prepared): native = prepared.closure
        case .host, .borrowed, .failure: preconditionFailure("Resolving a closure produces a native call.")
        }
        if native != nil {
            return try encodeGenericClosure(plan: SwiftGenericClosurePlan.concrete(Signature.self), retainingCode: nil)
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
        let discriminator = try generic?.discriminator ?? signature.closureDiscriminator()
        let prepared = try SwiftCall(signature: Signature.self,
            errorPlan: generic == nil ? signature.makeErrorPlan() : generic?.errorPlan, closure: generic)
        let interface: SwiftCallInterface
        if let generic {
            guard case .synchronous(let original) = generic.transport else {
                preconditionFailure("The prepared closure effects must agree.")
            }
            interface = original
        } else { interface = prepared.interface }
        let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any = { value, owner, taking, codeLifetime in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftClosureStorage(adopting: value, discriminator: discriminator,
                retaining: owner, codeLifetime: codeLifetime)
            if ABIIsSwiftClosureCallbackFunction(original.implementation.function) {
                return Self(call: .synchronous(original, prepared))
            }
            // Native copies retain only the closure's heap context. Forwarding keeps
            // implementation images alive until the final native copy is destroyed.
            let callback = try SwiftClosureContext(interface: prepared.interface, body: SwiftThrowingClosureBody(
                retainingCode: original.codeOwner, codeLifetime: original.codeLifetime,
                initializeResult: swiftResultInitializer(nativeMetadata: generic?.nativeResult ?? signature.result,
                    generic: generic?.result ?? .concrete)) { arguments, result, failure in
                var didThrow = false
                func invoke(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> Bool {
                    if prepared.errorPlan != nil {
                        return ABIUnsafeInvokeSwiftThrowingCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context,
                            failure, &didThrow, nil)
                    }
                    return ABIUnsafeInvokeSwiftCallInterface(interface.handle,
                            original.implementation.function, result, arguments, original.value.context, nil)
                }
                let succeeded = invoke(arguments)
                precondition(succeeded, "The prepared Swift closure forwarding call must be valid.")
                return didThrow
            })
            return Self(call: .synchronous(try callback.storage(discriminator: discriminator,
                codeLifetime: original.codeLifetime), prepared))
        }
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer]), nativePlan: generic,
            encoding: { value, owner in try (value as! Self).encodeClosureResult(generic: generic, retainingCode: owner) }, borrowing: { borrow, lifetime in
            Self(call: .borrowed(resolve: { asynchronous in
                let access = try borrow.access(asynchronous: asynchronous, codeLifetime: lifetime)
                let value = access.address.load(as: ABISwiftClosureValue.self)
                let storage = try SwiftClosureStorage(adopting: value, discriminator: discriminator,
                    retaining: access, codeLifetime: lifetime, ownsContext: false)
                return .synchronous(storage, prepared)
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

extension NativeSwiftClosure {
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec {
        try makeClosureCodec(generic: plan)
    }

    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?, asynchronous: Bool = false, consuming: Bool = false) throws -> NativeValueStorage {
        if plan.isEscaping || consuming, case .borrowed = call {
            return try copy().encodeGenericClosure(plan: plan, retainingCode: owner, asynchronous: asynchronous, consuming: consuming)
        }
        if case .asynchronous = plan.transport {
            return try encodeGenericAsyncClosure(plan: plan, retainingCode: owner, asynchronous: asynchronous)
        }
        if case .host(let host) = call {
            return try host.factory.encode(plan: plan, retainingCode: owner, codeLifetime: host.codeLifetime)
        }
        guard case .synchronous(let interface) = plan.transport,
              case .synchronous(let original, let prepared) = try call.resolved(asynchronous: asynchronous) else {
            preconditionFailure("The prepared callback and its formal transport must agree.")
        }
        if let native = prepared.closure {
            try native.validateNativeValues(for: plan)
            if native.hasSameNativeABI(as: plan) { return original.encoded() }
        }
        else if !plan.convertsValues, interface === prepared.interface { return original.encoded() }
        if let factory = original.callbackFactory, factory.signature == Signature.self {
            return try factory.encode(plan: plan, retainingCode: (original.codeOwner, owner),
                codeLifetime: original.codeLifetime)
        }
        if plan.hasNestedClosures || prepared.closure?.hasNestedClosures == true
            || plan.hasTuples || prepared.closure?.hasTuples == true {
            let source = try prepared.closure ?? SwiftGenericClosurePlan.concrete(Signature.self)
            let adapter = try SwiftNativeClosureAdapter(source: source, target: plan)
            return adapter.encode(original.value, taking: false, escaping: false, retainingValue: original,
                retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime)
        }
        if let native = prepared.closure { try native.validateNativeValues(for: plan) }
        else { try plan.validateCallbackConversion() }
        let callback = try SwiftClosureContext(interface: interface, body: SwiftThrowingClosureBody(
            retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime,
            initializeResult: swiftResultInitializer(nativeMetadata: plan.nativeResult, generic: plan.result)) { arguments, output, error in
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
            native?.finishInvocation()
            return didThrow || plan.encodeCallbackResult(convertedResult, to: output, errorOutput: error)
        })
        return try callback.storage(discriminator: plan.discriminator,
            codeLifetime: original.codeLifetime).encoded()
    }
}
