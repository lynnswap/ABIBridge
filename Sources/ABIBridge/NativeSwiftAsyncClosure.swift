import ABIBridgeCore

final class SwiftAsyncClosureStorage {
    let value: ABISwiftClosureValue
    private let ownsContext: Bool
    let callbackFactory: SwiftClosureBodyFactory?
    let entry: SwiftAsyncEntry
    let codeOwner: Any
    let codeLifetime: SwiftValueCodeLifetime?

    init(adopting value: ABISwiftClosureValue, discriminator: UInt16, retaining owner: Any?,
         codeLifetime: SwiftValueCodeLifetime? = nil, ownsContext: Bool = true,
         entry prepared: SwiftAsyncEntry? = nil) throws {
        self.ownsContext = ownsContext
        let image: NativeImage?
        do {
            guard let descriptor = ABIAuthenticateSwiftAsyncClosureDescriptor(value.function, discriminator) else {
                throw ABIInvocationError.unexpectedNilResult(expected: "an async Swift closure")
            }
            entry = try prepared ?? SwiftAsyncEntry(descriptor: descriptor)
            image = try prepared == nil ? swiftImplementationImage(containing: descriptor) : nil
        } catch {
            withExtendedLifetime(owner) { if ownsContext { ABIReleaseSwiftClosureContext(value.context) } }
            throw error
        }
        self.value = value
        let callbackOwner = ABICopySwiftAsyncClosureCallbackCodeOwner(entry.function, value.context).map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        callbackFactory = ABICopySwiftAsyncClosureCallbackBodyOwner(entry.function, value.context).map {
            Unmanaged<SwiftClosureBodyFactory>.fromOpaque($0).takeRetainedValue()
        }
        codeOwner = (owner, entry, callbackOwner)
        let callbackLifetime = (callbackOwner as? SwiftClosureCodeOwner)?.codeLifetime
        let images = image.map { [$0] } ?? []
        let lifetime = codeLifetime ?? callbackLifetime ?? (images.isEmpty ? nil : SwiftValueCodeLifetime(images))
        self.codeLifetime = SwiftValueCodeLifetime.connect([lifetime, callbackLifetime].compactMap { $0 }, retaining: images)
    }

    deinit { withExtendedLifetime(codeOwner) { if ownsContext { ABIReleaseSwiftClosureContext(value.context) } } }
    func encoded() -> NativeValueStorage {
        if ownsContext { return SwiftClosureStorage.copy(value, retaining: self, codeLifetime: codeLifetime) }
        let storage = NativeValueStorage(size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment, owner: self, codeLifetime: codeLifetime)
        storage.store(value)
        return storage
    }
}

// Each invocation owns distinct buffers. The public body's Sendable contract
// permits concurrent native callers; no task or executor is created here.
final class SwiftAsyncClosureBody: @unchecked Sendable {
    let codeOwner: SwiftClosureCodeOwner?
    let callbackFactory: SwiftClosureBodyFactory?
    let inheritsCallerIsolation: Bool
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) async -> Bool
    init(inheritsCallerIsolation: Bool, retainingCode codeOwner: Any? = nil, codeLifetime: SwiftValueCodeLifetime? = nil, callbackFactory: SwiftClosureBodyFactory? = nil,
         _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) async -> Bool) {
        self.callbackFactory = callbackFactory
        self.codeOwner = SwiftClosureCodeOwner(codeOwner, codeLifetime: codeLifetime)
        self.inheritsCallerIsolation = inheritsCallerIsolation
        self.invoke = { arguments, result, error in
            await SwiftValueCodeLifetime.withCurrent(codeLifetime) { await invoke(arguments, result, error) }
        }
    }
}

final class SwiftAsyncClosureInvocation: @unchecked Sendable {
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

func retainedValue<Body>(_ operation: Body) -> ABISwiftClosureValue {
    withUnsafeBytes(of: operation) { bytes in
        let value = bytes.load(as: ABISwiftClosureValue.self)
        ABIRetainSwiftClosureContext(value.context)
        return value
    }
}

final class SwiftAsyncClosureContext {
    let entry: SwiftAsyncClosureCallbackOwner
    let body: SwiftAsyncClosureBody
    var handle: OpaquePointer { entry.handle }
    init(interface: SwiftAsyncCallInterface, body: SwiftAsyncClosureBody) throws {
        entry = try interface.closureEntry()
        self.body = body
    }

