import ABIBridgeCore
import ABIBridgeRuntime
import Synchronization

/// Converts the host value at one position to and from its native value.
///
/// A conversion is prepared once from the position's plan and the host type.
/// It works in both directions, so a call's arguments and result, a
/// callback's inputs and result, and a hook's values share it.
struct SwiftHostConversion: Sendable {
    indirect enum Kind: Sendable {
        /// The host value is the native value: the native type itself, an
        /// `ABIBridgeSwiftValue`, a C value, or a class reference.
        case identity
        /// An `ABIBridgeValue` adapter, which passes its C representation.
        case adapter
        /// A runtime value handle, or its Optional or collection projection.
        case runtimeValue(SwiftRuntimeValuePlan)
        /// A closure, which passes a native function and its context.
        case closure(SwiftClosureConversion)
        /// A tuple whose fields convert independently.
        case tuple(SwiftTupleValuePlan)
        /// An ownership wrapper around the conversion of its value.
        case ownership(SwiftArgumentConvention, SwiftHostConversion)
    }

    let kind: Kind
    /// The host type.
    let host: Any.Type
    /// The native value at this position.
    let schema: SwiftValueSchema
    var type: CValueType { schema.type }
    private let operations: Operations
    private let hostValues: SwiftHostValues

    struct Operations: Sendable {
        /// Host to native: storage that passes the value at the host address
        /// with an ownership convention, possibly to an async function.
        let encode:
            @Sendable (UnsafeRawPointer, SwiftArgumentConvention, Bool, Any?) throws ->
                NativeValueStorage
        /// Host to native: storage holding an owned native value, which
        /// takes the runtime values the host value holds.
        let encodeResult: @Sendable (UnsafeRawPointer, Any?) throws -> NativeValueStorage
        /// Host to native: storage holding an owned native value, or holding
        /// a native value to copy, flagged true, which the host value keeps.
        let encodeCopy: @Sendable (UnsafeRawPointer, Any?) throws -> (NativeValueStorage, Bool)
        /// Storage for a native value that native code initializes.
        let makeStorage: @Sendable () -> NativeValueStorage
        /// Native to host: takes the owned native value in the storage and
        /// initializes the host value at the output address.
        let decode:
            @Sendable (NativeValueStorage, Any?, Any?, UnsafeMutableRawPointer) throws -> Void
        /// Native to host for a callback input that native code passes with
        /// a convention, possibly to an async callback, given the callback's
        /// error type.
        let callbackDecoder:
            @Sendable (SwiftArgumentConvention, Bool, Any.Type) throws -> SwiftCallbackDecoder
        /// Checks that the host value can own a native result.
        let validateOwnedResult: @Sendable () throws -> Void
    }

    private init<Value>(
        _: Value.Type,
        kind: Kind,
        schema: SwiftValueSchema,
        operations: Operations
    ) {
        self.kind = kind
        host = Value.self
        self.schema = schema
        self.operations = operations
        hostValues = SwiftHostValues(Value.self)
    }

    // MARK: Plans

    var tuple: SwiftTupleValuePlan? {
        switch kind {
        case .tuple(let plan): plan
        case .runtimeValue(let plan): plan.nativeTuple
        case .ownership(_, let value): value.tuple
        default: nil
        }
    }

    var closure: SwiftGenericClosurePlan? {
        switch kind {
        case .closure(let closure): closure.plan
        case .runtimeValue(let plan): plan.nativeClosure
        case .ownership(_, let value): value.closure
        default: nil
        }
    }

    var runtimeValue: SwiftRuntimeValuePlan? {
        switch kind {
        case .runtimeValue(let plan): plan
        case .ownership(_, let value): value.runtimeValue
        default: nil
        }
    }

    /// The wrapper's convention, for an ownership wrapper.
    var ownership: SwiftArgumentConvention? {
        if case .ownership(let convention, _) = kind { return convention }
        return nil
    }

    /// The native type, whose value witnesses copy, take, and destroy the
    /// native value: an adapter's is a trivial type of its representation's
    /// size and alignment, and a closure's is its native function type.
    func nativeType() throws -> Any.Type {
        switch kind {
        case .identity: host
        case .adapter: try Self.trivialType(of: type)
        case .runtimeValue(let plan): plan.valueType.metadata
        case .closure: try SwiftClosureConversion.nativeType(of: host)
        case .tuple(let plan): plan.nativeMetadata
        case .ownership(_, let value): try value.nativeType()
        }
    }

