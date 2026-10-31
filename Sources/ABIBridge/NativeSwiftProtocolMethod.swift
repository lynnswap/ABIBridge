import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime
import Foundation

/// One synchronous instance method implemented by a host callback.
///
/// Name the requirement with its argument labels, such as `receive(_:)`. The
/// parameter types describe the host representation of its native arguments;
/// use the same value and ownership wrappers as native Swift callbacks.
///
/// The escaping Sendable body runs synchronously on the native caller's thread,
/// including concurrent calls. It performs no actor hop. The native object owns
/// its captures until final release, including callbacks already in progress.
public struct NativeSwiftProtocolMethod {
    let name: String
    let consumesReceiver: Bool
    let factory: SwiftClosureBodyFactory
    let errorErasedFactory: SwiftClosureBodyFactory

    /// Implements a Void-returning requirement with a typed host callback.
    ///
    /// Receiver ownership must match the native declaration. Ordinary methods
    /// borrow self; pass receiver: .consuming for a consuming requirement.
    /// Swift symbols and protocol descriptors do not encode that convention.
    public init<Failure: Error, each Argument>(
        _ name: String,
        receiver convention: NativeSwiftReceiverConvention = .borrowing,
        _ body: @escaping @Sendable (repeat each Argument) throws(Failure) -> Void
    ) throws {
        guard convention != .mutating else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A class-bound protocol method cannot have an inout receiver."
            )
        }
        consumesReceiver = convention == .consuming
        let callback = try NativeSwiftClosure<(repeat each Argument) throws(Failure) -> Void>(body)
        guard case .host(let host) = callback.call else {
            preconditionFailure("A newly created host callback has a body factory.")
        }
        self.name = name
        factory = host.factory
        if Failure.self == (any Error).self {
            errorErasedFactory = host.factory
        } else {
            let erased = try NativeSwiftClosure<(repeat each Argument) throws -> Void> {
                (arguments: repeat each Argument) throws in
                try body(repeat each arguments)
            }
            guard case .host(let erasedHost) = erased.call else {
                preconditionFailure("A newly created host callback has a body factory.")
            }
            errorErasedFactory = erasedHost.factory
        }
    }
}

