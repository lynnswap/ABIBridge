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

    struct Operations: Sendable {
        /// Host to native: the storage that passes the value at the host
        /// address with an ownership convention, possibly asynchronously.
        let encode:
            @Sendable (UnsafeRawPointer, SwiftArgumentConvention, Bool, Any?) throws ->
                NativeValueStorage
        /// Storage for a native value that native code initializes.
        let makeStorage: @Sendable () -> NativeValueStorage
        /// Native to host: takes the owned native value in the storage and
        /// initializes the host value at the output address.
        let decode:
            @Sendable (NativeValueStorage, Any?, Any?, UnsafeMutableRawPointer) throws -> Void
        /// Native to host for a callback input, borrowed or consumed, given
        /// the callback's error type.
        let callbackDecoder: (@Sendable (Bool, Any.Type) throws -> SwiftCallbackDecoder)?
    }

    init(kind: Kind, host: Any.Type, schema: SwiftValueSchema, operations: Operations) {
        self.kind = kind
        self.host = host
        self.schema = schema
        self.operations = operations
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

    // MARK: Native to host

    func makeStorage() -> NativeValueStorage { operations.makeStorage() }

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

    /// A decoder of this position's callback input, which `consuming` owns.
    ///
    /// - Parameter failure: The callback's error type, which must be able to
    ///   report a failed writeback.
    func callbackDecoder(consuming: Bool, failure: Any.Type) throws -> SwiftCallbackDecoder? {
        try operations.callbackDecoder?(consuming, failure)
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
                return .identity(Value.self, schema: SwiftValueSchema(storage: type, metadata: Value.self))
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
                if let tuple = try SwiftGenericCallPlan.concreteTuple(Value.self, position: position) {
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
                return .identity(Value.self, schema: SwiftValueSchema(storage: type, metadata: Value.self))
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
            if let tuple = try SwiftGenericCallPlan.concreteTuple(Value.self, position: position),
                tuple.needsConversion
            {
                return .tuple(Value.self, plan: tuple)
            }
            if let closure = Value.self as? any SwiftClosureValue.Type {
                return try .closure(Value.self, plan: nil, codec: closure.makeClosureCodec())
            }
            let schema = try SwiftValueSchema.host(Value.self, position: position)
            if schema.kind == .scalar, schema.metadata == nil {
                return try .adapter(Value.self, schema: schema)
            }
            return .identity(Value.self, schema: schema)
        }
        self = try _openExistential(host, do: prepare)
    }
}

// MARK: - Kinds

extension SwiftHostConversion {
    /// The host value of `Value` is its native value, stored as `schema`.
    private static func identity<Value>(_: Value.Type, schema: SwiftValueSchema) -> Self {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        // A nonoptional reference or pointer has no nil value.
        let requiresValue =
            !(Value.self is any NativeOptionalValue.Type)
            && (base is AnyClass || base == AnyObject.self || base is any NativePointerValue.Type)
        let constants = SwiftValueConstants(Value.self)
        let size = max(MemoryLayout<Value>.stride, schema.type.size)
        let alignment = max(MemoryLayout<Value>.alignment, schema.type.alignment)
        return Self(
            kind: .identity,
            host: Value.self,
            schema: schema,
            operations: Operations(
                encode: { value, _, _, _ in
                    if Value.self == Void.self { return NativeValueStorage(size: 0, alignment: 1) }
                    let storage = NativeValueStorage(size: size, alignment: alignment)
                    storage.initialize(value.load(as: Value.self))
                    return storage
                },
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
                callbackDecoder: nil
            )
        )
    }

    /// An `ABIBridgeValue` adapter, which passes its C representation.
    private static func adapter<Value>(_: Value.Type, schema: SwiftValueSchema) throws -> Self {
        let codec = try CValueCodec<Value>()
        let type = codec.type
        return Self(
            kind: .adapter,
            host: Value.self,
            schema: schema,
            operations: Operations(
                encode: { value, _, _, _ in try codec.encode(value.load(as: Value.self)) },
                makeStorage: { NativeValueStorage(size: type.size, alignment: type.alignment) },
                decode: { storage, owner, _, output in
                    output.initializeMemory(
                        as: Value.self,
                        repeating: try codec.decode(storage, retaining: owner),
                        count: 1
                    )
                },
                callbackDecoder: nil
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
        return Self(
            kind: .closure(closure),
            host: Value.self,
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
                callbackDecoder: nil
            )
        )
    }

    /// A runtime value handle for the native value `plan` describes.
    private static func runtimeValue<Value>(
        _: Value.Type,
        plan: SwiftRuntimeValuePlan
    ) throws -> Self {
        let pointer = try CValueType(scalar: ABIValuePointer)
        return Self(
            kind: .runtimeValue(plan),
            host: Value.self,
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
                makeStorage: { plan.makeStorage() },
                decode: { storage, _, _, output in
                    let value = try plan.hostValue(plan.decode(storage))
                    output.initializeMemory(as: Value.self, repeating: value as! Value, count: 1)
                },
                callbackDecoder: nil
            )
        )
    }

    /// A tuple whose fields `plan` converts.
    private static func tuple<Value>(_: Value.Type, plan: SwiftTupleValuePlan) -> Self {
        Self(
            kind: .tuple(plan),
            host: Value.self,
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
                callbackDecoder: nil
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
        Self(
            kind: .ownership(convention, value),
            host: Wrapper.self,
            schema: convention == .inoutValue
                ? SwiftValueSchema(type: type, kind: .scalar, metadata: nil)
                : SwiftValueSchema(type: type, kind: value.schema.kind, metadata: value.schema.metadata),
            operations: Operations(
                encode: { wrapper, _, _, owner in
                    try encode(wrapper.load(as: Wrapper.self), owner)
                },
                makeStorage: {
                    preconditionFailure("An ownership wrapper is not a result.")
                },
                decode: { _, _, _, _ in
                    preconditionFailure("An ownership wrapper is not a result.")
                },
                callbackDecoder: { _, failure in try callbackDecoder(failure) }
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
