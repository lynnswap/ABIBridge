import ABIBridgeCore

enum SwiftArgumentConvention: Sendable, Equatable {
    case borrowing, consuming, inoutValue
}

protocol SwiftConventionArgument: SendableMetatype {
    static var wrappedType: Any.Type { get }
    static var convention: SwiftArgumentConvention { get }
    /// The conversion of this wrapper around a value that `generic` plans.
    static func makeConversion(generic: SwiftGenericArgument) throws -> SwiftHostConversion
    func retainingAsynchronousClosureArgument() throws -> Any
}

extension SwiftConventionArgument {
    func retainingAsynchronousClosureArgument() throws -> Any { self }
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

/// The conversion of a borrowing or consuming wrapper of the host type
/// `Wrapper`, whose value of the host type `Value` passes as `generic` plans.
private func swiftOwnershipConversion<Wrapper, Value>(
    _: Wrapper.Type,
    value: Value.Type,
    generic: SwiftGenericArgument,
    consumes: Bool,
    wrap: @escaping @Sendable (Value) -> Wrapper,
    unwrap: @escaping @Sendable (Wrapper) -> Value
) throws -> SwiftHostConversion {
    let argument = try SwiftCallValues.Argument(
        host: Value.self,
        plan: generic,
        defaultConsuming: consumes,
        asynchronous: false
    )
    return .ownership(
        Wrapper.self,
        convention: consumes ? .consuming : .borrowing,
        value: argument.conversion,
        type: argument.type,
        encode: { wrapper, owner in
            try withUnsafePointer(to: unwrap(wrapper)) {
                try argument.conversion.encode(
                    $0,
                    convention: argument.convention,
                    asynchronous: argument.asynchronous,
                    retainingCode: owner
                )
            }
        },
        callbackDecoder: { _ in
            let decode = try SwiftCallbackValues.decoder(
                for: Value.self,
                generic: generic,
                consuming: consumes
            )
            return { wrap(try decode($0, $1) as! Value) }
        }
    )
}

/// An explicit borrowed Swift argument, including a borrowed initializer argument. The encoded value remains owned by the bridge throughout the call.
public struct NativeSwiftBorrowing<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension NativeSwiftBorrowing: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .borrowing }
    func retainingAsynchronousClosureArgument() throws -> Any {
        Self(try swiftRetainingAsynchronousClosureArgument(value))
    }
    static func makeConversion(generic: SwiftGenericArgument) throws -> SwiftHostConversion {
        try swiftOwnershipConversion(
            Self.self,
            value: Value.self,
            generic: generic,
            consumes: false,
            wrap: { Self($0) }
        ) { $0.value }
    }
}
extension NativeSwiftBorrowing: Sendable where Value: Sendable {}

/// Transfers an owned Swift argument across a native call or callback boundary.
///
/// A `NativeSwiftValue` transfers its existing payload, including a noncopyable value, and becomes consumed. Other Swift values supply an independent encoded copy and remain usable. Native code owns the transferred value on successful or throwing completion.
///
/// In a host callback, `value` owns the incoming argument; `NativeSwiftValue` takes its payload directly. Use an actual Swift representation: foreign value conversions cannot establish Swift destruction semantics.
public struct NativeSwiftConsuming<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension NativeSwiftConsuming: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .consuming }
    func retainingAsynchronousClosureArgument() throws -> Any {
        Self(try swiftRetainingAsynchronousClosureArgument(value, consuming: true))
    }
    static func makeConversion(generic: SwiftGenericArgument) throws -> SwiftHostConversion {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let usesNativeStorage: Bool
        switch generic {
        case .value, .runtimeValue: usesNativeStorage = true
        default: usesNativeStorage = false
        }
        guard
            usesNativeStorage || !(base is any ABIBridgeValue.Type)
                || Value.self is any ABIBridgeSwiftValue.Type
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Consuming arguments require an actual Swift value representation and its owned copy."
            )
        }
        return try swiftOwnershipConversion(
            Self.self,
            value: Value.self,
            generic: generic,
            consumes: true,
            wrap: { Self($0) }
        ) { $0.value }
    }
}
extension NativeSwiftConsuming: Sendable where Value: Sendable {}