    // MARK: Host to native

    /// Storage that passes the host value at `value` to native code.
    ///
    /// - Parameters:
    ///   - convention: How native code receives the value. An ownership
    ///     wrapper passes its value with its own convention.
    ///   - asynchronous: Whether the value passes to an async function, whose
    ///     suspensions borrowed values must allow.
    ///   - owner: What the native value's code must keep alive.
    func encode(
        _ value: UnsafeRawPointer,
        convention: SwiftArgumentConvention,
        asynchronous: Bool,
        retainingCode owner: Any?
    ) throws -> NativeValueStorage {
        try operations.encode(value, convention, asynchronous, owner)
    }

    /// Storage holding an owned native value for the host value at `value`,
    /// which gives up the runtime values it holds, as a result does.
    func encodeResult(
        _ value: UnsafeRawPointer,
        retainingCode owner: Any?
    ) throws -> NativeValueStorage {
        try operations.encodeResult(value, owner)
    }

    /// Storage holding an owned native value for the host value at `value`,
    /// or, when `copying`, a native value to copy, which the host value
    /// keeps.
    func encodeCopy(
        _ value: UnsafeRawPointer,
        retainingCode owner: Any?
    ) throws -> (storage: NativeValueStorage, copying: Bool) {
        try operations.encodeCopy(value, owner)
    }

    // MARK: Native to host

    func makeStorage() -> NativeValueStorage { operations.makeStorage() }

    /// Takes the owned native value in `storage` as the host value at
    /// `output`.
    func decode(
        _ storage: NativeValueStorage,
        retaining owner: Any?,
        retainingCode codeOwner: Any?,
        into output: UnsafeMutableRawPointer
    ) throws {
        try operations.decode(storage, owner, codeOwner, output)
    }

    /// Takes the owned native value in `storage` as a host value.
    func decode<Value>(
        _ storage: NativeValueStorage,
        retaining owner: Any?,
        retainingCode codeOwner: Any?,
        as type: Value.Type
    ) throws -> Value {
        try withUnsafeTemporaryAllocation(of: Value.self, capacity: 1) { buffer in
            try operations.decode(storage, owner, codeOwner, buffer.baseAddress!)
            return buffer.baseAddress!.move()
        }
    }

    /// A decoder of a callback input that native code passes with
    /// `convention`.
    ///
    /// - Parameters:
    ///   - asynchronous: Whether the callback is async, so that borrows of
    ///     the input allow suspension.
    ///   - failure: The callback's error type, which must be able to report
    ///     a failed writeback.
    func callbackDecoder(
        convention: SwiftArgumentConvention,
        asynchronous: Bool,
        failure: Any.Type
    ) throws -> SwiftCallbackDecoder {
        try operations.callbackDecoder(convention, asynchronous, failure)
    }

    /// Checks that a host value can own a native result.
    func validateOwnedResult() throws { try operations.validateOwnedResult() }

    // MARK: Host values

    /// Initializes the host value at `address` with `value`, a value of the
    /// host type.
    func initializeHost(_ value: Any, at address: UnsafeMutableRawPointer) {
        hostValues.initialize(value, address)
    }

    func destroyHost(at address: UnsafeMutableRawPointer) { hostValues.destroy(address) }
}

/// Initializes and destroys values of a host type that is known at run time.
private struct SwiftHostValues: Sendable {
    let initialize: @Sendable (Any, UnsafeMutableRawPointer) -> Void
    let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

