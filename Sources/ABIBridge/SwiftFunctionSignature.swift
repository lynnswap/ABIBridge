import ABIBridgeRuntime
import ABIBridgeCore

/// The function metadata's formal types and effects, before declaration-level lowering. https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
struct SwiftFunctionMetadata: Sendable {
    let runtime: RuntimeFunctionMetadata
    var flags: UInt { runtime.flags }
    var parameters: [Any.Type] { runtime.parameters }
    var result: Any.Type { runtime.result }
    var failure: Any.Type { runtime.failure }
    var parameterFlags: [UInt32] { runtime.parameterFlags }
    var globalActor: Any.Type? { runtime.globalActor }
    var extendedFlags: UInt32 { runtime.extendedFlags }
    var attributes: SwiftFunctionAttributes {
        SwiftFunctionAttributes(
            isAsync: runtime.isAsync,
            isEscaping: runtime.isEscaping,
            isSendable: runtime.isSendable,
            isolation: runtime.isolation,
            differentiability: runtime.differentiability,
            hasSendingResult: runtime.hasSendingResult,
            parameterFlags: runtime.parameterFlags.map { $0 & ~7 }
        )
    }
    init(_ type: Any.Type) throws {
        runtime = try withRuntimeErrors { try RuntimeFunctionMetadata(type) }
    }
}

struct SwiftFunctionSignature: Sendable {
    private let metadata: SwiftFunctionMetadata
    var parameters: [Any.Type] { metadata.parameters }
    var result: Any.Type { metadata.result }
    var failure: Any.Type { metadata.failure }
    var isAsync: Bool { metadata.attributes.isAsync }
    var attributes: SwiftFunctionAttributes { metadata.attributes }
    var globalActor: Any.Type? { metadata.globalActor }
    var inheritsCallerIsolation: Bool { metadata.attributes.isolation == .caller }
    let parameterConventions: [SwiftArgumentConvention]

    init(_ type: Any.Type, nativeConventions: Bool = false) throws {
        let metadata = try SwiftFunctionMetadata(type)
        guard metadata.flags & 0x00ff0000 == 0 else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Expected the native Swift function convention."
            )
        }
        guard nativeConventions || metadata.parameterFlags.allSatisfy({ $0 == 0 }) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Use explicit Swift argument wrappers for parameter conventions."
            )
        }
        parameterConventions = try metadata.parameterFlags.map {
            switch $0 & 7 {
            case 0, 2: return .borrowing
            case 1: return .inoutValue
            case 3: return .consuming
            default:
                throw ABIResolutionError.unsupportedDeclaration(
                    "The native function parameter uses an unsupported ownership convention."
                )
            }
        }
        guard metadata.attributes.differentiability == .none else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Differentiable function types require their native invocation conventions."
            )
        }
        guard metadata.globalActor == nil || metadata.globalActor == MainActor.self else {
            throw ABIResolutionError.unsupportedDeclaration(
                "This global-actor function requires its actor's native invocation convention."
            )
        }
        guard metadata.attributes.isolation != .isolatedAny else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An isolated-any function requires a dynamic isolation context."
            )
        }
        self.metadata = metadata
    }

    /// - Parameter schema: The declaration's schema of the error where it
    ///   differs from the thrown type's own.
    func makeErrorPlan(schema: SwiftValueSchema? = nil) throws -> SwiftErrorPlan? {
        if failure == Never.self && schema == nil { return nil }
        if failure == (any Error).self {
            return try SwiftErrorPlan.make((any Error).self, schema: schema)
        }
        guard let error = failure as? any Error.Type else {
            throw ABIResolutionError.unsupportedDeclaration(
                "The function's thrown type does not conform to Error."
            )
        }
        return try SwiftErrorPlan.make(error, schema: schema)
    }

    /// The discriminator that signs this function's values. Describing the
    /// function's formal types also rejects values that closure signatures
    /// do not support, on every architecture.
    func closureDiscriminator() throws -> UInt16 {
        RuntimePointerAuthentication.swiftClosureDiscriminator(try closureAuthDescription())
    }

    func closureAuthDescription() throws -> String {
        var parameters = isAsync && inheritsCallerIsolation ? ["-class"] : []
        for type in self.parameters {
            parameters.append(contentsOf: try swiftClosureAuthTypes(type, position: .parameter))
        }
        return swiftClosureAuthDescription(
            parameters: parameters,
            results: try swiftClosureAuthTypes(result, position: .result)
        )
    }
}