/// An owned typed buffer for a native Swift inout argument.
///
/// Read `value` after the call completes, including when it throws. Native mutations update this buffer, leaving the original input unchanged. A `NativeSwiftValue` buffer instead retains the same owner and gives native code exclusive access to its payload.
///
/// Give native code exclusive access for the entire invocation, including suspension: do not read, write, or alias the buffer during a call. The buffer is not `Sendable`.
///
/// A callback with a known Swift pointee receives a local buffer, written back before callback completion even on error. Runtime-only inout inputs use `NativeSwiftBorrowedValue` to access the original payload.
///
/// Converted pointees use temporary native storage. Host values are replaced only after every argument writeback conversion succeeds; a failure does not undo native effects. Converted closure writeback requires `throws(any Error)` to report failures. See <doc:SwiftArgumentConventions>.
public final class NativeSwiftInout<Value> {
    private let storage: NativeValueStorage

    public init(_ value: Value) {
        storage = NativeValueStorage(
            size: MemoryLayout<Value>.stride,
            alignment: MemoryLayout<Value>.alignment
        )
        storage.initialize(value)
    }

    /// The current Swift value. Access only while no native invocation uses the buffer.
    public var value: Value {
        get { storage.address.load(as: Value.self) }
        set { storage.address.assumingMemoryBound(to: Value.self).pointee = newValue }
    }