    init<Value>(_: Value.Type) {
        initialize = { value, address in
            address.initializeMemory(as: Value.self, repeating: value as! Value, count: 1)
        }
        destroy = { $0.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
    }
}

// MARK: - Preparation

extension SwiftHostConversion {
    /// The conversion of an argument whose host type is `host`, as `argument`
    /// plans it.
    ///
    /// - Parameters:
    ///   - position: `.parameter` for a whole parameter, or the position of a
    ///     tuple element; it decides how an undecided inferred host value is
    ///     passed.
    ///   - asynchronous: Whether the argument passes to an async function,
    ///     whose closures need their prepared reabstraction.
    init(
        host: Any.Type,
        argument: SwiftGenericArgument,
        asynchronous: Bool = false,
        position: SwiftValuePosition
    ) throws {
        func prepare<Value>(_: Value.Type) throws -> Self {
            switch argument {
            case .convention(let conversion):
                return conversion
            case .value(let type, _):
                return .identity(
                    Value.self,
                    schema: SwiftValueSchema(storage: type, metadata: Value.self),
                    restoresConstants: false
                )
            case .closure(let plan, _):
                return try .closure(Value.self, plan: plan, codec: nil)
            case .runtimeValue(let plan, _, _):
                return try .runtimeValue(Value.self, plan: plan)
            case .tuple(let plan, _, _):
                return .tuple(Value.self, plan: plan)
            case .concrete:
                if let wrapper = Value.self as? any SwiftConventionArgument.Type {
                    let nested: SwiftGenericArgument
                    if asynchronous, let closure = wrapper.wrappedType as? any SwiftClosureValue.Type {
                        nested = .closure(
                            try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType),
                            asynchronous: true
                        )
                    } else {
                        nested = .concrete
                    }
                    return try wrapper.makeConversion(generic: nested)
                }
                if let tuple = try SwiftTupleValuePlan(host: Value.self, position: position) {
                    return .tuple(Value.self, plan: tuple)
                }
                if asynchronous, let closure = Value.self as? any SwiftClosureValue.Type {
                    return try .closure(
                        Value.self,
                        plan: SwiftGenericClosurePlan.concrete(closure.swiftFunctionType),
                        codec: nil
                    )
                }
                return try Self(host: Value.self, position: position)
            }
        }
        self = try _openExistential(host, do: prepare)
    }

    /// The conversion of a result whose host type is `host`, as `result` or
    /// an opaque result's underlying type plans it.
    init(host: Any.Type, result: SwiftGenericResult, opaque: SwiftOpaqueResultPlan? = nil) throws {
        func prepare<Value>(_: Value.Type) throws -> Self {
            switch result {
            case .value(let type):
                return .identity(
                    Value.self,
                    schema: SwiftValueSchema(storage: type, metadata: Value.self),
                    restoresConstants: false
                )
            case .closure(let codec):
                return try .closure(Value.self, plan: codec.nativePlan, codec: codec)
            case .runtimeValue(let plan):
                if Value.self != NativeSwiftBorrowedValue.self {
                    try plan.requireOwnedValue(as: Value.self)
                }
                return try .runtimeValue(Value.self, plan: plan)
            case .tuple(let plan):
                try plan.validateOwnedResult()
                return .tuple(Value.self, plan: plan)
            case .concrete:
                if let opaque {
                    if Value.self != NativeSwiftBorrowedValue.self {
                        try opaque.value.requireOwnedValue(as: Value.self)
                    }
                    return try .runtimeValue(Value.self, plan: opaque.value)
                }
                return try Self(host: Value.self, position: .result)
            }
        }
        self = try _openExistential(host, do: prepare)
    }

    /// The conversion of a value that the host type `host` passes by itself
    /// at `position`, from the type's own representation.
    ///
    /// A tuple whose elements convert passes its native tuple, and a closure
    /// its native function. An adapter passes its C representation. Other
    /// values pass themselves.
    init(host: Any.Type, position: SwiftValuePosition) throws {
        func prepare<Value>(_: Value.Type) throws -> Self {
            if let tuple = try SwiftTupleValuePlan(host: Value.self, position: position),
                tuple.needsConversion
            {
                return .tuple(Value.self, plan: tuple)
            }
            if let closure = Value.self as? any SwiftClosureValue.Type {
                return try .closure(Value.self, plan: nil, codec: closure.makeClosureCodec())
            }
            let schema = try SwiftValueSchema.host(Value.self, position: position)
            if Self.isAdapter(Value.self) {
                return try .adapter(Value.self, schema: schema)
            }
            return .identity(Value.self, schema: schema, restoresConstants: true)
        }
        self = try _openExistential(host, do: prepare)
    }

    /// Whether `Value` passes as its `ABIBridgeValue` representation, even
    /// in an Optional, instead of its own Swift storage.
    static func isAdapter<Value>(_: Value.Type) -> Bool {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        return base is any ABIBridgeValue.Type && !(Value.self is any ABIBridgeSwiftValue.Type)
            && !(base is any ABIBridgeSwiftValue.Type)
    }

