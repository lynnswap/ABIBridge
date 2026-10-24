import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import ObjectiveC
import Synchronization

enum SwiftTypeCacheKey: Hashable, Sendable {
    case declaration(
        name: String,
        image: NativeImageIdentity,
        representation: ObjectIdentifier?,
        arguments: [NativeSwiftGenericArgument.Identity]
    )
    case metadata(ObjectIdentifier, image: NativeImageIdentity)
}

final class SwiftTypeCache: Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var types: [SwiftTypeCacheKey: NativeSwiftType] = [:]
    }
    private let state = Mutex(State())

    var revision: UInt64 { state.withLock { $0.revision } }

    func value(
        for key: SwiftTypeCacheKey,
        retaining arguments: [NativeSwiftGenericArgument]? = nil
    ) -> NativeSwiftType? {
        state.withLock { state in
            guard let cached = state.types[key], retainsOwners(cached, of: arguments) else {
                return nil
            }
            return cached
        }
    }

    func insert(
        _ type: NativeSwiftType,
        for key: SwiftTypeCacheKey,
        revision: UInt64,
        retaining arguments: [NativeSwiftGenericArgument]? = nil
    ) -> NativeSwiftType {
        let (result, displaced) = state.withLock { state in
            if let cached = state.types[key], retainsOwners(cached, of: arguments) {
                return (cached, nil as NativeSwiftType?)
            }
            guard state.revision == revision else { return (type, nil) }
            return (type, state.types.updateValue(type, forKey: key))
        }
        withExtendedLifetime(displaced) {}
        return result
    }

    func removeCachedResults() {
        let removed = state.withLock { state in
            state.revision &+= 1
            let removed = state.types
            state.types = [:]
            return removed
        }
        // Type destruction can release loader references and reenter lookup.
        withExtendedLifetime(removed) {}
    }

    private func retainsOwners(
        _ type: NativeSwiftType,
        of arguments: [NativeSwiftGenericArgument]?
    ) -> Bool {
        guard let arguments else { return true }
        return zip(type.genericMetadata?.arguments ?? [], arguments)
            .allSatisfy { $0.retainsOwners(of: $1) }
    }
}

struct SwiftMetadataResponse: BitwiseCopyable, ABIBridgeValue {
    let address: UInt
    let state: UInt
    static let abiType = try! NativeType.structure(
        named: "Swift.MetadataResponse",
        fields: [.uint, .uint]
    )
    init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

/// A concrete Swift type and its retained implementation images.
///
/// Type lookup requests complete metadata without constructing an instance. Generic arguments are validated by the Swift runtime. Member lookups reuse the image's existing symbol index. See <doc:SwiftMemberInvocation> for lookup and invocation conventions.
///
/// Protocol-qualified names, such as `Module.Protocol.member()` or a complete `(extension in Module):Module.Protocol.member() -> ...` declaration, bind Self to this concrete type for methods, accessors, subscripts, static members, and initializers. A requirement runs through the protocol's dispatch thunk or the witness of this type's conformance, never an extension member. genericArguments supplies only the type parameters introduced by the member.
public actor NativeSwiftType: Hashable {
    /// Type handles compare by their concrete Swift metadata identity.
    public nonisolated static func == (lhs: NativeSwiftType, rhs: NativeSwiftType) -> Bool {
        lhs.metadata == rhs.metadata
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(metadata))
    }

