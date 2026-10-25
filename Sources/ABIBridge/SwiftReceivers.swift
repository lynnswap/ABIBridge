import ABIBridgeCore
import ABIBridgeCore.Backend

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

    /// - Parameter schema: The declaration's schema of `self`, where it
    ///   decides how the host value passes instead of `conversion`.
    init(
        conversion: SwiftHostConversion,
        schema: SwiftValueSchema? = nil,
        metadata: Any.Type,
        isMutating: Bool?,
        isConsuming: Bool,
        protocolSelf: SwiftFormalType?,
        validateClass: Bool,
        borrowed: Bool? = nil
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
        if borrowed == true && isConsuming {
            throw ABIResolutionError.unsupportedDeclaration(
                "The declared result cannot borrow consuming self."
            )
        }
        let borrowedAddress =
            try borrowed == true && !isMutating && !indirect && !(metadata is AnyClass)
            ? SwiftBorrowedInputs.passesByAddress(
                SwiftInferredValue.addressability(of: metadata),
                of: metadata,
                input: .receiver,
                tuple: false,
                borrowed: true
            ) : false
        // Mutating protocol Self addresses the receiver slot, even when class-bound.
        if (protocolSelf != nil && isMutating) || indirect || borrowedAddress {
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

    /// Requires that `replacement`, the receiver of another declaration,
    /// receives `self` as this one does: in the same mode and ownership, and
    /// a value passing alike.
    ///
    /// A mutating `self` passes as one address, as an inout argument does, so
    /// the value it addresses takes no part. Another `self` passes as its
    /// value does: in registers, or, for an indirect value, as the address of
    /// storage of the same size and alignment.
    func requireReplacement(
        _ replacement: SwiftReceiverPlan,
        declaration: NativeDeclaration
    ) throws {
        guard mode == replacement.mode, isMutating == replacement.isMutating,
            isConsuming == replacement.isConsuming,
            mode == .object || isMutating
                || SwiftDeclaredLowering.passAlike(type, replacement.type, isResult: false)
        else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    declaration: declaration,
                    position: .receiver,
                    expected: passingDescription,
                    found: [replacement.passingDescription]
                )
            )
        }
    }

    private var passingDescription: String {
        let passing =
            switch mode {
            case .object: "a class instance"
            case .address where isMutating: "self passed by address"
            case .address, .value: "self " + SwiftDeclaredLowering.lowering(of: type)
            }
        return passing + (isMutating ? ", mutating" : "") + (isConsuming ? ", consuming" : "")
    }

    /// Checks that `self` passes as Swift passes it where the call's result
    /// borrows from it; see ``SwiftBorrowedInputs``. The declaration's
    /// `self` type decides, whatever represents it.
    func requireBorrowable(borrowed: Bool? = nil) throws {
        // Swift rejects a borrow dependency on a consuming self, and a class
        // instance, a mutating self, or an indirect self passes as one
        // pointer either way.
        guard mode == .value, !isConsuming else { return }
        _ = try SwiftBorrowedInputs.passesByAddress(
            SwiftInferredValue.addressability(of: metadata),
            of: metadata,
            input: .receiver,
            tuple: false,
            borrowed: borrowed
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