    /// A trivial type with the size and alignment of `type`, which stands
    /// for an adapter's C representation where native code copies, takes,
    /// or destroys it.
    static func trivialType(of type: CValueType) throws -> Any.Type {
        let element: Any.Type
        switch type.alignment {
        case 1: element = UInt8.self
        case 2: element = UInt16.self
        case 4: element = UInt32.self
        case 8: element = UInt64.self
        default:
            throw ABIResolutionError.unsupportedDeclaration(
                "An adapter representation with alignment \(type.alignment) has no native storage type."
            )
        }
        let count = (type.size + type.alignment - 1) / type.alignment
        if count == 1 { return element }
        let pointers = Array(
            repeating: Optional(unsafeBitCast(element, to: UnsafeRawPointer.self)),
            count: count
        )
        let metadata = pointers.withUnsafeBufferPointer {
            ABISwiftTupleTypeMetadata($0.baseAddress, $0.count, nil)
        }
        guard let metadata else {
            throw ABIResolutionError.metadataUnavailable(
                "The adapter representation exceeds Swift's tuple metadata element count."
            )
        }
        return unsafeBitCast(metadata, to: Any.Type.self)
    }
}

// MARK: - Kinds

extension SwiftHostConversion {
    /// The host value of `Value` is its native value, stored as `schema`.
    ///
    /// - Parameter restoresConstants: Whether a callback input restores the
    ///   singleton metatypes that the host type stores, which a value that
    ///   native code passes in registers omits.
    private static func identity<Value>(
        _: Value.Type,
        schema: SwiftValueSchema,
        restoresConstants: Bool
    ) -> Self {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        // A nonoptional reference or pointer has no nil value.
        let requiresValue =
            !(Value.self is any NativeOptionalValue.Type)
            && (base is AnyClass || base == AnyObject.self || base is any NativePointerValue.Type)
        let constants = SwiftValueConstants(Value.self)
        let inputConstants = SwiftValueConstants(restoresConstants ? Value.self : Void.self)
        let size = max(MemoryLayout<Value>.stride, schema.type.size)
        let alignment = max(MemoryLayout<Value>.alignment, schema.type.alignment)
        @Sendable func encode(_ value: UnsafeRawPointer) -> NativeValueStorage {
            if Value.self == Void.self { return NativeValueStorage(size: 0, alignment: 1) }
            let storage = NativeValueStorage(size: size, alignment: alignment)
            storage.initialize(value.load(as: Value.self))
            return storage
        }
        return Self(
            Value.self,
            kind: .identity,
            schema: schema,
            operations: Operations(
                encode: { value, _, _, _ in encode(value) },
                encodeResult: { value, _ in encode(value) },
                encodeCopy: { value, _ in (encode(value), false) },
                makeStorage: { NativeValueStorage(size: size, alignment: alignment) },
                decode: { storage, _, _, output in
                    if requiresValue, storage.address.load(as: UnsafeRawPointer?.self) == nil {
                        throw ABIInvocationError.unexpectedNilResult(
                            expected: String(reflecting: Value.self)
                        )
                    }
                    // A Swift result is +1. Taking it avoids adding another
                    // retain or destroying bytes whose ownership has moved.
                    constants.initialize(at: storage.address)
                    output.initializeMemory(
                        as: Value.self,
                        repeating: storage.take(as: Value.self),
                        count: 1
                    )
                },
                callbackDecoder: { convention, _, _ in
                    if convention == .consuming {
                        return { address, _ in
                            inputConstants.initialize(at: address)
                            return address.assumingMemoryBound(to: Value.self).move()
                        }
                    }
                    return { address, _ in inputConstants.load(from: address, as: Value.self) }
                },
                validateOwnedResult: {}
            )
        )
    }

    /// An `ABIBridgeValue` adapter, which passes its C representation.
    private static func adapter<Value>(_: Value.Type, schema: SwiftValueSchema) throws -> Self {
        let codec = try CValueCodec<Value>()
        let type = codec.type
        @Sendable func encode(_ value: UnsafeRawPointer) throws -> NativeValueStorage {
            try codec.encode(value.load(as: Value.self))
        }
        return Self(
            Value.self,
            kind: .adapter,
            schema: schema,
            operations: Operations(
                encode: { value, _, _, _ in try encode(value) },
                encodeResult: { value, _ in try encode(value) },
                encodeCopy: { value, _ in (try encode(value), false) },
                makeStorage: { NativeValueStorage(size: type.size, alignment: type.alignment) },
                decode: { storage, owner, _, output in
                    output.initializeMemory(
                        as: Value.self,
                        repeating: try codec.decode(storage, retaining: owner),
                        count: 1
                    )
                },
                callbackDecoder: { _, _, _ in
                    { address, scope in
                        let storage = NativeValueStorage(borrowing: address, owner: scope)
                        return try codec.decode(storage, retaining: storage)
                    }
                },
                validateOwnedResult: {}
            )
        )
    }