enum SwiftCallablePlan: Sendable {
    case synchronous(SwiftCall)
    case asynchronous(SwiftAsyncCall, SwiftAsyncImplementation)

    var values: SwiftCallValues {
        switch self {
        case .synchronous(let call): call.values
        case .asynchronous(let call, _): call.values
        }
    }

    init(
        signature: Any.Type,
        entry: SwiftEntry,
        resolver: SymbolResolver?,
        trailingType: CValueType? = nil,
        consumesArguments: Bool = false,
        generic: SwiftGenericCallPlan? = nil
    ) throws {
        let description = try SwiftFunctionSignature(signature)
        let errorPlan = try description.makeErrorPlan(schema: generic?.errorSchema)
        let opaque =
            try generic?.plansResult == true
            ? nil
            : SwiftOpaqueResultPlan.make(
                for: description.result,
                entry: entry,
                resolver: resolver
            )
        if description.isAsync {
            guard let resolver else {
                throw ABIResolutionError.metadataUnavailable(
                    "Async calls require the native descriptor's resolver."
                )
            }
            self = .asynchronous(
                try SwiftAsyncCall(
                    signature: signature,
                    trailingType: trailingType,
                    consumesArguments: consumesArguments,
                    errorPlan: errorPlan,
                    inheritsCallerIsolation: description.inheritsCallerIsolation,
                    opaqueResult: opaque,
                    generic: generic
                ),
                try SwiftAsyncImplementation(entry: entry, resolver: resolver)
            )
        } else {
            self = .synchronous(
                try SwiftCall(
                    signature: signature,
                    trailingType: trailingType,
                    consumesArguments: consumesArguments,
                    errorPlan: errorPlan,
                    opaqueResult: opaque,
                    generic: generic
                )
            )
        }
    }

    var generic: SwiftGenericCallPlan? {
        switch self {
        case .synchronous(let call): call.generic
        case .asynchronous(let call, _): call.generic
        }
    }

    var errorPlan: SwiftErrorPlan? {
        switch self {
        case .synchronous(let call): call.errorPlan
        case .asynchronous(let call, _): call.errorPlan
        }
    }

    var isAsync: Bool {
        if case .asynchronous = self { return true }
        return false
    }

    /// Requires that `replacement`, the plan of another declaration, receives
    /// the calls that native code makes with this plan.
    func requireReplacement(
        _ replacement: SwiftCallablePlan,
        declaration: NativeDeclaration
    ) throws {
        guard case .synchronous(let original) = self,
            case .synchronous(let other) = replacement
        else {
            preconditionFailure("Replacements have synchronous call plans.")
        }
        try original.requireReplacement(other, declaration: declaration)
    }
}

/// Shares value preparation between synchronous and asynchronous transports. The containing signature establishes the types used by typed invocation.
struct SwiftCallValues: Sendable {
    struct Argument: Sendable {
        let conversion: SwiftHostConversion
        /// The storage with which the argument passes.
        let type: CValueType
        /// How native code receives the argument.
        let convention: SwiftArgumentConvention
        /// Whether the argument passes to an async function.
        let asynchronous: Bool
        var consumes: Bool { convention == .consuming }

