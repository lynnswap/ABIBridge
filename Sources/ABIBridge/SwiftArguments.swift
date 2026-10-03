import ABIBridgeCore

enum SwiftArgumentConvention: Sendable, Equatable {
    case borrowing, consuming, inoutValue
}

struct SwiftConventionCodec: Sendable {
    let type: CValueType
    let consumes: Bool
    let convention: SwiftArgumentConvention
    let argument: SwiftGenericArgument
    let prepareCallback: @Sendable () throws -> SwiftCallbackDecoder
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
        case genericClosure(SwiftGenericClosurePlan)
        case runtimeValue(SwiftRuntimeValuePlan, SwiftArgumentConvention, asynchronous: Bool)
    }
    private let encoding: Encoding

    init(defaultConsuming: Bool, generic: SwiftGenericArgument = .concrete) throws {
        switch generic {
        case .convention(let codec):
            type = codec.type; consumes = codec.consumes
            encoding = .explicit(codec)
        case .value(let nativeType, let consuming):
            type = nativeType
            consumes = consuming || defaultConsuming
            encoding = .genericValue
        case .closure(let plan):
            type = try SwiftValueCodec<Value>().type
            consumes = defaultConsuming
            encoding = .genericClosure(plan)
        case .runtimeValue(let plan, let convention, let asynchronous):
            type = convention == .inoutValue ? try CValueType(scalar: ABIValuePointer) : plan.type
            consumes = convention == .consuming
            encoding = .runtimeValue(plan, convention, asynchronous: asynchronous)
        case .concrete:
            if let argument = Value.self as? any SwiftConventionArgument.Type {
                let codec = try argument.makeArgumentCodec(generic: .concrete)
                type = codec.type; consumes = codec.consumes
                encoding = .explicit(codec)
            } else {
                let codec = try SwiftValueCodec<Value>()
                type = codec.type; consumes = defaultConsuming
                encoding = .ordinary(codec)
            }
        }
    }

    func encode(_ value: Value, retainingCode owner: Any? = nil) throws -> NativeValueStorage {
        switch encoding {
        case .ordinary(let codec): return try codec.encode(value)
        case .explicit(let codec): return try codec.encode(value, owner)
        case .genericClosure(let plan):
            return try (value as! any SwiftGenericClosureValue).encodeGenericClosure(plan: plan, retainingCode: owner)
        case .runtimeValue(let plan, let convention, let asynchronous):
            let access = try plan.encode(value, convention: convention, asynchronous: asynchronous)
            guard convention == .inoutValue else { return access }
            let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: access, codeLifetime: access.codeLifetime)
            pointer.store(UnsafeRawPointer(access.address))
            return pointer
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
        argument: generic, prepareCallback: {
        let decode = try SwiftCallbackValues.decoder(for: Value.self, generic: generic, consuming: consumes)
        return { wrap(decode($0, $1) as! Value) }
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
        guard !(Value.self is any SwiftClosureValue.Type),
              !(base is any ABIBridgeValue.Type) || Value.self is any ABIBridgeSwiftValue.Type else {
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
        let constants = SwiftValueConstants(Value.self)
        return { argument, scope in
            let address = argument.load(as: UnsafeMutableRawPointer.self)
            let buffer = Self(constants.load(from: address, as: Value.self))
            scope.writeback { address.assumingMemoryBound(to: Value.self).pointee = buffer.value }
            return buffer
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
                prepareCallback: { throw ABIResolutionError.unsupportedDeclaration("Use NativeSwiftBorrowedValue for a runtime inout callback input.") }) { value, _ in
                let access = try plan.encode((value as! Self).value, convention: .inoutValue, asynchronous: asynchronous)
                let pointer = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.size,
                    alignment: MemoryLayout<UnsafeRawPointer>.alignment, owner: access, codeLifetime: access.codeLifetime)
                pointer.store(UnsafeRawPointer(access.address))
                return pointer
            }
        }
        if case .value = generic {} else { try Self.validatePointee() }
        return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false, convention: .inoutValue, argument: generic,
            prepareCallback: { callbackDecoder() }) { value, _ in (value as! Self).encoded() }
    }
}
