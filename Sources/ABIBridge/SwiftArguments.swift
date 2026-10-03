import ABIBridgeCore

enum SwiftArgumentConvention: Sendable, Equatable {
    case borrowing, consuming, inoutValue
}

struct SwiftConventionCodec: Sendable {
    let type: CValueType
    let consumes: Bool
    let convention: SwiftArgumentConvention
    let argument: SwiftGenericArgument
    let prepareCallback: @Sendable (Any.Type) throws -> SwiftCallbackDecoder
    let encode: @Sendable (Any, Any?) throws -> NativeValueStorage
}
protocol SwiftConventionArgument: SendableMetatype {
    static var wrappedType: Any.Type { get }
    static var convention: SwiftArgumentConvention { get }
    static func makeArgumentCodec(generic: SwiftGenericArgument) throws -> SwiftConventionCodec
}

func swiftArgumentTypeName(_ type: Any.Type, defaultConsuming: Bool) throws -> String {
    guard let argument = type as? any SwiftConventionArgument.Type else {
        return try swiftFunctionTypeName(type)
    }
    let name = try swiftFunctionTypeName(argument.wrappedType)
    switch argument.convention {
    case .inoutValue: return "inout " + name
    case .borrowing: return (defaultConsuming ? "__shared " : "") + name
    case .consuming: return (defaultConsuming ? "" : "__owned ") + name
    }
}

struct SwiftArgumentCodec<Value>: Sendable {
    let type: CValueType
    let consumes: Bool
    private enum Encoding: Sendable {
        case ordinary(SwiftValueCodec<Value>)
        case explicit(SwiftConventionCodec)
        case genericValue
        case genericClosure(SwiftGenericClosurePlan, asynchronous: Bool)
        case runtimeValue(SwiftRuntimeValuePlan, SwiftArgumentConvention, asynchronous: Bool)
        case tuple(SwiftTupleValuePlan, asynchronous: Bool)
    }
    private let encoding: Encoding

    init(defaultConsuming: Bool, generic: SwiftGenericArgument = .concrete, asynchronous: Bool = false) throws {
        switch generic {
        case .convention(let codec):
            type = codec.type; consumes = codec.consumes
            encoding = .explicit(codec)
        case .value(let nativeType, let consuming):
            type = nativeType
            consumes = consuming || defaultConsuming
            encoding = .genericValue
        case .closure(let plan, let asynchronous):
            let pointer = try CValueType(scalar: ABIValuePointer)
            type = try CValueType(fields: [pointer, pointer])
            consumes = defaultConsuming
            encoding = .genericClosure(plan, asynchronous: asynchronous)
        case .runtimeValue(let plan, let convention, let asynchronous):
            type = convention == .inoutValue ? try CValueType(scalar: ABIValuePointer) : plan.type
            consumes = convention == .consuming
            encoding = .runtimeValue(plan, convention, asynchronous: asynchronous)
        case .tuple(let plan, let consuming, let asynchronous):
            type = plan.type; consumes = consuming || defaultConsuming
            encoding = .tuple(plan, asynchronous: asynchronous)
        case .concrete:
            if let argument = Value.self as? any SwiftConventionArgument.Type {
                let nested: SwiftGenericArgument
                if asynchronous, let closure = argument.wrappedType as? any SwiftClosureValue.Type {
                    nested = .closure(try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType), asynchronous: true)
                } else { nested = .concrete }
                let codec = try argument.makeArgumentCodec(generic: nested)
                type = codec.type; consumes = codec.consumes
                encoding = .explicit(codec)
            } else if let tuple = try SwiftGenericCallPlan.concreteTuple(Value.self) {
                type = tuple.type; consumes = defaultConsuming
                encoding = .tuple(tuple, asynchronous: asynchronous)
            } else {
                let codec = try SwiftValueCodec<Value>()
                type = codec.type; consumes = defaultConsuming
                if asynchronous, let closure = Value.self as? any SwiftClosureValue.Type {
                    encoding = .genericClosure(try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType), asynchronous: true)
                } else { encoding = .ordinary(codec) }
            }
        }
    }

    func encode(_ value: Value, retainingCode owner: Any? = nil) throws -> NativeValueStorage {
        switch encoding {
        case .ordinary(let codec): return try codec.encode(value, consuming: consumes)
        case .explicit(let codec): return try codec.encode(value, owner)
        case .genericClosure(let plan, let asynchronous):
            return try (value as! any SwiftClosureValue).encodeGenericClosure(plan: plan, retainingCode: owner, asynchronous: asynchronous, consuming: consumes)
        case .runtimeValue(let plan, let convention, let asynchronous):
            let access = try plan.encodeArgument(value, convention: convention, asynchronous: asynchronous)
            guard convention == .inoutValue else { return access }
            let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: access, codeLifetime: access.codeLifetime)
            pointer.store(UnsafeRawPointer(access.address))
            pointer.prepareWriteback = access.prepareWriteback
            return pointer
        case .tuple(let plan, let asynchronous):
            return try withUnsafePointer(to: value) {
                try plan.encodeArgument(fromHost: $0, consuming: consumes,
                    asynchronous: asynchronous, retainingCode: owner)
            }
        case .genericValue:
            // The callee receives Value's metadata and operates on Value itself,
            // even when Value also provides a different foreign representation.
            let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
            storage.initialize(value)
            return storage
        }
    }
}