        /// Whether the value has ownership that a convention transfers, as
        /// a reference or a value with nontrivial copies does; plain bytes
        /// and metatypes have none.
        var hasOwnership: Bool {
            let schema = conversion.schema
            switch schema.kind {
            case .scalar, .metatype: return false
            default: break
            }
            guard let metadata = schema.metadata else { return true }
            let nonPOD: UInt32 = 0x0001_0000
            return ABISwiftGetValueWitnessFlags(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
                & nonPOD != 0
        }

        /// How an argument of the host type `host` passes as `plan` describes
        /// it, where the declaration consumes arguments by default if
        /// `defaultConsuming`.
        ///
        /// - Parameter position: `.parameter` for a whole parameter, or the
        ///   position of a tuple element; it decides how an undecided
        ///   inferred host value is passed.
        init(
            host: Any.Type,
            plan: SwiftGenericArgument,
            defaultConsuming: Bool,
            asynchronous: Bool,
            position: SwiftValuePosition = .parameter
        ) throws {
            conversion = try SwiftHostConversion(host: host, argument: plan, position: position)
            switch plan {
            case .value(let native, let consuming):
                type = native
                convention = consuming || defaultConsuming ? .consuming : .borrowing
                self.asynchronous = asynchronous
            case .closure(_, let planned):
                type = conversion.type
                convention = defaultConsuming ? .consuming : .borrowing
                self.asynchronous = planned
            case .runtimeValue(let runtime, let planned, let plannedAsynchronous):
                type =
                    planned == .inoutValue ? try CValueType(scalar: ABIValuePointer) : runtime.type
                convention = planned
                self.asynchronous = plannedAsynchronous
            case .tuple(let tuple, let consuming, let planned):
                type = tuple.type
                convention = consuming || defaultConsuming ? .consuming : .borrowing
                self.asynchronous = planned
            case .convention, .host:
                type = conversion.type
                convention = conversion.ownership ?? (defaultConsuming ? .consuming : .borrowing)
                self.asynchronous = asynchronous
            }
        }
    }
    struct Result: Sendable {
        let conversion: SwiftHostConversion
        let scoped: SwiftRuntimeValuePlan?
        var type: CValueType { conversion.type }
        func makeStorage() -> NativeValueStorage { conversion.makeStorage() }
    }
    let arguments: [Argument]
    let result: Result

    /// - Parameters:
    ///   - opaqueResult: The underlying type of an opaque result, which
    ///     applies where the host type would convert the result by itself.
    ///   - result: How the result passes, or nil for a result that its host
    ///     type converts by itself.
    init(
        signature: SwiftFunctionSignature,
        consumesArguments: Bool,
        opaqueResult: SwiftOpaqueResultPlan?,
        arguments argumentPlans: [SwiftGenericArgument],
        result resultPlan: SwiftGenericResult?
    ) throws {
        arguments = try zip(signature.parameters, argumentPlans).map { type, argument in
            let consuming: Bool
            // Initializers consume escaping closure arguments, but their
            // nonescaping closure parameters are guaranteed borrows.
            if case .closure(let plan, _) = argument {
                consuming = consumesArguments && plan.isEscaping
            } else {
                consuming = consumesArguments
            }
            return try Argument(
                host: type,
                plan: argument,
                defaultConsuming: consuming,
                asynchronous: signature.isAsync
            )
        }
        let resultPlan: SwiftGenericResult? =
            switch resultPlan {
            case .host?, nil: opaqueResult.map { .runtimeValue($0.value) } ?? resultPlan
            default: resultPlan
            }
        let conversion =
            try resultPlan.map { try SwiftHostConversion(host: signature.result, result: $0) }
            ?? SwiftHostConversion(host: signature.result, position: .result)
        let scoped: SwiftRuntimeValuePlan?
        if signature.result == NativeSwiftBorrowedValue.self {
            scoped = conversion.runtimeValue
        } else {
            scoped = nil
        }
        result = Result(conversion: conversion, scoped: scoped)
    }

