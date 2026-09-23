/// A failure describing or converting native storage.
public enum NativeValueError: Error, Sendable, Equatable {
    /// Storage needs a nonnegative size and positive power-of-two alignment.
    case invalidLayout(size: Int, alignment: Int)
    /// A byte-copy source has a different size from its requested representation.
    case incompatibleSize(expected: Int, actual: Int)
    /// The source and destination have different native representations.
    case incompatibleLayout(expected: NativeType, actual: NativeType)
    /// A byte range falls outside the value's accessible extent.
    case outOfBounds(offset: Int, count: Int, size: Int)
    /// The layout has no field at this index.
    case invalidField(Int)
}

/// Conversion between a user-defined Swift wrapper and native storage.
///
/// The ABI type must remain stable for the lifetime of prepared handles.
/// Conversion methods own any target-specific initialization, interpretation,
/// and pointee ownership. The protocol does not make a nontrivial C++ value
/// compatible with the C calling convention; use a native adapter for that ABI.
public protocol ABIBridgeValue: SendableMetatype {
    /// The representation used by native calls, independent of Self's Swift layout.
    static var abiType: NativeType { get }

    /// Converts native storage into this Swift wrapper.
    ///
    /// A wrapper that adopts a returned foreign resource must establish cleanup
    /// before performing further validation that can throw.
    init(nativeValue: NativeValue) throws

    /// Produces storage and retains all resources required while the value is used.
    ///
    /// This operation does not transfer ownership to a native callee. Consumed
    /// arguments require an adapter that performs the transfer at the call boundary.
    static func nativeValue(from value: Self) throws -> NativeValue
}

extension ABIBridgeValue {
    func nativeValueForCall() throws -> NativeValue {
        try Self.nativeValue(from: self)
    }
}

// Copying a value preserves its original resource storage and a bounded set
// of implementation images, without retaining every intermediate value buffer.
final class NativeValueLifetime {
    private var resource: AnyObject?
    let images: [NativeImageIdentity: NativeImage]

    init(resource: AnyObject, images: [NativeImageIdentity: NativeImage]) {
        self.resource = resource
        self.images = images
    }

    func adding(_ additions: [NativeImage]) -> NativeValueLifetime {
        var images = images
        for image in additions { images[image.identity] = image }
        return NativeValueLifetime(resource: resource!, images: images)
    }

    deinit { withExtendedLifetime(images) { resource = nil } }
}

private final class NativeStorage {
    let address: UnsafeMutableRawPointer
    let owner: Any?
    private let release: ((UnsafeMutableRawPointer) -> Void)?

    init(address: UnsafeMutableRawPointer, owner: Any?,
         release: ((UnsafeMutableRawPointer) -> Void)?) {
        self.address = address
        self.owner = owner
        self.release = release
    }

    deinit { withExtendedLifetime(owner) { release?(address) } }
}

/// Native storage with an explicit layout and lifetime.
///
/// A value can allocate its own storage, adopt an external allocation, or borrow
/// memory while retaining an owner. Values and views are not Sendable: their
/// foreign resources and destruction callbacks may have thread requirements.
/// See <doc:NativeValueAdapters>.
public final class NativeValue {
    /// The layout associated with these bytes.
    public let type: NativeType
    private let storage: NativeStorage

    /// Allocates storage and initializes it using an adapter.
    ///
    /// The destruction callback runs before the allocation and retained owner
    /// are released. If initialization throws, the allocation is released
    /// without calling destroy; the initializer must clean up any partially
    /// initialized foreign resources itself.
    ///
    /// - Parameters:
    ///   - type: The storage layout.
    ///   - owner: An additional owner kept alive during initialization and use.
    ///   - destroy: A nonthrowing foreign-value destructor; allocation cleanup is automatic.
    ///   - initialize: Initializes the value within the supplied byte extent.
    /// - Throws: Any initialization error.
    public init(
        type: NativeType,
        retaining owner: Any? = nil,
        destroy: ((UnsafeMutableRawPointer) -> Void)? = nil,
        initializingWith initialize: (UnsafeMutableRawBufferPointer) throws -> Void
    ) rethrows {
        let address = UnsafeMutableRawPointer.allocate(
            byteCount: max(type.size, 1), alignment: type.alignment
        )
        do {
            try withExtendedLifetime(owner) {
                try initialize(.init(start: address, count: type.size))
            }
        } catch {
            address.deallocate()
            throw error
        }
        self.type = type
        storage = NativeStorage(address: address, owner: owner) {
            destroy?($0)
            $0.deallocate()
        }
    }