    /// Creates an owned value for a case without associated values.
    ///
    /// Case names must match one entry in this enum's runtime field metadata. The enum must be Escapable; it need not be Copyable. Construction uses the enum's value witnesses on the caller's thread without symbol lookup or call preparation. The returned value retains this type and its implementation images through destruction.
    ///
    /// - Parameter caseName: The unqualified case name, without argument labels or backticks.
    /// - Returns: A newly initialized value with this concrete enum type.
    /// - Throws: `NativeSwiftValueError` for an unknown or ambiguous name or a case requiring a payload; `ABIResolutionError` for an unsupported type or unavailable metadata.
    public nonisolated func makeEnumCase(named caseName: String) throws -> NativeSwiftValue {
        let enumeration = try withRuntimeErrors { try RuntimeEnumMetadata(metadata) }
        let index = try enumeration.caseIndex(named: caseName)
        guard !enumeration.cases[index].hasPayload else {
            throw NativeSwiftValueError.enumCaseRequiresPayload(name: caseName)
        }
        guard SwiftEscapability.accepts(metadata) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An owned runtime value requires an Escapable native type."
            )
        }
        try validateSwiftRuntimeValueStorage(metadata)
        let nativeMetadata = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(nativeMetadata)
        let storage = NativeValueStorage(
            size: layout.stride,
            alignment: layout.alignment,
            owner: self,
            codeLifetime: codeLifetime
        )
        try withRuntimeErrors {
            try enumeration.initializeEmptyCase(at: index, in: storage.address)
        }
        storage.assumeInitialized { ABISwiftDestroyValue(nativeMetadata, $0) }
        return NativeSwiftValue(storage: storage, type: self)
    }

    /// Creates an owned enum value by copying the case's entire associated payload.
    ///
    /// The payload's concrete type must exactly match the case's runtime payload metadata. Multiple associated values use their native tuple payload. The payload must be Copyable, and the enum must be Escapable; the enum need not be Copyable. The original payload is neither modified nor consumed. Direct and indirect cases retain independent ownership of the copied payload and its implementation images.
    ///
    /// Required closure ABI preparation runs away from the caller's executor. Copying and binding captured contexts run on the caller's executor. Function values are adapted from owned runtime storage to the case's native convention. Supply `valueABIs` for closed nominal types in their parameters or results whose ABI cannot be inferred from runtime metadata.
    ///
    /// - Parameters:
    ///   - caseName: The unique unqualified case name, without argument labels or backticks.
    ///   - payload: An owned value with the case's complete native payload type.
    ///   - valueABIs: Explicit calling conventions for closed nominal types used by payload closures.
    /// - Throws: `NativeSwiftValueError` for an unknown or ambiguous case name, a consumed or inaccessible payload, or a noncopyable payload; `ABIInvocationError` for a mismatched payload type; `ABIResolutionError` for a case without a payload or unsupported metadata.
    public nonisolated(nonsending) func makeEnumCase(
        named caseName: String,
        payload: NativeSwiftValue,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftValue {
        let payloadType = payload.type
        let prepared = try await NativePreparation.run {
            try self.prepareEnumCase(
                named: caseName,
                payloadType: payloadType,
                valueABIs: valueABIs
            )
        }
        return try initializeEnumCase(payload: payload, prepared: prepared, valueABIs: valueABIs)
    }

    /// Creates an owned enum value synchronously on the caller's thread.
    ///
    /// This has the same payload and ownership contract as `makeEnumCase(named:payload:valueABIs:)`. It performs or joins required ABI preparation before returning, which can block the caller's thread.
    public nonisolated func makeEnumCaseAndWait(
        named caseName: String,
        payload: NativeSwiftValue,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftValue {
        let prepared = try prepareEnumCase(
            named: caseName,
            payloadType: payload.type,
            valueABIs: valueABIs
        )
        return try initializeEnumCase(payload: payload, prepared: prepared, valueABIs: valueABIs)
    }

    private nonisolated func prepareEnumCase(
        named caseName: String,
        payloadType: NativeSwiftType,
        valueABIs: [NativeSwiftType: NativeType]
    ) throws -> (Int, SwiftRuntimeValueProjectionPlan) {
        let enumeration = try withRuntimeErrors { try RuntimeEnumMetadata(metadata) }
        let index = try enumeration.caseIndex(named: caseName)
        guard SwiftCopyability.accepts(payloadType.metadata) else {
            throw NativeSwiftValueError.noncopyableType
        }
        guard let expected = try withRuntimeErrors({ try enumeration.payloadType(at: index) })
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "The enum case '\(caseName)' has no associated payload."
            )
        }
        guard expected == payloadType.metadata else {
            throw ABIInvocationError.incompatibleValue(
                expected: String(reflecting: expected),
                actual: payloadType.name
            )
        }
        guard SwiftEscapability.accepts(metadata) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An owned runtime value requires an Escapable native type."
            )
        }
        try validateSwiftRuntimeValueStorage(metadata)
        try validateSwiftRuntimeValueStorage(expected)
        return (
            index,
            try SwiftRuntimeValueProjectionPlan(
                enumType: self,
                caseIndex: index,
                payload: expected,
                valueABIs: valueABIs
            )
        )
    }

    private nonisolated func initializeEnumCase(
        payload: NativeSwiftValue,
        prepared: (Int, SwiftRuntimeValueProjectionPlan),
        valueABIs: [NativeSwiftType: NativeType]
    ) throws -> NativeSwiftValue {
        let source = try payload.access(.borrowing)
        let lifetime = SwiftValueCodeLifetime.connect(
            [codeLifetime, payload.type.codeLifetime]
                + valueABIs.keys.map(\.codeLifetime)
                + (source.codeLifetime.map { [$0] } ?? []),
            retaining: []
        )!
        let nativeMetadata = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let payloadMetadata = unsafeBitCast(payload.type.metadata, to: UnsafeRawPointer.self)
        let payloadLayout = ABISwiftGetValueLayout(payloadMetadata)
        let scratch = NativeValueStorage(
            size: payloadLayout.stride,
            alignment: payloadLayout.alignment,
            owner: payload.type,
            codeLifetime: lifetime
        )
        withExtendedLifetime(source) {
            ABISwiftCopyValue(payloadMetadata, scratch.address, source.address)
        }
        scratch.assumeInitialized { ABISwiftDestroyValue(payloadMetadata, $0) }
        prepared.1.apply(to: scratch, native: true)
        let layout = ABISwiftGetValueLayout(nativeMetadata)
        let storage = NativeValueStorage(
            size: layout.stride,
            alignment: layout.alignment,
            owner: self,
            codeLifetime: lifetime
        )
        let enumeration = try withRuntimeErrors { try RuntimeEnumMetadata(metadata) }
        try withRuntimeErrors {
            try enumeration.initializeCase(
                at: prepared.0,
                in: storage.address,
                taking: scratch.address,
                payloadType: payload.type.metadata
            )
        }
        scratch.relinquishValue()
        storage.assumeInitialized { ABISwiftDestroyValue(nativeMetadata, $0) }
        storage.retainResource(scratch)
        return NativeSwiftValue(storage: storage, type: self)
    }

    /// The qualified type name. Runtime values can include instantiated generic arguments.
    public nonisolated let name: String
    /// An image retained with this type's metadata and implementations.
    public nonisolated let image: NativeImage

    let metadata: Any.Type
    let representation: Any.Type?
    let resolver: SymbolResolver
    let genericMetadata: SwiftGenericTypeMetadata?
    nonisolated let codeLifetime: SwiftValueCodeLifetime
    nonisolated var codeImages: [NativeImage] { codeLifetime.images }
    nonisolated var genericArguments: [NativeSwiftGenericArgument] {
        genericMetadata?.arguments ?? []
    }
    private nonisolated let cachedReceiver = Mutex<SwiftHostConversion?>(nil)
    private nonisolated let cachedDeclarationName = Mutex<String?>(nil)

    init(
        name: String,
        image: NativeImage,
        metadata: Any.Type,
        representation: Any.Type?,
        resolver: SymbolResolver,
        genericMetadata: SwiftGenericTypeMetadata? = nil,
        codeLifetime: SwiftValueCodeLifetime? = nil
    ) {
        self.name = name
        self.image = image
        self.metadata = metadata
        self.representation = representation
        self.resolver = resolver
        self.genericMetadata = genericMetadata
        self.codeLifetime =
            codeLifetime ?? SwiftValueCodeLifetime([image] + (genericMetadata?.images ?? []))
    }

    nonisolated func retainingCode(_ lifetime: SwiftValueCodeLifetime) -> NativeSwiftType {
        NativeSwiftType(
            name: name,
            image: image,
            metadata: metadata,
            representation: representation,
            resolver: resolver,
            genericMetadata: genericMetadata,
            codeLifetime: lifetime
        )
    }

    nonisolated func declarationName() throws -> String {
        if let cached = cachedDeclarationName.withLock({ $0 }) { return cached }
        // Runtime value construction retains metadata without scanning symbols.
        // A member lookup needs the declaration's uninstantiated owner name.
        let resolved = try swiftTypeDeclarationName(
            metadata,
            in: image,
            suggestedName: name,
            resolver: resolver
        )
        return cachedDeclarationName.withLock { cached in
            if let cached { return cached }
            cached = resolved
            return resolved
        }
    }

    nonisolated func receiverPlan(
        mutating isMutating: Bool?,
        consuming isConsuming: Bool = false,
        generic: SwiftGenericCallPlan? = nil,
        receiverABI: NativeType? = nil
    ) throws -> SwiftReceiverPlan {
        let (plan, conversion) = try prepareReceiverPlan(
            mutating: isMutating,
            consuming: isConsuming,
            generic: generic,
            receiverABI: receiverABI,
            cachedReceiver: cachedReceiver.withLock { $0 }
        )
        if let conversion {
            cachedReceiver.withLock { cached in
                if cached == nil { cached = conversion }
            }
        }
        return plan
    }

    private nonisolated func prepareReceiverPlan(
        mutating isMutating: Bool?,
        consuming isConsuming: Bool,
        generic: SwiftGenericCallPlan?,
        receiverABI: NativeType?,
        cachedReceiver: SwiftHostConversion?
    ) throws -> (SwiftReceiverPlan, SwiftHostConversion?) {
        let protocolSelf = try generic.flatMap { plan in
            try plan.binding.declaration.protocolSelf.map { try plan.binding.canonicalType(of: $0) }
        }
        // A representation that is not the type itself is an adapter, whose
        // own inferred layout says nothing about the declaration's self.
        if receiverABI == nil, let representation, representation != metadata,
            SwiftInferredValue.lowersByInference(representation)
        {
            throw ABIResolutionError.metadataUnavailable(
                "ABIBridge infers the Swift calling convention of self only from \(name); its representation \(String(reflecting: representation)) is an adapter. Describe it with receiverABI or an ABIBridgeSwiftValue conformance."
            )
        }
        let conversion: SwiftHostConversion
        let cachedConversion: SwiftHostConversion?
        // The declaration's formal self, when its convention applies to a
        // representation's value.
        var formalSelf: SwiftValueSchema?
        if let receiverABI {
            let schema = SwiftValueSchema(
                storage: try SwiftValueSchema.explicitLayout(of: metadata, abi: receiverABI),
                metadata: metadata
            )
            conversion = SwiftHostConversion(native: metadata, schema: schema)
            cachedConversion = nil
        } else if (representation == nil || representation == metadata || protocolSelf != nil),
            let formal = try generic?.receiverSchema()
        {
            if let representation, representation != metadata {
                conversion = try SwiftHostConversion(host: representation, position: .receiver)
                formalSelf = formal
            } else {
                conversion = SwiftHostConversion(native: metadata, schema: formal)
            }
            cachedConversion = nil
        } else {
            conversion =
                try cachedReceiver
                ?? SwiftHostConversion(host: representation ?? metadata, position: .receiver)
            cachedConversion = conversion
        }
        if receiverABI == nil, let representation, representation != metadata,
            !(metadata is AnyClass)
        {
            try checkReceiverRepresentation(representation, formalSelf: formalSelf)
        }
        let plan = try SwiftReceiverPlan(
            conversion: conversion,
            schema: formalSelf,
            metadata: metadata,
            isMutating: isMutating,
            isConsuming: isConsuming,
            protocolSelf: protocolSelf,
            validateClass: representation != nil && representation != metadata
        )
        if receiverABI != nil, metadata is any NativeOptionalValue.Type {
            try checkOptionalReceiverABI(
                plan,
                generic: generic,
                isMutating: isMutating,
                isConsuming: isConsuming,
                protocolSelf: protocolSelf
            )
        }
        return (plan, cachedConversion)
    }

    /// Checks that `plan`, which passes an Optional self as receiverABI
    /// describes it, passes self as the declaration does.
    ///
    /// SwiftReceiverPlan decides the passing from either convention with the
    /// same flags. By address, as a generic extension's formal self or a
    /// mutating self is passed, receiverABI's storage serves, because the
    /// Optional's metadata sizes it. By value, its components must match the
    /// Optional's storage. receiverABI states the convention of other self
    /// values, and of an Optional self whose convention is not established.
    private nonisolated func checkOptionalReceiverABI(
        _ plan: SwiftReceiverPlan,
        generic: SwiftGenericCallPlan?,
        isMutating: Bool?,
        isConsuming: Bool,
        protocolSelf: SwiftFormalType?
    ) throws {
        let formalSelf: SwiftValueSchema?
        do {
            formalSelf = try generic?.receiverSchema()
        } catch {
            return
        }
        guard
            let schema = formalSelf
                ?? SwiftValueSchema.establishedOptionalStorage(of: metadata).map({
                    SwiftValueSchema(storage: $0, metadata: metadata)
                })
        else { return }
        let declared = try SwiftReceiverPlan(
            conversion: SwiftHostConversion(native: metadata, schema: schema),
            metadata: metadata,
            isMutating: isMutating,
            isConsuming: isConsuming,
            protocolSelf: protocolSelf,
            validateClass: false
        )
        func passing(_ plan: SwiftReceiverPlan) -> String {
            plan.mode == .value ? SwiftDeclaredLowering.lowering(of: plan.type) : "by address"
        }
        let passes =
            plan.mode == declared.mode
            && (plan.mode != .value
                || withExtendedLifetime((plan.type, declared.type)) {
                    ABISwiftValuePassesAs(plan.type.handle, declared.type.handle, false)
                })
        guard !passes else { return }
        throw SwiftDeclaredLowering.explicitMismatch(
            statedBy: "receiverABI",
            forOptional: metadata,
            passing: passing(plan),
            swiftPassing: passing(declared)
        )
    }

    /// Checks that a representation passes as self does.
    ///
    /// A representation is this type's adapter for self. Where the
    /// declaration's formal self applies, such as a protocol's indirect Self,
    /// the representation's storage passes by that convention. Otherwise it
    /// must pass as this type's value, and the adapter states that convention
    /// where this type's metadata does not establish it, because receiverABI
    /// describes native self values rather than a representation. A class
    /// receiver is a reference, which SwiftReceiverPlan checks.
    private nonisolated func checkReceiverRepresentation(
        _ representation: Any.Type,
        formalSelf: SwiftValueSchema?
    ) throws {
        let own = try SwiftValueSchema(host: representation, position: .receiver).type
        let host: CValueType
        let declared: CValueType
        if let formalSelf {
            declared = formalSelf.type
            host =
                withExtendedLifetime(declared, { ABISwiftValueIsIndirect(declared.handle) })
                ? try CValueType(indirectSwiftSize: own.size, alignment: own.alignment) : own
        } else if let schema = try? SwiftValueSchema(host: metadata, position: .receiver) {
            declared = schema.type
            host = own
        } else {
            return
        }
        do {
            try SwiftDeclaredLowering.check(
                representation,
                layout: host,
                as: name,
                declared: declared,
                position: .receiver
            )
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            throw ABIResolutionError.signatureMismatch(mismatch.at(.receiver))
        }
    }

    // A library-evolution class can export only the dispatch thunk and method
    // descriptor of a member. The member's code is then this type's
    // virtual-table entry: the implementation visible to this type, which
    // calls run without redispatching on the receiver.
    ///
    /// - Parameter asynchronous: The requested effect, when known. A slot
    ///   with another effect does not apply to the request.
    private nonisolated func dispatchedEntry(
        _ candidate: SwiftCandidate,
        asynchronous: Bool?
    ) throws -> SwiftEntry {
        var entry = candidate.entry
        let dispatch = try SwiftClassDispatch(
            metadata: metadata,
            entry: entry,
            resolver: resolver,
            asynchronous: asynchronous
        )
        let code = try SwiftSlotCode(
            at: dispatch.address,
            authentication: dispatch.authentication,
            asynchronous: dispatch.isAsync,
            retaining: nil
        )
        guard let implementation = code.implementation else {
            throw ABIResolutionError.invalidAddress
        }
        entry.implementation = implementation
        entry.asyncEntry = code.asyncEntry
        entry.dispatch = dispatch
        return entry
    }

    // Generic packs expand caller arguments without changing the source labels.
    // Their requests keep those labels until declaration binding determines arity.
    private typealias ResolvedMember = (
        entry: SwiftEntry, metadata: Any.Type, generic: SwiftGenericCallPlan
    )

    /// Selects a member from the candidates this type declares, then those
    /// its extensions declare, then those of each superclass in turn.
    ///
    /// A complete declaration selects the candidates it spells, and the
    /// requested types may adapt them. A label-only name selects the
    /// candidates whose native signatures accept the requested types. A name
    /// qualified by a protocol selects its requirement, or else a protocol
    /// extension member. A requirement is called through its dispatch thunk,
    /// which selects the witness of the conformance a call passes, or else
    /// through the witness of this type's conformance. An extension member
    /// never stands in for a requirement.
    ///
    /// The request's role and static-ness, and the records of each
    /// candidate, decide whether a symbol declares the member. The name
    /// supplies only its owner, base name, and argument labels, and, when
    /// complete, the spelling that selects among overloads.
    private nonisolated func resolveMember(
        _ query: SwiftMemberQuery,
        signature: Any.Type,
        genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String?,
        valueABIs: [NativeSwiftType: NativeType]
    ) throws -> ResolvedMember {
        let description = try SwiftFunctionSignature(signature)
        let isComplete = query.isComplete
        // Initializers are found in the lookup type only.
        let inherited = query.role != .initializer
        // The representation this type was resolved with stands for it.
        let representations =
            representation.flatMap { $0 == metadata ? nil : [ObjectIdentifier($0): metadata] } ?? [:]
        var originalRequest: NativeDeclaration?
        var ownerClass: AnyClass? = metadata as? AnyClass
        var ownerImage = image
        var ownerName = try declarationName()
        var hasUnavailableImages = false
        var preparationFailure: (any Error)?
        // Why a requirement that the request names has no witness for this
        // type. Extension members then never stand in for it.
        var missingWitness: (any Error)?
        // The requirements whose records selection considered, and the
        // conformances whose witnesses it saw.
        var considered: Set<String> = []
        var conformances: [UnsafeRawPointer: NativeImage] = [:]
        // This type's conformance to the protocol qualifying a request.
        var protocolConformance: SwiftConformance??
        while true {
            let owner: Any.Type = ownerClass ?? metadata
            let enclosing =
                try owner == metadata ? genericMetadata : SwiftGenericTypeMetadata(metadata: owner)
            // The member's spelling in diagnostics.
            let declaration = query.display(in: ownerName)
            if originalRequest == nil { originalRequest = declaration }
            // A name qualified by another owner than this type names a
            // protocol's member.
            let isProtocolMember =
                query.qualifier != nil
                && !SwiftMemberLookup.belongs(query.request.name, to: ownerName)
            if query.role == .initializer, query.qualifier != nil, !isProtocolMember {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Name this type's own initializer relative to the type, such as init(text:)."
                )
            }
            let match = try query.match(in: ownerName)
            let memberOwner = query.owner(in: ownerName)
            // Prepares a candidate whose context applies to the request.
            func prepare(
                _ candidate: SwiftCandidate,
                _ entry: SwiftEntry,
                ignoringOwner: Bool = false
            ) throws -> SwiftGenericCallPlan? {
                if isComplete {
                    guard query.spells(candidate, ignoringOwner: ignoringOwner) else { return nil }
                }
                let plan = try SwiftGenericCallPlan(
                    entry: entry,
                    genericArguments: genericArguments,
                    signature: description,
                    resolver: resolver,
                    enclosing: enclosing,
                    implicitSelf: isProtocolMember ? self : nil,
                    declaredSignature: declaredSignature,
                    valueABIs: valueABIs
                )
                if isComplete {
                    try plan.checkLowerings(description)
                } else {
                    try plan.check(description, representations: representations)
                }
                return plan
            }
            func select(
                extensionsOnly: Bool,
                includingSharedCache: Bool
            ) throws -> (
                selection: SwiftCandidateSelection<SwiftGenericCallPlan>,
                unserved: [NativeDeclaration]
            ) {
                var tier = SwiftRequirementCandidates(
                    candidates: try resolver.swiftMemberCandidates(
                        match,
                        owner: memberOwner,
                        in: isProtocolMember || extensionsOnly ? nil : ownerImage,
                        extensionsOnly: extensionsOnly,
                        includingSharedCache: includingSharedCache
                    )
                )
                if isProtocolMember && !extensionsOnly {
                    // A protocol that exports dispatch thunks exports one for
                    // each requirement, so their witnesses are not searched.
                    let dispatches = tier.candidates.contains {
                        $0.record.context == .protocolRequirement
                            && $0.record.role == .dispatchThunk
                    }
                    if !dispatches {
                        if protocolConformance == nil {
                            protocolConformance = try protocolDescriptor(named: memberOwner)
                                .flatMap { symbol in
                                    try conformance(to: unsafe symbol.withUnsafeAddress { $0 })
                                }
                        }
                        if let own = protocolConformance ?? nil {
                            tier.candidates += try witnesses(
                                of: match,
                                in: memberOwner,
                                through: own,
                                excluding: tier.candidates,
                                includingSharedCache: includingSharedCache
                            )
                        }
                    }
                    tier = try servingWitnesses(tier.candidates)
                    conformances.merge(tier.conformances) { first, _ in first }
                }
                var unserved: [NativeDeclaration] = []
                let selection = SwiftCandidateSelection(
                    tier.candidates,
                    namesDeclaration: isComplete,
                    dispatch: { try self.dispatchedEntry($0, asynchronous: description.isAsync) }
                ) { candidate, entry -> SwiftGenericCallPlan? in
                    if isProtocolMember {
                        switch candidate.record.context {
                        // A requirement's own symbol in a resilient protocol is
                        // its default implementation, not a conformance's witness.
                        case .protocolRequirement where candidate.record.role != .implementation:
                            if let requirement = candidate.record.requirement {
                                considered.insert(requirement)
                            }
                        case .protocolExtension: break
                        default: return nil
                        }
                    }
                    guard query.isDeclared(by: candidate.record) else { return nil }
                    guard let plan = try prepare(candidate, entry) else { return nil }
                    // Another conformance's witness only shows that the
                    // request names a requirement without this type's witness.
                    if tier.others.contains(candidate.record.identity) {
                        unserved.append(candidate.declaration)
                        return nil
                    }
                    return plan
                }
                return (selection, unserved)
            }
            // The members a type declares hide those its extensions declare.
            for extensionsOnly in [false, true]
            where extensionsOnly ? missingWitness == nil : query.extensionModule == nil {
                var selection: SwiftCandidateSelection<SwiftGenericCallPlan>
                var unserved: [NativeDeclaration]
                do {
                    (selection, unserved) = try select(
                        extensionsOnly: extensionsOnly,
                        includingSharedCache: false
                    )
                    // The images can hold other overloads while only the shared
                    // cache's local symbols describe the requested one.
                    if selection.accepted.isEmpty && selection.failure == nil {
                        (selection, unserved) = try select(
                            extensionsOnly: extensionsOnly,
                            includingSharedCache: true
                        )
                    }
                } catch ABIResolutionError.imageUnavailable {
                    hasUnavailableImages = true
                    continue
                }
                if let (entry, plan) = try selection.selected(for: declaration) {
                    // A name that does not spell the extension's module can
                    // also name a requirement.
                    if isProtocolMember && extensionsOnly && query.extensionModule == nil {
                        try checkRequirements(
                            excluding: query,
                            match: match,
                            displayed: declaration,
                            isAsync: description.isAsync,
                            considered: considered,
                            conformances: conformances
                        ) { witness in
                            do {
                                return try prepare(witness, witness.entry, ignoringOwner: true)
                                    != nil
                            } catch ABIResolutionError.signatureMismatch {
                                return false
                            }
                        }
                    }
                    return (entry, isProtocolMember ? metadata : owner, plan)
                }
                // A member that applies but has no selectable code still hides
                // extension and superclass members. A protocol extension
                // member is not the requirement, so it cannot stand in for one
                // that fails or that only other conformances serve.
                if let unavailable = selection.unavailable { throw unavailable }
                if isProtocolMember && !extensionsOnly, let failure = selection.failure {
                    throw failure
                }
                if let requirement = unserved.first {
                    missingWitness = ABIResolutionError.metadataUnavailable(
                        requirement.name
                            + ": neither the protocol's dispatch thunk for this requirement nor the witness of \(self.name)'s conformance is in the loaded images. Witnesses of other conformances show that the protocol declares it, so no extension member stands in for it. A conformance's witnesses are local symbols, which stripping removes."
                    )
                }
                if let failure = selection.failure ?? selection.mismatch {
                    preparationFailure = failure
                }
            }
            guard inherited, let current = ownerClass, let parent = class_getSuperclass(current)
            else {
                if hasUnavailableImages { throw ABIResolutionError.imageUnavailable }
                if let missingWitness { throw missingWitness }
                if let preparationFailure { throw preparationFailure }
                throw ABIResolutionError.declarationNotFound(originalRequest!)
            }
            let runtimeName = try swiftFunctionTypeName(parent)
            ownerClass = parent
            ownerImage = try swiftClassImage(parent, named: runtimeName, resolver: resolver)
            ownerName = try swiftTypeDeclarationName(
                parent,
                in: ownerImage,
                suggestedName: runtimeName,
                resolver: resolver
            )
        }
    }

    /// Resolves an instance member: a method, or a property's or subscript's
    /// getter or setter.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// The handle calls the implementation selected during lookup, without
    /// virtual redispatch. Typed receivers transfer a copy to consuming
    /// members; ``NativeSwiftValue`` transfers its owned value. Borrowed views
    /// allow nonconsuming calls within their active scope; only native inout
    /// callback borrows permit mutation.
    ///
    /// A protocol-qualified requirement, including a subscript accessor's,
    /// binds `Self` to this concrete type. It runs through the protocol's
    /// dispatch thunk, or, where the protocol exports none, the witness of
    /// this type's conformance. Lookup requires the native conformance and
    /// preserves the protocol's formal `Self` convention.
    ///
    /// For runtime-only `self`, the request's `receiverABI` supplies
    /// established fixed components or an opaque descriptor for formally
    /// indirect `self`. Without it, a struct or enum `self` uses the
    /// convention inferred from its metadata, and preparation fails when the
    /// evidence cannot decide it; see
    /// <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable method with an explicit receiver, retaining this
    ///   type and the member's implementation images.
    /// - Throws: A lookup, representation, or preparation error.
    public nonisolated func resolveAndWait<Signature>(
        _ request: NativeSwiftInstanceMemberRequest<Signature>
    ) throws -> NativeSwiftMethod<Signature> {
        let member = try resolveMember(request.member, signature: Signature.self)
        let receiver = try receiverPlan(
            mutating: request.receiver.isMutating,
            consuming: request.receiver.isConsuming,
            generic: member.generic,
            receiverABI: request.receiver.abi
        )
        return try prepareMethod(
            member,
            receiver: receiver,
            consumesArguments: request.member.role == .setter
        )
    }

    /// Resolves an instance member without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker. Receivers remain with the
    /// caller, and lookup does not invoke the member.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable method with an explicit receiver.
    /// - Throws: The same lookup, representation, and preparation errors as
    ///   synchronous resolution.
    public nonisolated func resolve<Signature>(
        _ request: NativeSwiftInstanceMemberRequest<Signature>
    ) async throws -> NativeSwiftMethod<Signature> {
        try await NativePreparation.run { try self.resolveAndWait(request) }
    }

    /// Resolves an initializer, or a static or class member, called on this
    /// type.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// This type's metadata is supplied as the member's `self`. A class
    /// member exported only through its dispatch thunk runs this type's
    /// virtual-table entry, so a subclass's override runs when the subclass
    /// is this type. A protocol-qualified static requirement receives this
    /// type's metatype as `Self`, and a protocol-qualified initializer
    /// constructs this type through its conformance.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable function retaining this type and the member's
    ///   implementation images.
    /// - Throws: A lookup, representation, or preparation error.
    public nonisolated func resolveAndWait<Signature>(
        _ request: NativeSwiftTypeMemberRequest<Signature>
    ) throws -> NativeSwiftFunction<Signature> {
        let member = try resolveMember(request.member, signature: Signature.self)
        switch request.member.role {
        case .initializer:
            return try prepareFunction(
                member,
                consumesArguments: true,
                classReceiver: metadata is AnyClass
            )
        case .method, .getter, .setter:
            return try prepareFunction(
                member,
                consumesArguments: request.member.role == .setter,
                classReceiver: member.metadata is AnyClass
            )
        }
    }

    /// Resolves an initializer, or a static or class member, without blocking
    /// the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a
    /// separate operation.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable function retaining this type and the member's
    ///   implementation images.
    /// - Throws: The same lookup, representation, and preparation errors as
    ///   synchronous resolution.
    public nonisolated func resolve<Signature>(
        _ request: NativeSwiftTypeMemberRequest<Signature>
    ) async throws -> NativeSwiftFunction<Signature> {
        try await NativePreparation.run { try self.resolveAndWait(request) }
    }

    /// Selects the member that `request` names and prepares its call plan.
    private nonisolated func resolveMember(
        _ request: SwiftMemberRequest,
        signature: Any.Type
    ) throws -> ResolvedMember {
        let query = try SwiftMemberQuery(request)
        if request.role == .getter && !query.namesSubscript {
            try validateGetterSignature(signature)
        }
        return try resolveMember(
            query,
            signature: signature,
            genericArguments: request.options.genericArguments,
            declaredSignature: request.options.declaredSignature,
            valueABIs: request.options.valueABIs
        )
    }

    private nonisolated func prepareMethod<Signature>(
        _ member: ResolvedMember,
        receiver: SwiftReceiverPlan,
        consumesArguments: Bool
    ) throws -> NativeSwiftMethod<Signature> {
        try NativeSwiftMethod(
            entry: member.entry,
            type: self,
            receiver: receiver,
            consumesArguments: consumesArguments
                || member.entry.record?.accessor == .setter,
            generic: member.generic.includingReceiver(receiver.mode)
        )
    }

    private nonisolated func prepareFunction<Signature>(
        _ member: ResolvedMember,
        consumesArguments: Bool,
        classReceiver: Bool
    ) throws -> NativeSwiftFunction<Signature> {
        try NativeSwiftFunction(
            entry: member.entry,
            metadata: metadata,
            owner: self,
            consumesArguments: consumesArguments
                || member.entry.record?.accessor == .setter,
            generic: classReceiver
                ? try member.generic.includingReceiver(.object) : member.generic
        )
    }
}