    func value(discriminator: UInt16) -> ABISwiftClosureValue {
        ABISwiftClosureValue(
            function: ABISignSwiftAsyncClosureDescriptor(ABISwiftAsyncClosureCallbackDescriptor(handle), discriminator),
            context: Unmanaged.passUnretained(self).toOpaque())
    }

    func storage(discriminator: UInt16, codeLifetime: SwiftValueCodeLifetime? = nil) throws -> SwiftAsyncClosureStorage {
        let value = value(discriminator: discriminator)
        ABIRetainSwiftClosureContext(value.context)
        return try SwiftAsyncClosureStorage(adopting: value, discriminator: discriminator, retaining: nil,
            codeLifetime: codeLifetime, entry: entry.entry)
    }
}

final class SwiftAsyncClosureCallbackOwner: @unchecked Sendable {
    let handle: OpaquePointer
    let entry: SwiftAsyncEntry
    init(handle: OpaquePointer) throws {
        self.handle = handle
        do { entry = try SwiftAsyncEntry(descriptor: ABISwiftAsyncClosureCallbackDescriptor(handle)!) }
        catch { ABIReleaseSwiftAsyncClosureCallback(handle); throw error }
    }
    convenience init(interface: SwiftAsyncCallInterface) throws {
        var functions = ABISwiftAsyncClosureCallbackFunctions()
        functions.usesNativeContext = true
        functions.createBody = { context, arguments, result, error, didThrow in
            let body = Unmanaged<SwiftAsyncClosureContext>.fromOpaque(context!).takeUnretainedValue().body
            let invocation = SwiftAsyncClosureInvocation(body, arguments, result!, error, didThrow!)
            if body.inheritsCallerIsolation {
                let operation: (nonisolated(nonsending) @Sendable () async -> Void) = { await invocation.run() }
                return retainedValue(operation)
            }
            let operation: @Sendable @concurrent () async -> Void = { await invocation.run() }
            return retainedValue(operation)
        }
        functions.copyCodeOwner = { context in
            let owner = Unmanaged<SwiftAsyncClosureContext>.fromOpaque(context!).takeUnretainedValue().body.codeOwner
            return owner.map { Unmanaged.passRetained($0).toOpaque() }
        }
        functions.copyBodyOwner = { context in
            let factory = Unmanaged<SwiftAsyncClosureContext>.fromOpaque(context!).takeUnretainedValue().body.callbackFactory
            return factory.map { Unmanaged.passRetained($0).toOpaque() }
        }
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftAsyncClosureCallback(interface.handle, functions, nil, &failure) else {
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
        }
        try self.init(handle: handle)
    }
    deinit { ABIReleaseSwiftAsyncClosureCallback(handle) }
}

extension NativeSwiftClosure {
    func encodeGenericAsyncClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage {
        if plan.isEscaping, case .borrowed = call {
            return try copy().encodeGenericClosure(plan: plan, retainingCode: owner)
        }
        if case .host(let host) = call {
            return try host.factory.encode(plan: plan, retainingCode: owner, codeLifetime: host.codeLifetime)
        }
        guard case .asynchronous(let interface, let isolation) = plan.transport,
              case .asynchronous(let original, let prepared) = try call.resolved() else {
            preconditionFailure("The prepared callback and its formal transport must agree.")
        }
        if let native = prepared.closure {
            try native.validateNativeValues(for: plan)
            if native.hasSameNativeABI(as: plan) { return original.encoded() }
        }
        if let factory = original.callbackFactory, factory.signature == Signature.self {
            return try factory.encode(plan: plan, retainingCode: (original.codeOwner, owner),
                codeLifetime: original.codeLifetime)
        }
        if plan.hasNestedClosures || prepared.closure?.hasNestedClosures == true {
            let source = try prepared.closure ?? SwiftGenericClosurePlan.concrete(Signature.self)
            let adapter = try SwiftNativeClosureAdapter(source: source, target: plan)
            return adapter.encode(original.value, taking: false, escaping: false, retainingValue: original,
                retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime)
        }
        if let native = prepared.closure { try native.validateNativeValues(for: plan) }
        else { try plan.validateCallbackConversion() }
        let callback = try SwiftAsyncClosureContext(interface: interface,
            body: SwiftAsyncClosureBody(inheritsCallerIsolation: isolation,
                retainingCode: (original.codeOwner, owner), codeLifetime: original.codeLifetime) { arguments, result, error in
                let decoded = prepared.closure == nil ? plan.decodeArguments(arguments) : nil
                let native = prepared.closure.map { $0.parameters.encode(plan.parameters.unpack(arguments)) }
                let unpacked = (native?.addresses ?? decoded?.addresses).map {
                    SwiftGenericArgumentBuffer($0.map { UInt(bitPattern: $0) })
                }
                let forwarded: UnsafePointer<UnsafeMutableRawPointer?>? = unpacked.map {
                    UnsafeRawPointer(bitPattern: $0.address)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                } ?? arguments
                let unusedError = plan.errorPlan == nil ? prepared.errorPlan?.makeStorage() : nil
                let convertedResult = prepared.closure == nil ? plan.makeCallbackResultStorage() : nil
                let invocation = ABICreateSwiftAsyncInvocation(prepared.interface.handle, original.entry.function,
                    original.entry.contextSize, convertedResult?.address ?? result, forwarded, original.value.context, error ?? unusedError?.address, nil)
                precondition(invocation != nil, "The prepared async closure reabstraction must be valid.")
                defer { withExtendedLifetime((original, decoded, native, unpacked, unusedError)) { ABIReleaseSwiftAsyncInvocation(invocation!) } }
                await invokeSwiftAsync(invocation!)
                let didThrow = ABISwiftAsyncInvocationDidThrow(invocation!)
                return didThrow || plan.encodeCallbackResult(convertedResult, to: result, errorOutput: error)
            })
        return try callback.storage(discriminator: plan.discriminator, codeLifetime: original.codeLifetime).encoded()
    }

