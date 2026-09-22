import ABIBridgeCore

/// An explicit pointer-authentication schema supplied by a native adapter.
///
/// Authentication is applied on targets built with the authenticated-call ABI.
/// On other targets the stored pointer is used unchanged. These operations do
/// not discover a schema or turn authentication failure into a Swift error.
public enum NativePointerAuthentication: Sendable, Hashable {
    /// An unsigned pointer. Use this only when the storage actually is unsigned.
    case unsigned
    /// A signed pointer with its key, extra discriminator, and address diversity.
    case signed(key: Key, discriminator: UInt = 0, addressDiversity: Bool = false)

    /// Keys used by the pointer-authentication intrinsics.
    public enum Key: Int32, Sendable, Hashable {
        /// Instruction-address key A.
        case instructionA = 0
        /// Instruction-address key B.
        case instructionB = 1
        /// Data-address key A.
        case dataA = 2
        /// Data-address key B.
        case dataB = 3
    }

    /// Whether this build uses the pointer-authenticated call ABI.
    public static var isEnabled: Bool { ABIUsesPointerAuthentication() }

    /// Describes a Clang C++ object-vtable pointer with address/type diversity.
    ///
    /// Compiler versions, flags, and class attributes can change the schema.
    /// Use an explicit signed schema for legacy or customized representations.
    /// - Parameter discriminator: The target compiler's discriminator for the
    ///   primary base class's vtable identifier.
    /// - Returns: Data key A with storage-address diversity.
    public static func cxxVTablePointer(discriminator: UInt) -> Self {
        .signed(key: .dataA, discriminator: discriminator, addressDiversity: true)
    }

    /// Describes a Clang absolute virtual-function slot.
    ///
    /// - Parameter discriminator: The target compiler's discriminator for the
    ///   declaration that originally introduced the slot.
    /// - Returns: Instruction key A with storage-address diversity.
    public static func cxxVirtualFunction(discriminator: UInt) -> Self {
        .signed(key: .instructionA, discriminator: discriminator, addressDiversity: true)
    }

    /// Reads a data pointer from a bounded native value and applies this schema.
    ///
    /// The bytes must contain a pointer signed according to the supplied schema.
    /// Authentication failure can fault when the returned pointer is dereferenced.
    /// - Parameters:
    ///   - storage: Storage containing the pointer field.
    ///   - offset: The field's byte offset, defaulting to zero.
    /// - Returns: The authenticated pointer, or nil for a stored null.
    /// - Throws: An out-of-bounds error for an unavailable field extent.
    @unsafe public func readPointer(
        from storage: NativeValue, at offset: Int = 0
    ) throws -> UnsafeRawPointer? {
        let field = try storage.view(at: offset, as: .pointer)
        return unsafe field.withUnsafeBytes {
            ABIUnsafeReadAuthenticatedPointer($0.baseAddress, keyCode, discriminator, addressDiversity)
        }
    }

    var keyCode: Int32 {
        switch self {
        case .unsigned: Int32(ABIAuthenticationUnsigned)
        case .signed(let key, _, _): key.rawValue
        }
    }
    var discriminator: UInt {
        switch self {
        case .unsigned: 0
        case .signed(_, let value, _): value
        }
    }
    var addressDiversity: Bool {
        switch self {
        case .unsigned: false
        case .signed(_, _, let value): value
        }
    }
}

/// A failure interpreting a bounded virtual table.
public enum NativeDispatchError: Error, Sendable, Equatable {
    /// The entry count is negative or cannot fit in an addressable byte extent.
    case invalidEntryCount(Int)
    /// The requested slot lies outside the declared table.
    case entryOutOfBounds(index: Int, count: Int)
    /// A receiver has a null virtual-table pointer.
    case missingVTable
}

/// A borrowed table of absolute function pointers with an explicit entry count.
///
/// The address points to the first function slot, excluding ABI headers such as
/// RTTI and offset-to-top fields. Relative table formats require a native adapter.
/// A method lookup captures its selected entry and retains the table owner;
/// later table changes do not alter the captured method. See <doc:CXXObjectInvocation>.
public final class NativeVTable {
    /// The number of function-pointer slots accessible from the address point.
    public let entryCount: Int
    private let storage: NativeValue

    /// Borrows a readable absolute function-pointer table.
    ///
    /// - Parameters:
    ///   - address: The address point of the first function slot.
    ///   - entryCount: The accessible number of pointer-sized entries.
    ///   - owner: An owner keeping table storage and dependencies alive.
    /// - Throws: An invalid-entry-count error.
    ///
    /// The caller must establish readability and the actual table format.
    @unsafe public init(
        borrowing address: UnsafeRawPointer, entryCount: Int, retaining owner: Any? = nil
    ) throws {
        let (size, overflow) = entryCount.multipliedReportingOverflow(by: MemoryLayout<UnsafeRawPointer>.size)
        guard entryCount >= 0, !overflow else { throw NativeDispatchError.invalidEntryCount(entryCount) }
        self.entryCount = entryCount
        storage = unsafe NativeValue(
            borrowing: UnsafeMutableRawPointer(mutating: address),
            as: try .opaque(named: "vtable", size: size, alignment: MemoryLayout<UnsafeRawPointer>.alignment),
            retaining: owner
        )
    }

    /// Reads a receiver's vtable pointer using an explicit storage offset and schema.
    ///
    /// - Parameters:
    ///   - receiver: A bounded view containing the vtable-pointer field.
    ///   - offset: The caller-specified byte offset of that field.
    ///   - entryCount: The accessible number of absolute function-pointer entries.
    ///   - authentication: The schema for the vtable pointer, not its function entries.
    /// - Throws: A bounds, null-vtable, or invalid-entry-count error.
    @unsafe public convenience init(
        readingFrom receiver: NativeValue, at offset: Int = 0, entryCount: Int,
        authentication: NativePointerAuthentication
    ) throws {
        guard let address = try unsafe authentication.readPointer(from: receiver, at: offset) else {
            throw NativeDispatchError.missingVTable
        }
        try unsafe self.init(borrowing: address, entryCount: entryCount, retaining: receiver)
    }

    func target(at index: Int, authentication: NativePointerAuthentication) throws -> VirtualCallTarget {
        guard index >= 0, index < entryCount else {
            throw NativeDispatchError.entryOutOfBounds(index: index, count: entryCount)
        }
        return try unsafe storage.withUnsafeBytes {
            var failure: OpaquePointer?
            guard let handle = ABICopyVirtualCallTarget(
                $0.baseAddress!.advanced(by: index * MemoryLayout<UnsafeRawPointer>.size),
                authentication.keyCode, authentication.discriminator, authentication.addressDiversity,
                &failure
            ) else { throw consumeNativeCallFailure(failure) }
            return VirtualCallTarget(handle: handle, retaining: storage)
        }
    }
}

// The table owner can also retain generated code or a receiver. Release it
// while the native implementation image is still leased.
final class VirtualCallTarget {
    let handle: OpaquePointer
    private var owner: NativeValue?
    init(handle: OpaquePointer, retaining owner: NativeValue) {
        self.handle = handle
        self.owner = owner
    }
    deinit {
        owner = nil
        ABIReleaseVirtualCallTarget(handle)
    }
    var function: ABIUnmanagedFunction? { ABIVirtualCallTargetFunction(handle) }
}