func swiftClassImage(
    _ type: AnyClass,
    named name: String,
    resolver: SymbolResolver
) throws -> NativeImage {
    try withRuntimeErrors {
        NativeImage(try runtimeClassImage(type, named: name, resolver: resolver.runtime))
    }
}

func swiftTypeDeclarationName(
    _ type: Any.Type,
    in image: NativeImage,
    suggestedName: String,
    resolver: SymbolResolver
) throws -> String {
    try withRuntimeErrors {
        try runtimeTypeDeclarationName(
            type,
            in: image.runtimeValue,
            suggestedName: suggestedName,
            resolver: resolver.runtime
        )
    }
}

extension ABIRuntime {
    nonisolated func swiftType(for objectType: AnyClass) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let (runtimeName, image) = try swiftTypeImage(for: objectType)
        let key = SwiftTypeCacheKey.metadata(ObjectIdentifier(objectType), image: image.identity)
        if let cached = swiftTypeCache.value(for: key) { return cached }
        let type = try prepareSwiftType(
            for: objectType,
            in: image,
            suggestedName: runtimeName
        )
        return swiftTypeCache.insert(type, for: key, revision: revision)
    }

    private nonisolated func swiftTypeImage(
        for objectType: AnyClass
    ) throws -> (String, NativeImage) {
        let runtimeName = try swiftFunctionTypeName(objectType)
        let image = try swiftClassImage(objectType, named: runtimeName, resolver: resolver)
        return (runtimeName, image)
    }

    private nonisolated func prepareSwiftType(
        for objectType: AnyClass,
        in image: NativeImage,
        suggestedName: String
    ) throws -> NativeSwiftType {
        let name = try swiftTypeDeclarationName(
            objectType,
            in: image,
            suggestedName: suggestedName,
            resolver: resolver
        )
        return NativeSwiftType(
            name: name,
            image: image,
            metadata: objectType,
            representation: nil,
            resolver: resolver,
            genericMetadata: try SwiftGenericTypeMetadata(metadata: objectType)
        )
    }

    /// Resolves a concrete Swift class, struct, or enum and caches its metadata.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining its defining image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait(
        named name: String,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolveAndWait(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: scope,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: nil,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType(
        named name: String,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                in: scope,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a concrete Swift type within an already retained image.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining the image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait(
        named name: String,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolveAndWait(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: image,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: nil,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType(
        named name: String,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                in: image,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a Swift type with an explicit receiver representation.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// Use an ABIBridgeValue adapter when the native type cannot be imported. The representation describes fixed storage and ownership; it does not establish ABI compatibility with a resilient or generic declaration.
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or adapter for receiver values.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A reusable type handle with the chosen receiver representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait<Representation>(
        named name: String,
        as representation: Representation.Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolveAndWait(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: scope,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType<Representation>(
        named name: String,
        as representation: Representation.Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                as: representation,
                in: scope,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a Swift type and receiver adapter within a retained image.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or fixed-layout receiver adapter.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable type handle with the chosen representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait<Representation>(
        named name: String,
        as representation: Representation.Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolveAndWait(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: image,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType<Representation>(
        named name: String,
        as representation: Representation.Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                as: representation,
                in: image,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    private nonisolated func makeSwiftType(
        named name: String,
        descriptor: ResolvedSymbol,
        representation: Any.Type?,
        genericArguments: [NativeSwiftGenericArgument],
        revision: UInt64
    ) throws -> NativeSwiftType {
        let key = SwiftTypeCacheKey.declaration(
            name: name,
            image: descriptor.image.identity,
            representation: representation.map(ObjectIdentifier.init),
            arguments: genericArguments.map(\.identity)
        )
        if let cached = swiftTypeCache.value(for: key, retaining: genericArguments) {
            return cached
        }
        let type = try prepareSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments
        )
        return swiftTypeCache.insert(
            type,
            for: key,
            revision: revision,
            retaining: genericArguments
        )
    }

    private nonisolated func prepareSwiftType(
        named name: String,
        descriptor: ResolvedSymbol,
        representation: Any.Type?,
        genericArguments: [NativeSwiftGenericArgument]
    ) throws -> NativeSwiftType {
        guard descriptor.sectionRange.upperBound - descriptor.address >= 4 else {
            throw ABIResolutionError.metadataUnavailable(
                "Incomplete Swift type descriptor for " + name
            )
        }
        let metadata = try SwiftGenericTypeMetadata(
            descriptor: descriptor,
            arguments: genericArguments
        )
        return NativeSwiftType(
            name: name,
            image: descriptor.image,
            metadata: metadata.value,
            representation: representation,
            resolver: resolver,
            genericMetadata: metadata
        )
    }
}

extension NativeSwiftType {

    private nonisolated func validateGetterSignature(_ signature: Any.Type) throws {
        let description = try SwiftFunctionSignature(signature)
        guard description.parameters.isEmpty else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "A zero-argument getter signature",
                    found: [String(reflecting: signature)]
                )
            )
        }
    }
}