    /// A closure. With a native plan, its function is reabstracted to that
    /// plan's convention.
    private static func closure<Value>(
        _: Value.Type,
        plan: SwiftGenericClosurePlan?,
        codec: SwiftClosureCodec?
    ) throws -> Self {
        let closure = SwiftClosureConversion(
            host: Value.self as! any SwiftClosureValue.Type,
            plan: plan,
            codec: codec
        )
        let pointer = try CValueType(scalar: ABIValuePointer)
        let type = try CValueType(fields: [pointer, pointer])
        @Sendable func encodeResult(_ value: UnsafeRawPointer, _ owner: Any?) throws
            -> NativeValueStorage
        {
            let value = value.load(as: Value.self)
            return try closure.codec().encodeValue?(value, owner)
                ?? (value as! any SwiftClosureValue).encodeClosureResult()
        }
        return Self(
            Value.self,
            kind: .closure(closure),
            schema: SwiftValueSchema(type: type, kind: .function, metadata: nil),
            operations: Operations(
                encode: { value, convention, asynchronous, owner in
                    let value = value.load(as: Value.self) as! any SwiftClosureValue
                    guard let plan else {
                        return try value.encodeClosure(consuming: convention == .consuming)
                    }
                    return try value.encodeGenericClosure(
                        plan: plan,
                        retainingCode: owner,
                        asynchronous: asynchronous,
                        consuming: convention == .consuming
                    )
                },
                encodeResult: encodeResult,
                encodeCopy: { value, owner in (try encodeResult(value, owner), false) },
                makeStorage: {
                    NativeValueStorage(
                        size: type.size,
                        alignment: type.alignment,
                        codeLifetime: SwiftValueCodeLifetime([])
                    )
                },
                decode: { storage, _, codeOwner, output in
                    let value = storage.address.load(as: ABISwiftClosureValue.self)
                    // Adopting the closure consumes its +1 even when
                    // preparing its entry fails.
                    storage.relinquishValue()
                    let host = try closure.codec().makeValue(
                        value,
                        codeOwner,
                        true,
                        storage.codeLifetime
                    )
                    output.initializeMemory(as: Value.self, repeating: host as! Value, count: 1)
                },
                callbackDecoder: { convention, _, _ in
                    let codec = try closure.codec()
                    if convention == .consuming {
                        guard let take = codec.takeValue else {
                            throw ABIResolutionError.unsupportedDeclaration(
                                "This closure representation cannot own native callback inputs."
                            )
                        }
                        return { address, _ in
                            take(
                                address.load(as: ABISwiftClosureValue.self),
                                SwiftValueCodeLifetime.current
                            )
                        }
                    }
                    guard let borrow = codec.borrowValue else {
                        throw ABIResolutionError.unsupportedDeclaration(
                            "This closure representation cannot borrow native callback inputs."
                        )
                    }
                    return { borrow($1.borrow($0), SwiftValueCodeLifetime.current) }
                },
                validateOwnedResult: {}
            )
        )
    }