    /// Checks that each argument passes as Swift passes it where the call's
    /// result borrows from it; see ``SwiftBorrowedInputs``.
    ///
    /// - Parameter declaration: The selected declaration's plan, whose
    ///   formal parameter types name the native types behind adapters.
    func requireBorrowableArguments(declaration: SwiftGenericCallPlan?) throws {
        guard result.scoped != nil else { return }
        // Packs pass their elements through one buffer, by address.
        var formals: [Int: SwiftFormalType] = [:]
        if let declaration {
            for (formal, group) in zip(
                declaration.binding.declaration.arguments,
                declaration.parameters.groups
            ) {
                if case .value(let index) = group { formals[index] = formal }
            }
        }
        // Swift rejects a borrow dependency on a consuming argument and
        // passes an inout argument by address.
        for (index, argument) in arguments.enumerated() where argument.convention == .borrowing {
            let indirect = withExtendedLifetime(argument.type) {
                ABISwiftValueIsIndirect(argument.type.handle)
            }
            // A tuple passes its elements separately.
            if indirect, argument.conversion.tuple == nil { continue }
            try SwiftBorrowedInputs.requireArgument(
                index,
                conversion: argument.conversion,
                formal: formals[index],
                binding: declaration?.binding
            )
        }
    }

    func requireIndependentResult() throws {
        guard result.scoped == nil else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A scoped runtime result requires unsafeInvoke(..., withResult:)."
            )
        }
    }

    func scopedResult() throws -> SwiftRuntimeValuePlan {
        guard let scoped = result.scoped else {
            throw ABIResolutionError.unsupportedDeclaration(
                "withResult: requires a scoped runtime result signature."
            )
        }
        return scoped
    }

    /// Prepares the native values of an invocation's arguments.
    func encode<each Argument>(
        _ values: repeat each Argument,
        retainingCode owner: Any?
    ) throws -> SwiftValueTransfer {
        var storage: [NativeValueStorage] = []
        storage.reserveCapacity(arguments.count)
        var index = 0
        for value in repeat each values {
            let argument = arguments[index]
            storage.append(
                try withUnsafePointer(to: value) {
                    try argument.conversion.encode(
                        $0,
                        convention: argument.convention,
                        asynchronous: argument.asynchronous,
                        retainingCode: owner
                    )
                }
            )
            index += 1
        }
        return SwiftValueTransfer(storage: storage, consumes: arguments.map(\.consumes))
    }

    func decode<Output>(
        _ storage: NativeValueStorage,
        retaining owner: Any?,
        retainingCode codeOwner: Any?
    ) throws -> Output {
        try result.conversion.decode(
            storage,
            retaining: owner,
            retainingCode: codeOwner,
            as: Output.self
        )
    }
}

// Native function parameters can contain stack closure contexts. Their handles
// borrow the entry frame; resolving them is a throwing invocation operation.
final class SwiftCallbackScope {
    private var borrows: [SwiftValueBorrow] = []
    private var storage: [NativeValueStorage] = []
    private var writebacks: [SwiftWritebackPreparation] = []
    private var pendingInputs: [Int: () -> Void] = [:]
    private var runtimeInputs: [UInt: NativeSwiftValue] = [:]
    private let asynchronous: Bool
    init(asynchronous: Bool) { self.asynchronous = asynchronous }
    var hasWritebacks: Bool { !writebacks.isEmpty }
    func retainInput(at index: Int, cleanup: @escaping () -> Void) {
        pendingInputs[index] = cleanup
    }
    func retainRuntimeInput(
        _ value: NativeSwiftValue,
        at address: UnsafeMutableRawPointer,
        index: Int
    ) {
        runtimeInputs[UInt(bitPattern: address)] = value
        claimInput(at: index)
    }
    func runtimeInput(at address: UnsafeMutableRawPointer) -> NativeSwiftValue? {
        runtimeInputs[UInt(bitPattern: address)]
    }
    func claimInput(at index: Int) { pendingInputs.removeValue(forKey: index) }
    func prepareWriteback(_ body: @escaping SwiftWritebackPreparation) { writebacks.append(body) }
    func finishInvocation<Output>(_ outcome: Result<Output, any Error>) throws -> Output {
        defer { expire() }
        return try finishSwiftInvocation(outcome) {
            let commits = try writebacks.map { try $0() }
            for commit in commits { commit() }
        }
    }
    func borrow(
        _ address: UnsafeRawPointer,
        retaining storage: NativeValueStorage? = nil,
        allowsSuspension: Bool? = nil,
        allowsMutation: Bool = false
    ) -> SwiftValueBorrow {
        if let storage { self.storage.append(storage) }
        let borrow = SwiftValueBorrow(
            address,
            allowsSuspension: allowsSuspension ?? asynchronous,
            allowsMutation: allowsMutation
        )
        borrows.append(borrow)
        return borrow
    }
    func expire() {
        let pending = pendingInputs
        pendingInputs.removeAll()
        for cleanup in pending.values { cleanup() }
        for borrow in borrows { borrow.expire() }
        borrows.removeAll()
        writebacks.removeAll()
        runtimeInputs.removeAll()
        storage.removeAll()
    }
    deinit { expire(); withExtendedLifetime(storage) {} }
}