extension ABIRuntime {
    /// Creates a native class-bound Swift protocol value from host callbacks.
    ///
    /// The protocol must have no associated types or generic requirements. Its
    /// requirements must be synchronous instance methods returning Void, including
    /// throwing methods and Self parameters. Protocol inheritance is unsupported.
    /// Every requirement must have exactly one implementation.
    ///
    /// Lookup and formal call planning run on a worker. Callback capture binding,
    /// runtime registration and instance creation stay in the caller's isolation
    /// domain. Bodies run on the native caller's thread without an actor hop.
    /// Supply `valueABIs` for
    /// closed nominal argument types whose calling convention cannot be inferred.
    ///
    /// The result contains the actual protocol existential and can be retained,
    /// copied, dynamically cast and reboxed by separately compiled native code.
    /// Native ARC owns the callbacks. Pass an independent `copy()` to a consuming
    /// setter when retaining this handle for a weak delegate.
    ///
    /// Runtime conformance registration cannot be undone. Successfully registered
    /// classes, metadata, witness code and implementation images remain alive for
    /// the process; registrations retain no instance callbacks or captures.
    public nonisolated(nonsending) func makeSwiftProtocolValue(
        _ protocolName: String,
        methods: [NativeSwiftProtocolMethod],
        in selector: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftValue {
        let signatures = methods.map {
            SwiftProtocolMethodSignature(
                name: $0.name,
                type: $0.factory.signature,
                errorErasedType: $0.errorErasedFactory.signature
            )
        }
        let prepared = try await NativePreparation.run {
            try SwiftProtocolValuePreparation(
                protocolName,
                methods: signatures,
                resolver: self.resolver,
                selector: selector,
                loading: loading,
                valueABIs: valueABIs
            )
        }
        return try prepared.makeValue(methods: methods)
    }

    /// Creates a protocol value synchronously, waiting for lookup and ABI preparation.
    ///
    /// This has the same requirement, isolation and lifetime contracts as
    /// `makeSwiftProtocolValue(_:methods:in:loading:valueABIs:)`.
    public nonisolated func makeSwiftProtocolValueAndWait(
        _ protocolName: String,
        methods: [NativeSwiftProtocolMethod],
        in selector: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftValue {
        let signatures = methods.map {
            SwiftProtocolMethodSignature(
                name: $0.name,
                type: $0.factory.signature,
                errorErasedType: $0.errorErasedFactory.signature
            )
        }
        return try SwiftProtocolValuePreparation(
            protocolName,
            methods: signatures,
            resolver: resolver,
            selector: selector,
            loading: loading,
            valueABIs: valueABIs
        ).makeValue(methods: methods)
    }
}

private struct SwiftProtocolMethodSignature: Sendable {
    let name: String
    let type: Any.Type
    let errorErasedType: Any.Type

    func matches(_ declaration: String) -> Bool {
        guard let requested = SwiftMemberPath(declaration: name),
            let native = SwiftMemberPath(declaration: declaration),
            requested.member == native.member,
            requested.owner.isEmpty || requested.owner == native.owner
        else { return false }
        return !SwiftMemberLookup.hasSignature(name)
            || SwiftMemberLookup.signatureKey(name) == SwiftMemberLookup.signatureKey(declaration)
    }
}

/// Prepared formal conversions contain code and type owners, never host captures.
private struct SwiftProtocolValuePreparation: Sendable {
    let descriptor: RuntimeSwiftProtocolDescriptor
    let codeLifetime: SwiftValueCodeLifetime
    let resolver: SymbolResolver
    let nativeClass: RuntimeSwiftProtocolClass
    let plans: [SwiftGenericClosurePlan]
    let methodIndices: [Int]

    init(
        _ name: String,
        methods: [SwiftProtocolMethodSignature],
        resolver: SymbolResolver,
        selector: ImageSelector,
        loading: ImageLoadingPolicy,
        valueABIs: [NativeSwiftType: NativeType]
    ) throws {
        self.resolver = resolver
        let symbol = try resolver.resolve(
            NativeDeclaration(
                name: "protocol descriptor for " + name,
                language: .swift,
                kind: .data
            ),
            in: selector,
            loading: loading
        )
        let descriptor = try withRuntimeErrors {
            try RuntimeSwiftProtocolDescriptor.cached(
                symbol: symbol.runtimeValue,
                resolver: resolver.runtime
            )
        }
        self.descriptor = descriptor
        codeLifetime = SwiftValueCodeLifetime([symbol.image])
        let declarations = try descriptor.requirements.map { requirement in
            let declaration = try SwiftGenericDeclaration(linkageName: requirement.identity)
            guard declaration.parameters.count == 1,
                declaration.parameters[0].name == "A",
                !declaration.parameters[0].isPack,
                declaration.result == .tuple([]), !declaration.isAsync
            else {
                throw ABIResolutionError.unsupportedDeclaration(
                    requirement.name
                        + ": protocol values require nongeneric, synchronous Void methods."
                )
            }
            return declaration
        }
        nativeClass = try withRuntimeErrors {
            try RuntimeSwiftProtocolClass.prepare(descriptor: descriptor)
        }
        let nativeClassType = NativeSwiftType(
            name: String(reflecting: nativeClass.metadata),
            image: symbol.image,
            metadata: nativeClass.metadata,
            representation: nil,
            resolver: resolver
        )
        var prepared: [SwiftGenericClosurePlan] = []
        var indices: [Int] = []
        var used: Set<Int> = []
        for (requirement, original) in zip(descriptor.requirements, declarations) {
            // The class constraint preserves direct object lowering for Self.
            // Conformance is published only after every method and body binds.
            let declaration = SwiftGenericDeclaration(
                parameters: [.init(name: "A", isPack: false)],
                requirements: [.conformance(.named("A", []), "Swift.AnyObject")],
                arguments: original.arguments,
                result: original.result,
                failure: original.failure,
                isAsync: false,
                consumesArguments: false
            )
            let candidates = methods.indices.filter { methods[$0].matches(requirement.name) }
            var matches: [(Int, SwiftGenericClosurePlan, [NativeImage])] = []
            var mismatch: (any Error)?
            for index in candidates {
                do {
                    let erasesError =
                        original.failure.map { ["Error", "Swift.Error"].contains($0.spelling) }
                        ?? false
                    var signature = try SwiftFunctionSignature(
                        erasesError ? methods[index].errorErasedType : methods[index].type
                    )
                    let binding = try SwiftGenericBinding(
                        declaration: declaration,
                        arguments: [.type(nativeClassType)],
                        signature: signature,
                        resolver: resolver,
                        image: symbol.image,
                        valueABIs: valueABIs
                    )
                    // A nonthrowing implementation satisfies a throwing requirement.
                    // Its body never writes an error; the entry still has the native
                    // requirement's complete error-result calling convention.
                    if signature.failure == Never.self, let failure = declaration.failure {
                        let nativeFailure =
                            try ["Error", "Swift.Error"].contains(failure.spelling)
                            ? (any Error).self : binding.types(failure)[0]
                        signature = try SwiftFunctionSignature(
                            SwiftGenericBinding.functionType(
                                parameters: signature.parameters,
                                parameterFlags: Array(
                                    repeating: 0,
                                    count: signature.parameters.count
                                ),
                                result: signature.result,
                                failure: nativeFailure,
                                attributes: signature.attributes,
                                globalActor: signature.globalActor
                            )
                        )
                    }
                    let formal = SwiftFormalType.function(
                        declaration.arguments,
                        declaration.result,
                        failure: declaration.failure,
                        attributes: .init()
                    )
                    let plan = try SwiftGenericCallPlan.closure(
                        formal,
                        signature: signature,
                        binding: binding
                    )
                    try plan.validateCallbackConversion()
                    matches.append(
                        (
                            index, plan,
                            binding.images + binding.typeOwners.flatMap { $0.codeLifetime.images }
                        )
                    )
                } catch { mismatch = error }
            }
            guard matches.count == 1, let match = matches.first else {
                if matches.isEmpty, let mismatch {
                    if case ABIResolutionError.signatureMismatch(let details) = mismatch {
                        throw ABIResolutionError.signatureMismatch(
                            details.inContext(
                                NativeDeclaration(name: requirement.name, language: .swift),
                                at: details.position
                            )
                        )
                    }
                    if case ABIResolutionError.unsupportedDeclaration(let reason) = mismatch {
                        throw ABIResolutionError.unsupportedDeclaration(
                            requirement.name + ": " + reason
                        )
                    }
                    if case ABIResolutionError.metadataUnavailable(let reason) = mismatch {
                        throw ABIResolutionError.metadataUnavailable(
                            requirement.name + ": " + reason
                        )
                    }
                    throw mismatch
                }
                throw ABIResolutionError.unsupportedDeclaration(
                    requirement.name
                        + (matches.isEmpty
                            ? ": missing protocol method implementation."
                            : ": more than one implementation matches this requirement.")
                )
            }
            guard used.insert(match.0).inserted else {
                throw ABIResolutionError.unsupportedDeclaration(
                    methods[match.0].name
                        + ": this implementation matches multiple requirements; use a complete declaration name to select one."
                )
            }
            SwiftValueCodeLifetime.connect([codeLifetime], retaining: match.2)
            indices.append(match.0)
            prepared.append(match.1)
        }
        guard used.count == methods.count else {
            let unused = methods.indices.filter { !used.contains($0) }.map { methods[$0].name }
            throw ABIResolutionError.unsupportedDeclaration(
                "These implementations do not name protocol requirements: "
                    + unused.joined(separator: ", ")
            )
        }
        plans = prepared
        methodIndices = indices
    }

    func makeValue(methods: [NativeSwiftProtocolMethod]) throws -> NativeSwiftValue {
        // Bind every capture before the irreversible runtime publication.
        let bodies = try zip(plans, methodIndices).map { plan, index in
            let method = methods[index]
            let factory =
                plan.errorPlan?.isTyped == false ? method.errorErasedFactory : method.factory
            return try factory.synchronous(plan: plan, retainingCode: codeLifetime)
        }
        let witnesses = zip(plans, methodIndices).map {
            plan,
            index -> RuntimeSwiftProtocolWitness in
            guard case .synchronous(let interface) = plan.transport else {
                preconditionFailure("A synchronous protocol method has a synchronous plan.")
            }
            return RuntimeSwiftProtocolWitness(
                interface: interface.runtime,
                consumesReceiver: methods[index].consumesReceiver
            )
        }
        let registration = try withRuntimeErrors {
            try nativeClass.register(
                witnesses: witnesses,
                retaining: codeLifetime.images.map(\.runtimeValue)
            )
        }
        let type = NativeSwiftType(
            name: String(reflecting: registration.metadata),
            image: NativeImage(descriptor.symbol.image),
            metadata: registration.metadata,
            representation: nil,
            resolver: resolver,
            codeLifetime: codeLifetime
        )
        let context = SwiftProtocolInstance(bodies: bodies)
        let retained = Unmanaged.passRetained(context)
        var failure: OpaquePointer?
        guard
            let pointer = ABICreateSwiftProtocolInstance(
                registration.handle,
                retained.toOpaque(),
                { context, slot, arguments, result, error in
                    let instance = Unmanaged<SwiftProtocolInstance>.fromOpaque(context!).retain()
                        .takeRetainedValue()
                    return withExtendedLifetime(instance) {
                        instance.bodies[slot].invoke(arguments, result!, error)
                    }
                },
                { Unmanaged<SwiftProtocolInstance>.fromOpaque($0!).release() },
                &failure
            )
        else {
            retained.release()
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftProtocol")
        }
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        // Let Swift construct the existential via runtime conformance lookup.
        func store<Value>(_ valueType: Value.Type) throws -> NativeSwiftValue {
            guard let value = object as? Value else {
                throw ABIResolutionError.metadataUnavailable(
                    "The registered native object did not conform to " + type.name
                )
            }
            let metadata = unsafeBitCast(valueType, to: UnsafeRawPointer.self)
            let layout = ABISwiftGetValueLayout(metadata)
            let storage = NativeValueStorage(
                size: layout.stride,
                alignment: layout.alignment,
                owner: type,
                codeLifetime: type.codeLifetime
            )
            storage.address.initializeMemory(as: Value.self, repeating: value, count: 1)
            storage.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
            return NativeSwiftValue(storage: storage, type: type)
        }
        return try _openExistential(type.metadata, do: store)
    }
}

private final class SwiftProtocolInstance {
    let bodies: [SwiftThrowingClosureBody]
    init(bodies: [SwiftThrowingClosureBody]) { self.bodies = bodies }
}