    /// A runtime value handle for the native value `plan` describes.
    private static func runtimeValue<Value>(
        _: Value.Type,
        plan: SwiftRuntimeValuePlan
    ) throws -> Self {
        let pointer = try CValueType(scalar: ABIValuePointer)
        @Sendable func encodeResult(_ value: UnsafeRawPointer, _: Any?) throws
            -> NativeValueStorage
        {
            try plan.encode(value.load(as: Value.self), convention: .consuming, asynchronous: false)
        }
        return Self(
            Value.self,
            kind: .runtimeValue(plan),
            schema: SwiftValueSchema(storage: plan.type, metadata: plan.valueType.metadata),
            operations: Operations(
                encode: { value, convention, asynchronous, _ in
                    let access = try plan.encodeArgument(
                        value.load(as: Value.self),
                        convention: convention,
                        asynchronous: asynchronous
                    )
                    guard convention == .inoutValue else { return access }
                    let storage = NativeValueStorage(
                        size: pointer.size,
                        alignment: pointer.alignment,
                        owner: access,
                        codeLifetime: access.codeLifetime
                    )
                    storage.store(UnsafeRawPointer(access.address))
                    storage.prepareWriteback = access.prepareWriteback
                    return storage
                },
                encodeResult: encodeResult,
                encodeCopy: { value, _ in
                    guard SwiftCopyability.accepts(plan.valueType.metadata) else {
                        throw NativeSwiftValueError.noncopyableType
                    }
                    let access = try plan.encode(
                        value.load(as: Value.self),
                        convention: .borrowing,
                        asynchronous: false
                    )
                    return (access, true)
                },
                makeStorage: { plan.makeStorage() },
                decode: { storage, _, _, output in
                    guard
                        SwiftGenericCallPlan.runtimeHandle(Value.self)?.type
                            != NativeSwiftBorrowedValue.self
                    else {
                        throw ABIResolutionError.unsupportedDeclaration(
                            "A scoped runtime tuple field requires its callback borrow scope."
                        )
                    }
                    let value = try plan.hostValue(plan.decode(storage))
                    output.initializeMemory(as: Value.self, repeating: value as! Value, count: 1)
                },
                callbackDecoder: { convention, asynchronous, _ in
                    try runtimeCallbackDecoder(
                        Value.self,
                        plan: plan,
                        convention: convention,
                        asynchronous: asynchronous
                    )
                },
                validateOwnedResult: { try plan.requireOwnedValue(as: Value.self) }
            )
        )
    }