    /// Copies a bitwise-copyable Swift value into native storage.
    ///
    /// Size is checked, but the adapter must ensure the field representations
    /// match. This copies pointer bits without retaining pointees or performing
    /// a foreign copy constructor.
    ///
    /// - Parameters:
    ///   - value: The initialized Swift value whose bytes will be copied.
    ///   - type: The intended native representation.
    ///   - owner: An optional owner for pointees referenced by those bytes.
    /// - Throws: A size mismatch.
    public convenience init<Value: BitwiseCopyable>(
        copying value: Value, as type: NativeType, retaining owner: Any? = nil
    ) throws {
        guard MemoryLayout<Value>.size == type.size else {
            throw NativeValueError.incompatibleSize(expected: type.size, actual: MemoryLayout<Value>.size)
        }
        self.init(type: type, retaining: owner) { destination in
            Swift.withUnsafeBytes(of: value) { destination.copyMemory(from: $0) }
        }
    }

    /// Borrows external storage without destroying or deallocating it.
    ///
    /// - Parameters:
    ///   - address: Storage valid for the layout's entire byte extent.
    ///   - type: The storage layout.
    ///   - owner: An owner retaining the allocation, when available.
    ///
    /// The caller must keep ownerless storage alive for this value and every
    /// derived view. The lifetime promise is not checked by this initializer.
    @unsafe public init(
        borrowing address: UnsafeMutableRawPointer, as type: NativeType,
        retaining owner: Any? = nil
    ) {
        self.type = type
        storage = NativeStorage(address: address, owner: owner, release: nil)
    }

    /// Adopts externally allocated storage with its matching release operation.
    ///
    /// - Parameters:
    ///   - address: Exclusively owned storage valid for the declared byte extent.
    ///   - type: The storage layout.
    ///   - owner: Any dependency needed while using or releasing the resource.
    ///   - release: Destroys and releases the external allocation exactly once.
    ///
    /// The caller transfers release responsibility and must not release the
    /// resource separately. The callback must obey the resource's thread contract.
    @unsafe public init(
        adopting address: UnsafeMutableRawPointer, as type: NativeType,
        retaining owner: Any? = nil,
        release: @escaping (UnsafeMutableRawPointer) -> Void
    ) {
        self.type = type
        storage = NativeStorage(address: address, owner: owner, release: release)
    }

    /// Produces a pointer value that keeps another native value's storage alive.
    ///
    /// This describes a pointer parameter, not a by-value copy of the pointee.
    /// - Parameter value: The pointee whose lifetime will be retained.
    /// - Returns: Pointer-sized storage retaining the pointee.
    public static func reference(to value: NativeValue) -> NativeValue {
        NativeValue(type: .pointer, retaining: value) { destination in
            Swift.withUnsafeBytes(of: value.storage.address) { destination.copyMemory(from: $0) }
        }
    }

    /// Creates a bounded storage view with another explicit layout.
    ///
    /// This is useful for a caller-specified C++ subobject offset. It does not
    /// infer inheritance layout or adjust the receiver automatically.
    /// - Parameters:
    ///   - offset: The byte offset within this value.
    ///   - type: The view's accessible extent and representation.
    /// - Returns: A view retaining this value and sharing its storage.
    /// - Throws: An out-of-bounds error when the view exceeds the known extent.
    public func view(at offset: Int, as type: NativeType) throws -> NativeValue {
        try checkRange(offset: offset, count: type.size)
        return unsafe NativeValue(
            borrowing: storage.address.advanced(by: offset), as: type, retaining: self
        )
    }