private func swiftConventionCodec<Value>(for type: Value.Type, generic: SwiftGenericArgument, consumes: Bool,
                                        wrap: @escaping @Sendable (Value) -> Any,
                                        unwrap: @escaping @Sendable (Any) -> Value) throws -> SwiftConventionCodec {
    let codec = try SwiftArgumentCodec<Value>(defaultConsuming: consumes, generic: generic)
    return SwiftConventionCodec(type: codec.type, consumes: consumes, convention: consumes ? .consuming : .borrowing,
        argument: generic, prepareCallback: { _ in
        let decode = try SwiftCallbackValues.decoder(for: Value.self, generic: generic, consuming: consumes)
        return { wrap(try decode($0, $1) as! Value) }
    }) { value, owner in
        try codec.encode(unwrap(value), retainingCode: owner)
    }
}

/// An explicit borrowed Swift argument, including a borrowed initializer argument.
/// The encoded value remains owned by the bridge throughout the call.
public struct NativeSwiftBorrowing<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension NativeSwiftBorrowing: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .borrowing }
    static func makeArgumentCodec(generic: SwiftGenericArgument) throws -> SwiftConventionCodec {
        try swiftConventionCodec(for: Value.self, generic: generic, consumes: false, wrap: { Self($0) }) { ($0 as! Self).value }
    }
}
extension NativeSwiftBorrowing: Sendable where Value: Sendable {}

/// Transfers an owned Swift argument across a native call or callback boundary.
/// In a host callback, value owns the argument received from native code;
/// a NativeSwiftValue takes the payload directly, including noncopyable types.
/// A NativeSwiftValue transfers its existing value and becomes consumed; other
/// Swift values supply an independently encoded copy and remain usable.
/// Native code owns the transferred value on successful or throwing completion.
/// Foreign value conversions cannot assert
/// Swift destruction semantics; use an actual Swift representation for this mode.
public struct NativeSwiftConsuming<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension NativeSwiftConsuming: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .consuming }
    static func makeArgumentCodec(generic: SwiftGenericArgument) throws -> SwiftConventionCodec {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let usesNativeStorage: Bool
        switch generic {
        case .value, .runtimeValue: usesNativeStorage = true
        default: usesNativeStorage = false
        }
        guard usesNativeStorage || !(base is any ABIBridgeValue.Type) || Value.self is any ABIBridgeSwiftValue.Type else {
            throw ABIResolutionError.unsupportedDeclaration("Consuming arguments require an actual Swift value representation and its owned copy.")
        }
        return try swiftConventionCodec(for: Value.self, generic: generic, consumes: true, wrap: { Self($0) }) { ($0 as! Self).value }
    }
}
extension NativeSwiftConsuming: Sendable where Value: Sendable {}