typealias SwiftCallbackDecoder =
    @Sendable (UnsafeMutableRawPointer, SwiftCallbackScope) throws -> Any

struct SwiftCallbackValues: Sendable {
    private let decoders: [SwiftCallbackDecoder?]
    private let constants: [SwiftValueConstants]
    private let needsScope: Bool
    private let inputDestructors: [(@Sendable (UnsafeMutableRawPointer) -> Void)?]

    init(
        _ signature: SwiftFunctionSignature,
        arguments: [SwiftGenericArgument] = [],
        consumingArguments: [Bool]? = nil
    ) throws {
        let arguments =
            try arguments.isEmpty
            ? SwiftGenericParameters.concreteArguments(signature: signature) : arguments
        let consuming = consumingArguments ?? arguments.map { $0.convention == .consuming }
        var decoders: [SwiftCallbackDecoder?] = [], constants: [SwiftValueConstants] = []
        var inputDestructors: [(@Sendable (UnsafeMutableRawPointer) -> Void)?] = []
        for (index, (type, argument)) in zip(signature.parameters, arguments).enumerated() {
            // A borrowed value that is its own native value is read in place.
            if !consuming[index], let readsInPlace = Self.readsInPlace(type, argument: argument) {
                decoders.append(nil)
                constants.append(readsInPlace)
                inputDestructors.append(nil)
                continue
            }
            let conversion = try SwiftHostConversion(
                host: type,
                argument: argument,
                position: .parameter
            )
            let convention: SwiftArgumentConvention
            let asynchronous: Bool
            if case .runtimeValue(_, let planned, let plannedAsynchronous) = argument {
                // A borrowed handle cannot own its input.
                let borrowed =
                    SwiftGenericCallPlan.runtimeHandle(type)?.type == NativeSwiftBorrowedValue.self
                convention =
                    planned == .inoutValue
                    ? .inoutValue : !borrowed && consuming[index] ? .consuming : .borrowing
                asynchronous = plannedAsynchronous
            } else {
                convention = consuming[index] ? .consuming : .borrowing
                asynchronous = false
            }
            decoders.append(
                try conversion.callbackDecoder(
                    convention: convention,
                    asynchronous: asynchronous,
                    failure: signature.failure
                )
            )
            constants.append(SwiftValueConstants(Void.self))
            inputDestructors.append(consuming[index] ? Self.inputDestructor(conversion) : nil)
        }
        self.decoders = decoders
        self.constants = constants
        self.inputDestructors = inputDestructors
        needsScope = decoders.contains { $0 != nil } || inputDestructors.contains { $0 != nil }
    }

    /// The constants to restore when a borrowed input of the host type `type`
    /// is read in place, or nil when `argument` converts the input.
    private static func readsInPlace(
        _ type: Any.Type,
        argument: SwiftGenericArgument
    ) -> SwiftValueConstants? {
        switch argument {
        case .value: SwiftValueConstants(Void.self)
        case .host(let conversion):
            // A closed declaration can pass another byte where the host
            // reads a Bool, which its decoder normalizes.
            if case .identity = conversion.kind,
                SwiftHostConversion.booleanOffsets(in: type).isEmpty
            {
                SwiftValueConstants(type)
            } else {
                nil
            }
        default: nil
        }
    }