    /// Returns a mutable field view retaining the containing allocation.
    ///
    /// - Parameter index: A field index from the structure layout.
    /// - Returns: A view with the field's layout and shared storage.
    /// - Throws: An invalid-field error when the index does not exist.
    public func field(at index: Int) throws -> NativeValue {
        guard type.fields.indices.contains(index) else { throw NativeValueError.invalidField(index) }
        let field = type.fields[index]
        return unsafe NativeValue(
            borrowing: storage.address.advanced(by: field.offset), as: field.type, retaining: self
        )
    }

    /// Converts storage to a wrapper with a compatible native layout.
    ///
    /// Diagnostic names may differ; representation, size, alignment, and field
    /// layouts must match. The wrapper is responsible for interpreting the bytes.
    ///
    /// - Parameter valueType: The requested Swift wrapper type.
    /// - Returns: The wrapper produced by its native-value initializer.
    /// - Throws: A layout mismatch or an error from the wrapper's conversion.
    public func cast<Value: ABIBridgeValue>(to valueType: Value.Type) throws -> Value {
        try requireLayout(Value.abiType)
        return try Value(nativeValue: self)
    }

    /// Reads a bitwise-copyable representation from a checked byte range.
    ///
    /// Bounds are checked and unaligned reads are supported. The caller must
    /// ensure those bytes are initialized and valid for the requested Swift type.
    ///
    /// - Parameters:
    ///   - valueType: The representation to read.
    ///   - offset: A byte offset, defaulting to zero.
    /// - Returns: A copy of the stored bits.
    /// - Throws: An out-of-bounds error.
    @unsafe public func read<Value: BitwiseCopyable>(
        as valueType: Value.Type, at offset: Int = 0
    ) throws -> Value {
        try checkRange(offset: offset, count: MemoryLayout<Value>.size)
        return withExtendedLifetime(storage) {
            storage.address.loadUnaligned(fromByteOffset: offset, as: Value.self)
        }
    }

    /// Borrows the initialized bytes while retaining their storage and owner.
    ///
    /// The pointer must not outlive the value. Foreign representations and
    /// pointees remain the adapter's responsibility.
    /// - Parameter body: A synchronous operation on the borrowed bytes.
    /// - Returns: The result produced by body.
    /// - Throws: Any error thrown by body.
    @unsafe public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(storage) {
            try body(.init(start: storage.address, count: type.size))
        }
    }

    /// Borrows mutable bytes without changing the storage's ownership.
    ///
    /// The caller must preserve foreign-value invariants, prevent conflicting
    /// accesses through other views, and keep the pointer within the value's lifetime.
    /// - Parameter body: A synchronous operation on the borrowed mutable bytes.
    /// - Returns: The result produced by body.
    /// - Throws: Any error thrown by body.
    @unsafe public func withUnsafeMutableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(storage) {
            try body(.init(start: storage.address, count: type.size))
        }
    }

    func lifetimeForCopy(retaining images: [NativeImage]) -> NativeValueLifetime {
        if let lifetime = storage.owner as? NativeValueLifetime {
            return lifetime.adding(images)
        }
        var retained: [NativeImageIdentity: NativeImage] = [:]
        for image in images { retained[image.identity] = image }
        return NativeValueLifetime(resource: storage, images: retained)
    }

    func requireLayout(_ expected: NativeType) throws {
        guard type.matchesLayout(of: expected) else {
            throw NativeValueError.incompatibleLayout(expected: expected, actual: type)
        }
    }

    private func checkRange(offset: Int, count: Int) throws {
        guard offset >= 0, offset <= type.size, count <= type.size - offset else {
            throw NativeValueError.outOfBounds(offset: offset, count: count, size: type.size)
        }
    }
}
