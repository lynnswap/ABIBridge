import ABIBridgeCore

enum SwiftArgumentConvention: Sendable, Equatable {
    case borrowing, consuming, inoutValue
}

struct SwiftConventionCodec: Sendable {
    let type: CValueType
    let consumes: Bool
    let encode: @Sendable (Any) throws -> NativeValueStorage
}
protocol SwiftConventionArgument: SendableMetatype {
    static var wrappedType: Any.Type { get }
    static var convention: SwiftArgumentConvention { get }
    static func makeArgumentCodec(genericType: CValueType?) throws -> SwiftConventionCodec
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
            consumes = false
            encoding = .genericClosure(plan)
        case .concrete:
            if let argument = Value.self as? any SwiftConventionArgument.Type {
                let codec = try argument.makeArgumentCodec(genericType: nil)
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
        case .explicit(let codec): return try codec.encode(value)
        case .genericClosure(let plan):
            return try (value as! any SwiftGenericClosureValue).encodeGenericClosure(plan: plan, retainingCode: owner)
        case .genericValue:
            // The callee receives Value's metadata and operates on Value itself,
            // even when Value also provides a different foreign representation.
            let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
            storage.initialize(value)
            return storage
        }
    }
}

private func swiftConventionCodec<Value>(for type: Value.Type, genericType: CValueType?, consumes: Bool,
                                        unwrap: @escaping @Sendable (Any) -> Value) throws -> SwiftConventionCodec {
    let concrete = genericType == nil ? try SwiftValueCodec<Value>() : nil
    return SwiftConventionCodec(type: genericType ?? concrete!.type, consumes: consumes) { value in
        let value = unwrap(value)
        if let concrete { return try concrete.encode(value) }
        let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
        storage.initialize(value)
        return storage
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
    static func makeArgumentCodec(genericType: CValueType?) throws -> SwiftConventionCodec {
        try swiftConventionCodec(for: Value.self, genericType: genericType, consumes: false) { ($0 as! Self).value }
    }
}
extension NativeSwiftBorrowing: Sendable where Value: Sendable {}

/// Transfers an independently encoded owned copy of a Swift argument.
/// The original Swift value remains usable. Native code owns the copy on both
/// successful and throwing completion. Foreign value conversions cannot assert
/// Swift destruction semantics; use an actual Swift representation for this mode.
public struct NativeSwiftConsuming<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension NativeSwiftConsuming: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .consuming }
    static func makeArgumentCodec(genericType: CValueType?) throws -> SwiftConventionCodec {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        guard genericType != nil || !(base is any ABIBridgeValue.Type) || Value.self is any ABIBridgeSwiftValue.Type else {
            throw ABIResolutionError.unsupportedDeclaration("Consuming arguments require an actual Swift value representation and its owned copy.")
        }
        return try swiftConventionCodec(for: Value.self, genericType: genericType, consumes: true) { ($0 as! Self).value }
    }
}
extension NativeSwiftConsuming: Sendable where Value: Sendable {}

/// An owned typed buffer for a native Swift inout argument.
/// Read value after a call completes, including a throwing call. Mutation is
/// performed in this buffer and does not assign back to the original input.
/// The caller gives native code exclusive access for the entire invocation,
/// including suspension: do not read, write, or alias this buffer during it.
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
}
extension NativeSwiftInout: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .inoutValue }
    static func makeArgumentCodec(genericType: CValueType?) throws -> SwiftConventionCodec {
        // Preparing a signature must establish the pointee contract even before
        // an actual buffer is supplied.
        if genericType == nil { try Self.validatePointee() }
        return SwiftConventionCodec(type: try CValueType(scalar: ABIValuePointer), consumes: false) { ($0 as! Self).encoded() }
    }
}