    private static let releaseContext: @Sendable (UnsafeMutableRawPointer) -> Void = {
        ABIReleaseSwiftClosureContext($0.load(as: ABISwiftClosureValue.self).ownedContext)
    }

    /// Destroys a consumed callback input that `conversion` receives.
    private static func inputDestructor(
        _ conversion: SwiftHostConversion
    ) -> @Sendable (UnsafeMutableRawPointer) -> Void {
        if case .ownership(_, let value) = conversion.kind { return inputDestructor(value) }
        if let tuple = conversion.tuple {
            let fields = tuple.leaves.map { ($0.nativeType, SwiftValueConstants($0.nativeType)) }
            return { vector in
                let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                for (index, field) in fields.enumerated() {
                    field.1.initialize(at: addresses[index]!)
                    ABISwiftDestroyValue(
                        unsafeBitCast(field.0, to: UnsafeRawPointer.self),
                        addresses[index]!
                    )
                }
            }
        }
        switch conversion.kind {
        case .closure: return releaseContext
        case .runtimeValue(let plan) where plan.nativeClosure != nil: return releaseContext
        default: break
        }
        let metadata = conversion.runtimeValue?.valueType.metadata ?? conversion.host
        let constants = SwiftValueConstants(metadata)
        return {
            constants.initialize(at: $0)
            ABISwiftDestroyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), $0)
        }
    }

    func makeScope(
        asynchronous: Bool,
        arguments: UnsafePointer<UnsafeMutableRawPointer?>?
    ) -> SwiftCallbackScope? {
        guard needsScope else { return nil }
        let scope = SwiftCallbackScope(asynchronous: asynchronous)
        for (index, destroy) in inputDestructors.enumerated() {
            if let destroy, let address = arguments?[index] {
                scope.retainInput(at: index) { destroy(address) }
            }
        }
        return scope
    }

    func decode<Value>(
        _ address: UnsafeMutableRawPointer,
        at index: Int,
        scope: SwiftCallbackScope?,
        as type: Value.Type
    ) throws -> Value {
        scope?.claimInput(at: index)
        if let decode = decoders[index] { return try decode(address, scope!) as! Value }
        return constants[index].load(from: address, as: type)
    }
}

/// Prepares a host callback's result as the native value it returns.
struct SwiftCallbackResult<Value>: Sendable {
    private let conversion: SwiftHostConversion
    var initializeNativeResult: SwiftResultInitializer { conversion.initializeNativeResult }

    /// - Parameter generic: How the result passes, or nil for a result
    ///   that its type converts by itself.
    init(failure: Any.Type, generic: SwiftGenericResult? = nil) throws {
        try self.init(
            generic.map { try SwiftHostConversion(host: Value.self, result: $0) }
                ?? SwiftHostConversion(host: Value.self, position: .result),
            failure: failure
        )
    }

    /// - Parameter failure: The callback's error type, which reports a
    ///   failure to convert the result.
    init(_ conversion: SwiftHostConversion, failure: Any.Type) throws {
        try conversion.validateOwnedResult()
        let converts =
            switch conversion.kind {
            case .closure, .runtimeValue: true
            case .tuple(let plan): plan.needsConversion
            default: false
            }
        if converts && failure != (any Error).self {
            throw ABIResolutionError.unsupportedDeclaration(
                "A host callback returning a converted value requires throws(any Error) to report ownership and conversion failures."
            )
        }
        self.conversion = conversion
    }

    func prepare(_ value: Value) throws -> (UnsafeMutableRawPointer) -> Void {
        try withUnsafePointer(to: value) { try conversion.prepareResult($0, retainingCode: nil) }
    }

    func initialize(_ value: Value, at output: UnsafeMutableRawPointer) throws {
        if case .identity = conversion.kind {
            output.initializeMemory(as: Value.self, repeating: value, count: 1)
            return
        }
        try prepare(value)(output)
    }
}