    /// A decoder of a native callback input as the runtime value handle
    /// `Value`, which `NativeSwiftValue?` and `NativeSwiftBorrowedValue?`
    /// receive as the Optional's payload or nil.
    private static func runtimeCallbackDecoder<Value>(
        _: Value.Type,
        plan: SwiftRuntimeValuePlan,
        convention: SwiftArgumentConvention,
        asynchronous: Bool
    ) throws -> SwiftCallbackDecoder {
        let consuming = convention == .consuming
        let borrowed =
            SwiftGenericCallPlan.runtimeHandle(Value.self)?.type == NativeSwiftBorrowedValue.self
        if borrowed {
            guard !consuming else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "A borrowed runtime value cannot be consumed."
                )
            }
        } else {
            try plan.requireOwnedValue()
            if !consuming, !SwiftCopyability.accepts(plan.valueType.metadata) {
                throw NativeSwiftValueError.noncopyableType
            }
        }
        let decode: SwiftCallbackDecoder = { address, scope in
            if consuming, let value = scope.runtimeInput(at: address) { return value }
            let lifetime = SwiftValueCodeLifetime.current ?? plan.valueType.codeLifetime
            SwiftValueCodeLifetime.connect(
                [lifetime, plan.valueType.codeLifetime],
                retaining: []
            )
            let nativeType = plan.valueType
            if let tuple = plan.nativeTuple, convention != .inoutValue {
                let materialized = tuple.materializeArgument(
                    from: address,
                    consuming: consuming
                )
                if consuming {
                    let value = plan.takeCallbackArgument(
                        from: materialized.address,
                        type: nativeType
                    )
                    materialized.relinquishValue()
                    return value
                }
                plan.normalizeCallbackArgument(materialized)
                if borrowed {
                    return NativeSwiftBorrowedValue(
                        type: nativeType,
                        borrow: scope.borrow(
                            materialized.address,
                            retaining: materialized,
                            allowsSuspension: asynchronous
                        )
                    )
                }
                return NativeSwiftValue(storage: materialized, type: nativeType)
            }
            if consuming { return plan.takeCallbackArgument(from: address, type: nativeType) }
            let restored =
                convention == .inoutValue ? nil : plan.restoredCallbackArgument(from: address)
            let source =
                convention == .inoutValue
                ? address.load(as: UnsafeMutableRawPointer.self) : restored?.address ?? address
            if borrowed {
                if plan.hasClosureConversions {
                    let canonical = plan.copyCallbackStorage(from: source, type: nativeType)
                    if convention == .inoutValue {
                        scope.prepareWriteback {
                            plan.prepareCallbackWriteback(from: canonical, to: source)
                        }
                    }
                    return NativeSwiftBorrowedValue(
                        type: nativeType,
                        borrow: scope.borrow(
                            canonical.address,
                            retaining: canonical,
                            allowsSuspension: asynchronous,
                            allowsMutation: convention == .inoutValue
                        )
                    )
                }
                return NativeSwiftBorrowedValue(
                    type: nativeType,
                    borrow: scope.borrow(
                        source,
                        retaining: restored,
                        allowsSuspension: asynchronous,
                        allowsMutation: convention == .inoutValue
                    )
                )
            }
            return plan.copyCallbackArgument(from: source, type: nativeType)
        }
        guard plan.projection != nil else { return decode }
        return { address, scope in
            let value = try decode(address, scope)
            if let owned = value as? NativeSwiftValue {
                // A consumed input can be the canonical handle a hook keeps
                // for recovery, so its payload comes from a copy.
                return try plan.hostValue(consuming ? owned.copy() : owned)
            }
            return try plan.hostValue(value as! NativeSwiftBorrowedValue)
        }
    }

    /// A tuple whose fields `plan` converts.
    private static func tuple<Value>(_: Value.Type, plan: SwiftTupleValuePlan) -> Self {
        @Sendable func destroy(_ value: UnsafeMutableRawPointer) {
            ABISwiftDestroyValue(unsafeBitCast(plan.nativeMetadata, to: UnsafeRawPointer.self), value)
        }
        return Self(
            Value.self,
            kind: .tuple(plan),
            schema: SwiftValueSchema(type: plan.type, kind: .tuple, metadata: plan.nativeMetadata),
            operations: Operations(
                encode: { value, convention, asynchronous, owner in
                    try plan.encodeArgument(
                        fromHost: value,
                        consuming: convention == .consuming,
                        asynchronous: asynchronous,
                        retainingCode: owner
                    )
                },
                encodeResult: { value, owner in
                    let initialize = try plan.prepareResult(fromHost: value, retainingCode: owner)
                    let storage = plan.makeResultStorage()
                    initialize(storage.address)
                    storage.assumeInitialized(destroyingWith: destroy)
                    return storage
                },
                encodeCopy: { value, owner in
                    let initialize = try plan.prepareNativeCopy(fromHost: value, retainingCode: owner)
                    let storage = plan.makeResultStorage()
                    initialize(storage.address)
                    storage.assumeInitialized(destroyingWith: destroy)
                    return (storage, false)
                },
                makeStorage: { plan.makeResultStorage() },
                decode: { storage, owner, codeOwner, output in
                    output.initializeMemory(
                        as: Value.self,
                        repeating: try plan.decodeResult(
                            storage,
                            retaining: owner,
                            retainingCode: codeOwner,
                            as: Value.self
                        ),
                        count: 1
                    )
                },
                callbackDecoder: { convention, _, _ in
                    try plan.callbackDecoder(consuming: convention == .consuming)
                },
                validateOwnedResult: { try plan.validateOwnedResult() }
            )
        )
    }

    /// An ownership wrapper of the host type `Wrapper` around `value`.
    ///
    /// - Parameters:
    ///   - type: The storage with which the wrapper passes its value.
    ///   - encode: Passes the wrapper's value with its convention.
    ///   - callbackDecoder: Wraps a callback input for the host, given the
    ///     callback's error type.
    static func ownership<Wrapper>(
        _: Wrapper.Type,
        convention: SwiftArgumentConvention,
        value: SwiftHostConversion,
        type: CValueType,
        encode: @escaping @Sendable (Wrapper, Any?) throws -> NativeValueStorage,
        callbackDecoder: @escaping @Sendable (Any.Type) throws -> SwiftCallbackDecoder
    ) -> Self {
        @Sendable func unsupported() -> ABIResolutionError {
            .unsupportedDeclaration(
                "Swift argument convention markers require the invocation argument path; results and managed callbacks cannot use them."
            )
        }
        return Self(
            Wrapper.self,
            kind: .ownership(convention, value),
            schema: convention == .inoutValue
                ? SwiftValueSchema(type: type, kind: .scalar, metadata: nil)
                : SwiftValueSchema(type: type, kind: value.schema.kind, metadata: value.schema.metadata),
            operations: Operations(
                encode: { wrapper, _, _, owner in
                    try encode(wrapper.load(as: Wrapper.self), owner)
                },
                encodeResult: { _, _ in throw unsupported() },
                encodeCopy: { _, _ in throw unsupported() },
                makeStorage: {
                    preconditionFailure("An ownership wrapper is not a result.")
                },
                decode: { _, _, _, _ in throw unsupported() },
                callbackDecoder: { _, _, failure in try callbackDecoder(failure) },
                validateOwnedResult: { throw unsupported() }
            )
        )
    }
}

