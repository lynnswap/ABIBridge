import ABIBridgeCore

enum SwiftReceiverMode: Sendable { case object, address, value }

struct SwiftReceiverPlan: Sendable {
    /// The conversion of the receiver's host value.
    let conversion: SwiftHostConversion
    /// The schema with which `self` passes, which the declaration can decide
    /// instead of the host type.
    let schema: SwiftValueSchema
    var type: CValueType { schema.type }
    /// The host type that represents `self`.
    var representation: ObjectIdentifier { ObjectIdentifier(conversion.host) }
    let mode: SwiftReceiverMode
    let isMutating: Bool
    let isConsuming: Bool
    let expectedClass: AnyClass?
    let metadata: Any.Type
    /// Whether `receiverABI` states the convention of `self`.
    var isExplicit = false

    /// - Parameter schema: The declaration's schema of `self`, where it
    ///   decides how the host value passes instead of `conversion`.
    init(
        conversion: SwiftHostConversion,
        schema: SwiftValueSchema? = nil,
        metadata: Any.Type,
        isMutating: Bool?,
        isConsuming: Bool,
        protocolSelf: SwiftFormalType?,
        validateClass: Bool
    ) throws {
        self.conversion = conversion
        let schema = schema ?? conversion.schema
        self.schema = schema
        let indirect = ABISwiftValueIsIndirect(schema.type.handle)
        // A concrete same-type Self keeps a protocol setter's inout default.
        let isMutating =
            isMutating
            ?? (!isConsuming
                && (protocolSelf?.nominalDeclaration != nil || indirect || !(metadata is AnyClass)))
        guard !(isMutating && isConsuming) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Swift self cannot be both mutating and consuming."
            )
        }
        self.metadata = metadata
        self.isMutating = isMutating
        self.isConsuming = isConsuming
        expectedClass = validateClass ? metadata as? AnyClass : nil
        // Mutating protocol Self addresses the receiver slot, even when class-bound.
        if (protocolSelf != nil && isMutating) || indirect {
            mode = .address
        } else if metadata is AnyClass {
            guard ABIValueTypeIsPointer(schema.type.handle) else {
                throw ABIResolutionError.unsupportedDeclaration("A Swift class receiver requires a reference or pointer adapter.")
            }
            mode = .object
        } else {
            mode = isMutating ? .address : .value
        }
    }

    var trailingType: CValueType? { mode == .value ? type : nil }

    /// Checks that `self` passes as the compiler passes it when the call's
    /// result can borrow from it; see
    /// ``SwiftInferredValue/requireBorrowable(_:passedByAddress:position:explicit:)``.
    func requireBorrowable() throws {
        // A representation other than the type itself states its own
        // convention, and an indirect self passes by address.
        guard mode == .value, !isExplicit, conversion.host == metadata else { return }
        try SwiftInferredValue.requireBorrowable(
            metadata,
            passedByAddress: false,
            position: .receiver
        )
    }

    /// Storage that passes the host value `receiver` as `self`.
    func encodeValue(_ receiver: Any) throws -> NativeValueStorage {
        guard let host = conversion.hostStorage(receiver) else {
            throw ABIInvocationError.incompatibleValue(
                expected: String(reflecting: conversion.host),
                actual: String(reflecting: Swift.type(of: receiver))
            )
        }
        try requireCopyable()
        return try conversion.encodeCopy(host.address, retainingCode: nil).storage
    }

    /// A host value that copies the native `self` in `storage`.
    func decodeValue(_ storage: NativeValueStorage, retaining owner: Any?) throws -> Any {
        try requireCopyable()
        return try conversion.decodeHost(
            conversion.copyNative(storage),
            retaining: owner,
            retainingCode: nil
        )
    }

    /// A copy of the native `self` in `storage`.
    func clone(_ storage: NativeValueStorage) throws -> NativeValueStorage {
        try requireCopyable()
        return try conversion.copyNative(storage)
    }

    func destroy(_ address: UnsafeMutableRawPointer) { conversion.destroyNative(at: address) }

    /// A receiver of a native type that only runtime metadata names can be
    /// noncopyable, which a host value cannot hold.
    private func requireCopyable() throws {
        guard SwiftCopyability.accepts(conversion.host) else {
            throw NativeSwiftValueError.noncopyableType
        }
    }

    func encode(_ receiver: Any, asynchronous: Bool = false) throws -> NativeValueStorage {
        let actual: NativeSwiftType
        if let value = receiver as? NativeSwiftValue {
            actual = value.type
        } else if let value = receiver as? NativeSwiftBorrowedValue {
            actual = value.type
        } else {
            return try encodeValue(receiver)
        }
        if !(isMutating && mode == .address),
            let expected = metadata as? AnyClass, let objectType = actual.metadata as? AnyClass
        {
            guard SwiftObjectType(objectType)?.isSubclass(of: expected) == true else {
                throw ABIInvocationError.incompatibleValue(expected: String(reflecting: metadata), actual: actual.name)
            }
        } else if actual.metadata != metadata {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: metadata), actual: actual.name)
        }
        if let value = receiver as? NativeSwiftValue {
            return try value.access(isConsuming ? .consuming : isMutating && mode != .object ? .inoutValue : .borrowing)
        }
        let value = receiver as! NativeSwiftBorrowedValue
        return try value.borrow.access(asynchronous: asynchronous, type: value.type,
            convention: isConsuming ? .consuming : isMutating && mode != .object ? .inoutValue : .borrowing)
    }

    func finishInvocation<Result: ~Copyable, Receiver>(
        _ outcome: consuming Swift.Result<Result, any Error>, storage: NativeValueStorage, invoked: Bool,
        receiver: inout Receiver, retaining owner: Any?
    ) throws -> Result {
        try finishSwiftInvocation(outcome) {
            if invoked && isMutating && mode != .object && !(receiver is NativeSwiftValue) && !(receiver is NativeSwiftBorrowedValue) {
                let value = try decodeValue(storage, retaining: owner)
                guard let updated = value as? Receiver else {
                    throw ABIInvocationError.incompatibleValue(
                        expected: String(reflecting: Receiver.self), actual: String(reflecting: Swift.type(of: value)))
                }
                receiver = updated
            }
        }
    }

    @unsafe func context(for storage: NativeValueStorage) throws -> UnsafeRawPointer? {
        if mode == .value { return nil }
        if mode == .address && expectedClass == nil { return UnsafeRawPointer(storage.address) }
        guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else {
            throw ABIInvocationError.incompatibleValue(
                expected: "a live Swift receiver",
                actual: "nil"
            )
        }
        // A receiver of the declaring class's own type is already that class.
        // Explicit pointer/AnyObject adapters need this runtime class check.
        if let expectedClass {
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard SwiftObjectType(Swift.type(of: object))?.isSubclass(of: expectedClass) == true
            else {
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: expectedClass), actual: String(reflecting: Swift.type(of: object))
                )
            }
        }
        return mode == .address ? UnsafeRawPointer(storage.address) : pointer
    }
}
