import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime

/// An explicit pointer-authentication schema supplied by a native adapter.
///
/// Authentication is applied on targets built with the authenticated-call ABI. On other targets the stored pointer is used unchanged. These operations do not discover a schema or turn authentication failure into a Swift error.
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
    /// Compiler versions, flags, and class attributes can change the schema. Use an explicit signed schema for legacy or customized representations.
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
    /// The bytes must contain a pointer signed according to the supplied schema. Authentication failure can fault when the returned pointer is dereferenced.
    /// - Parameters:
    ///   - storage: Storage containing the pointer field.
    ///   - offset: The field's byte offset, defaulting to zero.
    /// - Returns: The authenticated pointer, or nil for a stored null.
    /// - Throws: An out-of-bounds error for an unavailable field extent.
    @unsafe public func readPointer(
        from storage: NativeValue,
        at offset: Int = 0
    ) throws -> UnsafeRawPointer? {
        let field = try storage.view(at: offset, as: .pointer)
        return unsafe field.withUnsafeBytes {
            ABIUnsafeReadAuthenticatedPointer(
                $0.baseAddress,
                keyCode,
                discriminator,
                addressDiversity
            )
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
/// The address points to the first function slot, excluding ABI headers such as RTTI and offset-to-top fields. Relative table formats require a native adapter. A method lookup captures its selected entry and code owner; later table changes do not alter it. A receiver-backed table retains its receiver while the table or a request retaining it remains alive. Captured targets retain their code owner and implementation image independently of the table. See <doc:CXXObjectInvocation>.
public final class NativeVTable {
    /// The number of function-pointer slots accessible from the address point.
    public let entryCount: Int
    let storage: NativeValue
    private let codeOwner: Any?

    /// Borrows a readable absolute function-pointer table.
    ///
    /// - Parameters:
    ///   - address: The address point of the first function slot.
    ///   - entryCount: The accessible number of pointer-sized entries.
    ///   - owner: An owner keeping table storage and captured code dependencies alive.
    /// - Throws: An invalid-entry-count error.
    ///
    /// The caller must establish readability and the actual table format.
    @unsafe public convenience init(
        borrowing address: UnsafeRawPointer,
        entryCount: Int,
        retaining owner: Any? = nil
    ) throws {
        try unsafe self.init(
            borrowing: address,
            entryCount: entryCount,
            retaining: owner,
            retainingCode: owner
        )
    }

    @unsafe private init(
        borrowing address: UnsafeRawPointer,
        entryCount: Int,
        retaining owner: Any?,
        retainingCode codeOwner: Any?
    ) throws {
        let (size, overflow) = entryCount.multipliedReportingOverflow(
            by: MemoryLayout<UnsafeRawPointer>.size
        )
        guard entryCount >= 0, !overflow else {
            throw NativeDispatchError.invalidEntryCount(entryCount)
        }
        self.entryCount = entryCount
        self.codeOwner = codeOwner
        storage = unsafe NativeValue(
            borrowing: UnsafeMutableRawPointer(mutating: address),
            as: try .opaque(
                named: "vtable",
                size: size,
                alignment: MemoryLayout<UnsafeRawPointer>.alignment
            ),
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
    ///   - codeOwner: An optional owner for generated code retained by captured targets and shared hooks.
    /// - Throws: A bounds, null-vtable, or invalid-entry-count error.
    @unsafe public convenience init(
        readingFrom receiver: NativeValue,
        at offset: Int = 0,
        entryCount: Int,
        authentication: NativePointerAuthentication,
        retainingCode codeOwner: Any? = nil
    ) throws {
        guard let address = try unsafe authentication.readPointer(from: receiver, at: offset) else {
            throw NativeDispatchError.missingVTable
        }
        try unsafe self.init(
            borrowing: address,
            entryCount: entryCount,
            retaining: receiver,
            retainingCode: codeOwner
        )
    }

    func slot(at index: Int) throws -> (bits: UInt, address: UInt) {
        guard index >= 0, index < entryCount else {
            throw NativeDispatchError.entryOutOfBounds(index: index, count: entryCount)
        }
        return unsafe storage.withUnsafeBytes {
            let slot = $0.baseAddress!.advanced(by: index * MemoryLayout<UnsafeRawPointer>.size)
            return (slot.loadUnaligned(as: UInt.self), UInt(bitPattern: slot))
        }
    }

    static func prepareTarget(
        _ slot: (bits: UInt, address: UInt),
        authentication: NativePointerAuthentication
    ) throws -> RuntimeImplementation {
        guard
            let implementation = try withRuntimeErrors({
                try RuntimeImplementation(
                    bits: slot.bits,
                    storage: UnsafeRawPointer(bitPattern: slot.address)!,
                    authentication: authentication.runtimeValue,
                    retaining: nil
                )
            })
        else { throw ABIResolutionError.invalidAddress }
        return implementation
    }

    func target(
        at index: Int,
        authentication: NativePointerAuthentication,
        retaining image: NativeImage? = nil
    ) throws -> VirtualCallTarget {
        let implementation = try Self.prepareTarget(slot(at: index), authentication: authentication)
        return target(capturing: implementation, retaining: image)
    }

    func target(
        capturing implementation: RuntimeImplementation,
        retaining image: NativeImage?
    ) -> VirtualCallTarget {
        VirtualCallTarget(implementation: implementation, retaining: codeOwner, image: image)
    }
}

// An explicit code owner may execute native destruction on final release.
// Keep the implementation images leased until that release finishes.
final class VirtualCallTarget {
    private let implementation: RuntimeImplementation
    private var owner: Any?
    private let image: NativeImage?

    init(implementation: RuntimeImplementation, retaining owner: Any?, image: NativeImage?) {
        self.implementation = implementation
        self.owner = owner
        self.image = image
    }

    deinit {
        withExtendedLifetime((image, implementation)) { owner = nil }
    }

    var function: ABIUnmanagedFunction? { implementation.function }
}