/// An owned typed buffer for a native Swift inout argument.
/// Read value after a call completes, including a throwing call. Mutation is
/// performed in this buffer and does not assign back to the original input.
/// For NativeSwiftValue, the buffer retains the same runtime owner and grants
/// exclusive access to its native payload instead of copying it.
/// The caller gives native code exclusive access for the entire invocation,
/// including suspension: do not read, write, or alias this buffer during it.
/// A callback with a known Swift pointee receives a local buffer whose value is
/// written back before callback completion, even on error. Runtime-only inout
/// callback inputs use NativeSwiftBorrowedValue to access the original payload.
/// Converted pointees use temporary native storage. Their host values are
/// replaced only after all argument writeback conversions succeed; a failed
/// conversion does not undo native side effects. A host callback writing back
/// a converted closure uses throws(any Error) to report conversion failures.
/// This buffer is deliberately not Sendable.
public final class NativeSwiftInout<Value> {
    private let storage: NativeValueStorage

    public init(_ value: Value) {
        storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
        storage.initialize(value)
    }

    /// The current Swift value. Access only while no native invocation uses the buffer.
    public var value: Value {
        get { storage.address.load(as: Value.self) }
        set { storage.address.assumingMemoryBound(to: Value.self).pointee = newValue }
    }

    private static func validatePointee() throws {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        guard !(base is any ABIBridgeValue.Type) || Value.self is any ABIBridgeSwiftValue.Type else {
            throw ABIResolutionError.unsupportedDeclaration("Inout buffers require actual Swift value storage, not a converted foreign representation.")
        }
        _ = try SwiftValueCodec<Value>()
    }