    /// Creates an async callback that preserves the native caller's task and isolation.
    /// The Sendable body may escape and be called concurrently. Native code receives its declared errors.
    /// Native entry preparation occurs on the first invocation or publication.
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result
    ) throws where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try self.init(asyncBody: body)
    }

    @_disfavoredOverload
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result
    ) throws where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try self.init(asyncBody: body)
    }

    /// Creates an async callback using the concurrent convention, without a caller-isolation prefix.
    @_disfavoredOverload
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result
    ) throws where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try self.init(asyncBody: body)
    }

    @_disfavoredOverload
    public init<Result, Failure: Error, each Argument>(
        _ body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result
    ) throws where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try self.init(asyncBody: body)
    }

    private init<Result, Failure: Error, each Argument>(
        asyncBody body: @escaping @Sendable (repeat each Argument) async throws(Failure) -> Result
    ) throws {
        let signature = try SwiftFunctionSignature(Signature.self)
        let codeLifetime = SwiftValueCodeLifetime([])
        let factory = SwiftClosureBodyFactory(signature: Signature.self, asynchronous: { plan, factory, owner in
            let inputs = try SwiftCallbackValues(signature, arguments: plan?.parameters.arguments ?? [])
            let output = try SwiftCallbackResult<Result>(failure: Failure.self, generic: plan?.result ?? .concrete)
            return SwiftAsyncClosureBody(inheritsCallerIsolation: signature.inheritsCallerIsolation,
                retainingCode: owner, codeLifetime: codeLifetime, callbackFactory: factory) { native, result, errorOutput in
                let unpacked = plan?.parameters.hasPacks == true
                    ? SwiftGenericArgumentBuffer(plan!.parameters.unpack(native).map { UInt(bitPattern: $0) }) : nil
                let arguments = unpacked.map {
                    UnsafeRawPointer(bitPattern: $0.address)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                } ?? native
                let scope = inputs.makeScope(asynchronous: true)
                defer { withExtendedLifetime((scope, unpacked)) {} }
                var index = 0
                func decode<Value>(_ type: Value.Type) -> Value {
                    defer { index += 1 }
                    return inputs.decode(arguments![index]!, at: index, scope: scope, as: type)
                }
                let values = (repeat decode((each Argument).self))
                do {
                    let value = try await body(repeat each values)
                    let convertedResult = plan?.makeCallbackResultStorage()
                    try output.initialize(value, at: convertedResult?.address ?? result)
                    return plan?.encodeCallbackResult(convertedResult, to: result, errorOutput: errorOutput) ?? false
                } catch {
                    errorOutput!.initializeMemory(as: Failure.self, repeating: error as! Failure, count: 1)
                    return true
                }
            }
        })
        call = .host(SwiftClosureHost(factory: factory, codeLifetime: codeLifetime) {
            let discriminator = try signature.closureDiscriminator()
            let prepared = try SwiftAsyncCall(signature: Signature.self, errorPlan: signature.makeErrorPlan(),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            let canonicalBody = try factory.asynchronous(plan: nil, retainingCode: nil)
            let context = try SwiftAsyncClosureContext(interface: prepared.interface, body: canonicalBody)
            return .asynchronous(try context.storage(discriminator: discriminator), prepared)
        })
    }

    static func makeAsyncClosureCodec(signature: SwiftFunctionSignature, generic: SwiftGenericClosurePlan? = nil) throws -> SwiftClosureCodec {
        let discriminator = try generic?.discriminator ?? signature.closureDiscriminator()
        let prepared = try SwiftAsyncCall(signature: Signature.self,
            errorPlan: generic == nil ? signature.makeErrorPlan() : generic?.errorPlan,
            inheritsCallerIsolation: signature.inheritsCallerIsolation, closure: generic)
        let interface: SwiftAsyncCallInterface
        if let generic {
            guard case .asynchronous(let original, _) = generic.transport else {
                preconditionFailure("The prepared closure effects must agree.")
            }
            interface = original
        } else { interface = prepared.interface }
        let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any = { value, owner, taking, codeLifetime in
            if !taking { ABIRetainSwiftClosureContext(value.context) }
            let original = try SwiftAsyncClosureStorage(adopting: value, discriminator: discriminator,
                retaining: owner, codeLifetime: codeLifetime)
            if ABIIsSwiftAsyncClosureCallbackFunction(original.entry.function) {
                return Self(call: .asynchronous(original, prepared))
            }
            let callback = try SwiftAsyncClosureContext(interface: prepared.interface,
                body: SwiftAsyncClosureBody(inheritsCallerIsolation: signature.inheritsCallerIsolation,
                    retainingCode: original.codeOwner, codeLifetime: original.codeLifetime) { arguments, result, error in
                    func prepare(_ arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> OpaquePointer? {
                        ABICreateSwiftAsyncInvocation(interface.handle, original.entry.function,
                            original.entry.contextSize, result, arguments, original.value.context, error, nil)
                    }
                    let invocation = prepare(arguments)
                    precondition(invocation != nil, "The prepared async closure forwarding call must be valid.")
                    defer { withExtendedLifetime(original) { ABIReleaseSwiftAsyncInvocation(invocation!) } }
                    await invokeSwiftAsync(invocation!)
                    return ABISwiftAsyncInvocationDidThrow(invocation!)
                })
            return Self(call: .asynchronous(try callback.storage(discriminator: discriminator,
                codeLifetime: original.codeLifetime), prepared))
        }
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer]), nativeValueTypes: generic?.nativeValueTypes ?? [], nativePlan: generic,
            encoding: { value, owner in try (value as! Self).encodeClosureResult(generic: generic, retainingCode: owner) }, borrowing: { borrow, lifetime in
            Self(call: .borrowed(resolve: { asynchronous in
                let access = try borrow.access(asynchronous: asynchronous, codeLifetime: lifetime)
                let value = access.address.load(as: ABISwiftClosureValue.self)
                let storage = try SwiftAsyncClosureStorage(adopting: value, discriminator: discriminator,
                    retaining: access, codeLifetime: lifetime, ownsContext: false)
                return .asynchronous(storage, prepared)
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

    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Awaits the native closure on the original task. Native failures use NativeSwiftError.
    /// The caller satisfies the native signature's ABI, ownership, and actor/thread requirements.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    /// Awaits a native closure using the concurrent convention and resumes on the caller's executor.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(_ values: repeat each Argument) async throws -> Result {
        guard case .asynchronous(let storage, let prepared) = try call.resolved(asynchronous: true) else { preconditionFailure("An async closure has an async call plan.") }
        return try unsafe await prepared.unsafeInvoke(entry: storage.entry,
            context: storage.value.context.map { UnsafeRawPointer($0) }, retaining: storage,
            retainingCode: storage.codeOwner, repeat each values)
    }
}