// MARK: - Closures

/// The closure conversion of a host closure type, with the native plan its
/// function is reabstracted to, if any.
///
/// The codec that wraps native functions for the host is prepared when a
/// position first decodes one; a call's arguments only encode.
final class SwiftClosureConversion: Sendable {
    let host: any SwiftClosureValue.Type
    let plan: SwiftGenericClosurePlan?
    private let prepared: Mutex<SwiftClosureCodec?>

    init(host: any SwiftClosureValue.Type, plan: SwiftGenericClosurePlan?, codec: SwiftClosureCodec?) {
        self.host = host
        self.plan = plan
        prepared = Mutex(codec)
    }

    func codec() throws -> SwiftClosureCodec {
        if let codec = prepared.withLock({ $0 }) { return codec }
        let codec = try plan.map(host.makeGenericClosureCodec) ?? host.makeClosureCodec()
        return prepared.withLock { prepared in
            if let prepared { return prepared }
            prepared = codec
            return codec
        }
    }

    /// The native type of a value of the host type `host` in a closure's
    /// signature: a closure's native function type, with its parameters and
    /// result mapped alike, a tuple of its elements' native types, or `host`
    /// itself.
    static func nativeType(of host: Any.Type) throws -> Any.Type {
        if let closure = host as? any SwiftClosureValue.Type, closure.isOptional {
            func optional<Wrapped>(_: Wrapped.Type) -> Any.Type { Wrapped?.self }
            return try _openExistential(
                nativeType(of: (host as! any NativeOptionalValue.Type).wrappedType),
                do: optional
            )
        }
        if let closure = host as? any SwiftClosureValue.Type {
            let function = closure.swiftFunctionType
            let signature = try SwiftFunctionSignature(function)
            var parameterFlags = Array(repeating: UInt32(0), count: signature.parameters.count)
            let parameters = try signature.parameters.enumerated().map { index, type -> Any.Type in
                if let convention = type as? any SwiftConventionArgument.Type {
                    parameterFlags[index] =
                        switch convention.convention {
                        case .inoutValue: 1
                        case .borrowing: 2
                        case .consuming: 3
                        }
                    return try nativeType(of: convention.wrappedType)
                }
                return try nativeType(of: type)
            }
            let result = try nativeType(of: signature.result)
            return try withRuntimeErrors {
                try RuntimeFunctionMetadata(function).replacing(
                    parameters: parameters,
                    result: result,
                    parameterFlags: parameterFlags
                )
            }
        }
        guard let tuple = SwiftTupleMetadata(host) else { return host }
        return try SwiftTupleValuePlan.tupleMetadata(
            tuple.elements.map { try nativeType(of: $0.type) },
            labels: tuple.labels,
            replacing: host,
            elements: tuple.elements
        )
    }
}

// MARK: - Transfers

/// The native values one invocation passes: the storage of each argument,
/// which arguments native code consumes, and the writebacks of inout
/// arguments, which the invocation commits when it finishes.
final class SwiftValueTransfer {
    let storage: [NativeValueStorage]
    private let consumes: [Bool]

    init(storage: [NativeValueStorage], consumes: [Bool]) {
        self.storage = storage
        self.consumes = consumes
    }

    var addresses: [UnsafeMutableRawPointer?] { storage.map(\.address) }

    /// The code lifetimes the arguments' native values need.
    var codeLifetimes: [SwiftValueCodeLifetime] { storage.compactMap(\.codeLifetime) }

    /// Gives up the values native code consumed, after it returns.
    func relinquishConsumed() {
        for (value, consumes) in zip(storage, consumes) where consumes {
            value.relinquishValue()
        }
    }

    /// Destroys the copies that consumed arguments transferred, once a hook
    /// has passed them on.
    func finishCopiedTransfers() {
        for (value, consumes) in zip(storage, consumes)
        where consumes && value.transfersOwnership {
            guard let destroy = value.destroyTransferredCopy else { continue }
            destroy()
            value.relinquishValue()
        }
    }

    /// The invocation's outcome, after committing every writeback. A
    /// writeback that fails to convert reports its error and commits none.
    func finish<Output: ~Copyable>(
        _ outcome: consuming Swift.Result<Output, any Error>
    ) throws -> Output {
        try finishSwiftInvocation(outcome) {
            let commits = try storage.compactMap(\.prepareWriteback).map { try $0() }
            for commit in commits { commit() }
        }
    }
}