    private static func validatePointee() throws {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        guard !(base is any ABIBridgeValue.Type) || Value.self is any ABIBridgeSwiftValue.Type
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Inout buffers require actual Swift value storage, not a converted foreign representation."
            )
        }
    }

    private func encoded() -> NativeValueStorage {
        let result = NativeValueStorage(
            size: MemoryLayout<UnsafeRawPointer>.size,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment,
            owner: self
        )
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

    /// Storage holding the address of `native`, which passes it by reference.
    private static func reference(to native: NativeValueStorage) -> NativeValueStorage {
        let pointer = NativeValueStorage(
            size: MemoryLayout<UnsafeRawPointer>.size,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment,
            owner: native,
            codeLifetime: native.codeLifetime
        )
        pointer.store(UnsafeRawPointer(native.address))
        return pointer
    }

    /// An inout conversion of this buffer around `value`.
    private static func conversion(
        value: SwiftHostConversion,
        callbackDecoder: @escaping @Sendable (Any.Type) throws -> SwiftCallbackDecoder,
        encode: @escaping @Sendable (NativeSwiftInout<Value>, Any?) throws -> NativeValueStorage
    ) throws -> SwiftHostConversion {
        .ownership(
            Self.self,
            convention: .inoutValue,
            value: value,
            type: try CValueType(scalar: ABIValuePointer),
            encode: encode,
            callbackDecoder: callbackDecoder
        )
    }

    private static func closureConversion(
        _ value: SwiftHostConversion,
        closure: SwiftClosureConversion
    ) throws -> SwiftHostConversion {
        let codec = try closure.codec()
        let encode: @Sendable (Any, Any?) throws -> NativeValueStorage = { value, owner in
            try codec.encodeValue?(value, owner)
                ?? (value as! any SwiftClosureValue).encodeClosureResult()
        }
        return try conversion(
            value: value,
            callbackDecoder: { failure in
                guard failure == (any Error).self else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A host callback writing back a converted closure requires throws(any Error) to report ownership and conversion failures."
                    )
                }
                return { argument, scope in
                    let address = argument.load(as: UnsafeMutableRawPointer.self)
                    let lifetime = SwiftValueCodeLifetime.current
                    let value = try codec.makeValue(
                        address.load(as: ABISwiftClosureValue.self),
                        nil,
                        false,
                        lifetime
                    )
                    let buffer = Self(value as! Value)
                    scope.prepareWriteback {
                        let replacement = try encode(buffer.value, lifetime)
                        SwiftValueCodeLifetime.connect(
                            [lifetime, replacement.codeLifetime].compactMap { $0 },
                            retaining: []
                        )
                        return {
                            let previous = address.load(as: ABISwiftClosureValue.self)
                            address.copyMemory(
                                from: replacement.address,
                                byteCount: MemoryLayout<ABISwiftClosureValue>.size
                            )
                            replacement.relinquishValue()
                            ABIReleaseSwiftClosureContext(previous.ownedContext)
                        }
                    }
                    return buffer
                }
            }
        ) { buffer, owner in
            let native = try encode(buffer.value, owner)
            let pointer = reference(to: native)
            pointer.prepareWriteback = {
                let updated =
                    try codec.makeValue(
                        native.address.load(as: ABISwiftClosureValue.self),
                        owner,
                        false,
                        native.codeLifetime
                    ) as! Value
                return { buffer.value = updated }
            }
            return pointer
        }
    }

    private static func tupleConversion(
        _ value: SwiftHostConversion,
        plan: SwiftTupleValuePlan
    ) throws -> SwiftHostConversion {
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
        return try conversion(
            value: value,
            callbackDecoder: { failure in
                guard failure == (any Error).self else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A host callback writing back a converted tuple requires throws(any Error) to report ownership and conversion failures."
                    )
                }
                return { argument, scope in
                    let metadata = unsafeBitCast(plan.nativeMetadata, to: UnsafeRawPointer.self)
                    let address = argument.load(as: UnsafeMutableRawPointer.self)
                    let lifetime = SwiftValueCodeLifetime.current
                    let buffer = Self(
                        try plan.copyNativeValue(
                            from: address,
                            retainingCode: lifetime,
                            codeLifetime: lifetime,
                            as: Value.self
                        )
                    )
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
            }
        ) { buffer, owner in
            let native = try encode(buffer.value, owner)
            let pointer = reference(to: native)
            pointer.prepareWriteback = {
                let updated = try plan.copyNativeValue(
                    from: native.address,
                    retainingCode: owner,
                    codeLifetime: native.codeLifetime,
                    as: Value.self
                )
                return { buffer.value = updated }
            }
            return pointer
        }
    }
}
extension NativeSwiftInout: SwiftConventionArgument {
    static var wrappedType: Any.Type { Value.self }
    static var convention: SwiftArgumentConvention { .inoutValue }
    static func makeConversion(generic: SwiftGenericArgument) throws -> SwiftHostConversion {
        // Preparing a signature must establish the pointee contract even before
        // an actual buffer is supplied.
        if case .runtimeValue(let plan, _, let asynchronous) = generic {
            guard Value.self == NativeSwiftValue.self || Value.self == NativeSwiftBorrowedValue.self
            else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Inout runtime arguments require a runtime value handle."
                )
            }
            return try conversion(
                value: SwiftHostConversion(host: Value.self, argument: generic, position: .nested),
                callbackDecoder: { _ in
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Use NativeSwiftBorrowedValue for a runtime inout callback input."
                    )
                }
            ) { buffer, _ in
                let access = try plan.encode(
                    buffer.value,
                    convention: .inoutValue,
                    asynchronous: asynchronous
                )
                let pointer = reference(to: access)
                pointer.prepareWriteback = access.prepareWriteback
                return pointer
            }
        }
        if case .value = generic {
        } else {
            let tuple: SwiftTupleValuePlan?
            if case .tuple(let plan, _, _) = generic {
                tuple = plan
            } else {
                tuple = try SwiftGenericCallPlan.concreteTuple(Value.self, position: .nested)
            }
            if let tuple {
                let value = try SwiftHostConversion(
                    host: Value.self,
                    argument: .tuple(tuple),
                    position: .nested
                )
                if tuple.needsConversion { return try tupleConversion(value, plan: tuple) }
                return try conversion(value: value, callbackDecoder: { _ in callbackDecoder() }) {
                    buffer,
                    _ in buffer.encoded()
                }
            }
            if Value.self is any SwiftClosureValue.Type {
                let value = try SwiftHostConversion(
                    host: Value.self,
                    argument: generic,
                    position: .nested
                )
                guard case .closure(let closure) = value.kind else {
                    preconditionFailure("A closure converts as a closure.")
                }
                return try closureConversion(value, closure: closure)
            }
            try Self.validatePointee()
        }
        // The pointee is stored in the buffer and passes by address.
        return try conversion(
            value: SwiftHostConversion(host: Value.self, argument: generic, position: .nested),
            callbackDecoder: { _ in callbackDecoder() }
        ) { buffer, _ in buffer.encoded() }
    }
}