    private func encoded() -> NativeValueStorage {
        let result = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                                        alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: self)
        result.store(UnsafeRawPointer(storage.address))
        return result
    }

    private static func callbackDecoder() -> SwiftCallbackDecoder {
        return { argument, scope in
            let address = argument.load(as: UnsafeMutableRawPointer.self)
            let buffer = Self(address.load(as: Value.self))
            scope.prepareWriteback {
                let updated = buffer.value
                return { address.assumingMemoryBound(to: Value.self).pointee = updated }
            }
            return buffer
        }
    }

    private static func closureCodec(_ closure: any SwiftClosureValue.Type,
                                     generic: SwiftGenericArgument) throws -> SwiftConventionCodec {
        let codec: SwiftClosureCodec
        if case .closure(let plan, _) = generic { codec = try closure.makeGenericClosureCodec(plan: plan) }
        else { codec = try closure.makeClosureCodec() }
        let encode: @Sendable (Any, Any?) throws -> NativeValueStorage = { value, owner in
            try codec.encodeValue?(value, owner) ?? (value as! any SwiftClosureValue).encodeClosureResult()
        }
        return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false,
            convention: .inoutValue, argument: generic, prepareCallback: { failure in
                guard failure == (any Error).self else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A host callback writing back a converted closure requires throws(any Error) to report ownership and conversion failures.")
                }
                return { argument, scope in
                    let address = argument.load(as: UnsafeMutableRawPointer.self)
                    let lifetime = SwiftValueCodeLifetime.current
                    let value = try codec.makeValue(address.load(as: ABISwiftClosureValue.self), nil, false, lifetime)
                    let buffer = Self(value as! Value)
                    scope.prepareWriteback {
                        let replacement = try encode(buffer.value, lifetime)
                        SwiftValueCodeLifetime.connect([lifetime, replacement.codeLifetime].compactMap { $0 }, retaining: [])
                        return {
                            let previous = address.load(as: ABISwiftClosureValue.self)
                            address.copyMemory(from: replacement.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
                            replacement.relinquishValue()
                            ABIReleaseSwiftClosureContext(previous.context)
                        }
                    }
                    return buffer
                }
            }) { value, owner in
                let buffer = value as! Self
                let native = try encode(buffer.value, owner)
                let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                    alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: native, codeLifetime: native.codeLifetime)
                pointer.store(UnsafeRawPointer(native.address))
                pointer.prepareWriteback = {
                    let updated = try codec.makeValue(native.address.load(as: ABISwiftClosureValue.self), owner,
                        false, native.codeLifetime) as! Value
                    return { buffer.value = updated }
                }
                return pointer
            }
    }

    private static func tupleCodec(_ plan: SwiftTupleValuePlan,
                                   generic: SwiftGenericArgument) throws -> SwiftConventionCodec {
        try plan.validateOwnedResult()
        let encode: @Sendable (Value, Any?) throws -> NativeValueStorage = { value, owner in
            let metadata = unsafeBitCast(plan.nativeMetadata, to: UnsafeRawPointer.self)
            let native = plan.makeResultStorage()
            try SwiftValueCodeLifetime.withCurrent(native.codeLifetime) {
                let initialize = try withUnsafePointer(to: value) {
                    try plan.prepareNativeCopy(fromHost: $0, retainingCode: owner)
                }
                initialize(native.address)
            }
            native.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
            return native
        }
        return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false,
            convention: .inoutValue, argument: generic, prepareCallback: { failure in
                guard failure == (any Error).self else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A host callback writing back a converted tuple requires throws(any Error) to report ownership and conversion failures.")
                }
                return { argument, scope in
                    let metadata = unsafeBitCast(plan.nativeMetadata, to: UnsafeRawPointer.self)
                    let address = argument.load(as: UnsafeMutableRawPointer.self)
                    let lifetime = SwiftValueCodeLifetime.current
                    let buffer = Self(try plan.copyNativeValue(from: address, retainingCode: lifetime,
                        codeLifetime: lifetime, as: Value.self))
                    scope.prepareWriteback {
                        let replacement = try encode(buffer.value, lifetime)
                        let previous = plan.makeResultStorage()
                        return {
                            ABISwiftTakeValue(metadata, previous.address, address)
                            previous.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
                            ABISwiftTakeValue(metadata, address, replacement.address)
                            replacement.relinquishValue()
                        }
                    }
                    return buffer
                }
            }) { value, owner in
                let buffer = value as! Self
                let native = try encode(buffer.value, owner)
                let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                    alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: native, codeLifetime: native.codeLifetime)
                pointer.store(UnsafeRawPointer(native.address))
                pointer.prepareWriteback = {
                    let updated = try plan.copyNativeValue(from: native.address, retainingCode: owner,
                        codeLifetime: native.codeLifetime, as: Value.self)
                    return { buffer.value = updated }
                }
                return pointer
            }
    }
}
extension NativeSwiftInout: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .inoutValue }
    static func makeArgumentCodec(generic: SwiftGenericArgument) throws -> SwiftConventionCodec {
        // Preparing a signature must establish the pointee contract even before
        // an actual buffer is supplied.
        if case .runtimeValue(let plan, _, let asynchronous) = generic {
            guard Value.self == NativeSwiftValue.self || Value.self == NativeSwiftBorrowedValue.self else {
                throw ABIResolutionError.unsupportedDeclaration("Inout runtime arguments require a runtime value handle.")
            }
            return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false, convention: .inoutValue, argument: generic,
                prepareCallback: { _ in throw ABIResolutionError.unsupportedDeclaration("Use NativeSwiftBorrowedValue for a runtime inout callback input.") }) { value, _ in
                let access = try plan.encode((value as! Self).value, convention: .inoutValue, asynchronous: asynchronous)
                let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                    alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: access, codeLifetime: access.codeLifetime)
                pointer.store(UnsafeRawPointer(access.address))
                pointer.prepareWriteback = access.prepareWriteback
                return pointer
            }
        }
        if case .value = generic {} else {
            let tuple: SwiftTupleValuePlan?
            if case .tuple(let plan, _, _) = generic { tuple = plan }
            else { tuple = try SwiftGenericCallPlan.concreteTuple(Value.self) }
            if let tuple, tuple.needsConversion { return try tupleCodec(tuple, generic: generic) }
            if tuple != nil {
                return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false,
                    convention: .inoutValue, argument: generic,
                    prepareCallback: { _ in callbackDecoder() }) { value, _ in (value as! Self).encoded() }
            }
            if let closure = Value.self as? any SwiftClosureValue.Type {
                return try closureCodec(closure, generic: generic)
            }
            try Self.validatePointee()
        }
        return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false, convention: .inoutValue, argument: generic,
            prepareCallback: { _ in callbackDecoder() }) { value, _ in (value as! Self).encoded() }
    }
}
