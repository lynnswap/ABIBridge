import ABIBridgeCore
import Foundation

/// An ownership or access conflict involving a runtime Swift value.
public enum NativeSwiftValueError: Error, Sendable, Equatable {
    /// The native value has already been transferred out of this handle.
    case consumedValue
    /// The native type does not support copying.
    case noncopyableType
    /// An active native operation holds conflicting access to the value.
    case valueInUse
}

/// Owns an Escapable Swift value whose concrete type need not be available at compile time.
///
/// Assignment shares this handle. Use copy() for an independent native value.
/// Native code, metadata, and value witnesses remain retained through destruction.
/// The value stays in the caller's isolation domain and is not Sendable.
public final class NativeSwiftValue {
    /// The actual runtime type and its retained implementation images.
    public let type: NativeSwiftType
    /// Whether the actual native type conforms to Copyable.
    public let isCopyable: Bool

    private let lock = NSLock()
    private var storage: NativeValueStorage?
    private var readers = 0
    private var exclusive = false

    init(storage: NativeValueStorage, type: NativeSwiftType) {
        self.storage = storage
        self.type = type
        isCopyable = SwiftCopyability.accepts(type.metadata)
    }

    /// Whether this handle has transferred its value to native code or take(as:).
    /// The type and copyability remain available after consumption.
    public var isConsumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage == nil
    }

    /// Creates an independent native copy, retaining its implementation images.
    public func copy() throws -> NativeSwiftValue {
        let source = try access(.borrowing)
        guard isCopyable else { throw NativeSwiftValueError.noncopyableType }
        return try withExtendedLifetime(source) { try Self.copy(from: source.address, type: type) }
    }

    /// Passes an Any copy to body while retaining its implementation images.
    ///
    /// Standard Swift casts can inspect the copy's existing conformances. If
    /// a value escapes body, keep this handle alive while that value may execute
    /// dynamically loaded code, including during destruction.
    public func withCopy<Result>(_ body: (Any) throws -> Result) throws -> Result {
        let source = try access(.borrowing)
        guard isCopyable else { throw NativeSwiftValueError.noncopyableType }
        func read<Concrete>(_ concrete: Concrete.Type) -> Any {
            source.address.load(as: Concrete.self)
        }
        return try withExtendedLifetime(source) {
            try SwiftValueCodeLifetime.withCurrent(type.codeLifetime) {
                try body(_openExistential(type.metadata, do: read))
            }
        }
    }

    /// Moves the exact native type into a typed Swift value, consuming this handle.
    ///
    /// This also supports noncopyable Swift types. A type or access error leaves
    /// the value owned by this handle. Keep its type handle alive while the
    /// returned value may execute code from a dynamically loaded image.
    public func take<Value: ~Copyable>(as valueType: Value.Type) throws -> Value {
        guard unsafeBitCast(valueType, to: UnsafeRawPointer.self)
                == unsafeBitCast(type.metadata, to: UnsafeRawPointer.self) else {
            throw ABIInvocationError.incompatibleValue(
                expected: String(reflecting: valueType), actual: type.name)
        }
        let source = try access(.consuming)
        let result = source.address.assumingMemoryBound(to: Value.self).move()
        source.relinquishValue()
        return result
    }

    /// Borrows this value on the current thread until body returns.
    ///
    /// The view expires at the end of this scope even if it is saved elsewhere.
    /// A conflicting mutation or transfer fails while this borrow remains active.
    /// An async member started during the scope retains its read access until
    /// native completion, even after the view expires at the end of body.
    public func withBorrowedValue<Result>(
        _ body: (NativeSwiftBorrowedValue) throws -> Result
    ) throws -> Result {
        let source = try access(.borrowing)
        let borrow = SwiftValueBorrow(UnsafeRawPointer(source.address), retaining: source)
        defer { withExtendedLifetime(source) { borrow.expire() } }
        return try body(NativeSwiftBorrowedValue(type: type, borrow: borrow))
    }

    static func copy(from source: UnsafeRawPointer, type: NativeSwiftType) throws -> NativeSwiftValue {
        guard SwiftEscapability.accepts(type.metadata) else {
            throw ABIResolutionError.unsupportedDeclaration("An owned runtime value requires an Escapable native type.")
        }
        let metadata = unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        let destination = NativeValueStorage(size: layout.stride, alignment: layout.alignment, owner: type,
                                            codeLifetime: type.codeLifetime)
        guard SwiftCopyability.accepts(type.metadata) else {
            throw NativeSwiftValueError.noncopyableType
        }
        ABISwiftCopyValue(metadata, destination.address, source)
        destination.assumeInitialized {
            ABISwiftDestroyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), $0)
        }
        return NativeSwiftValue(storage: destination, type: type)
    }

    func access(_ convention: SwiftArgumentConvention) throws -> NativeValueStorage {
        lock.lock()
        guard let storage else { lock.unlock(); throw NativeSwiftValueError.consumedValue }
        let writes = convention != .borrowing
        guard !exclusive, !writes || readers == 0 else {
            lock.unlock(); throw NativeSwiftValueError.valueInUse
        }
        if writes { exclusive = true } else { readers += 1 }
        lock.unlock()
        let access = SwiftRuntimeValueAccess(storage: storage) { consumed in
            self.lock.lock()
            if consumed {
                storage.relinquishValue()
                self.storage = nil
            }
            if writes { self.exclusive = false } else { self.readers -= 1 }
            self.lock.unlock()
        }
        return NativeValueStorage(borrowing: storage.address, owner: access, retainingResourcesOf: storage,
                                  didRelinquish: convention == .consuming ? { access.consume() } : nil)
    }
}

// The runtime checks the compiler-emitted Copyable requirement, including
// conditional conformances. Swift 6.3's initialized generic value-witness flags
// can omit IsNonCopyable even when their copy witness traps. Suppress Escapable
// so this query tests only Copyable, independently of the caller's lifetime.
private struct SwiftCopyabilityQuery<Value: ~Escapable> {}
private struct SwiftEscapabilityQuery<Value: ~Copyable> {}

private func swiftTypeSatisfiesRequirement(_ type: Any.Type, descriptor: UInt) -> Bool {
    var argument: UnsafeRawPointer? = unsafeBitCast(type, to: UnsafeRawPointer.self)
    let result = withUnsafePointer(to: &argument) {
        ABICreateSwiftTypeMetadata(UnsafeRawPointer(bitPattern: descriptor), $0, 1, nil)
    }
    guard let result else { return false }
    ABIReleaseSwiftTypeMetadata(result)
    return true
}

enum SwiftCopyability {
    private static let descriptor = UInt(bitPattern: ABISwiftTypeDescriptor(
        unsafeBitCast(SwiftCopyabilityQuery<Int>.self, to: UnsafeRawPointer.self))!)

    static func accepts(_ type: Any.Type) -> Bool {
        swiftTypeSatisfiesRequirement(type, descriptor: descriptor)
    }
}

enum SwiftEscapability {
    private static let descriptor = UInt(bitPattern: ABISwiftTypeDescriptor(
        unsafeBitCast(SwiftEscapabilityQuery<Int>.self, to: UnsafeRawPointer.self))!)

    static func accepts(_ type: Any.Type) -> Bool {
        swiftTypeSatisfiesRequirement(type, descriptor: descriptor)
    }
}

private final class SwiftRuntimeValueAccess {
    let storage: NativeValueStorage
    private let finish: (Bool) -> Void
    private var consumed = false
    init(storage: NativeValueStorage, finish: @escaping (Bool) -> Void) {
        self.storage = storage
        self.finish = finish
    }
    func consume() { consumed = true }
    deinit { finish(consumed) }
}

/// Native metadata owns value operations; the formal declaration owns ABI placement.
struct SwiftRuntimeValuePlan: Sendable {
    let valueType: NativeSwiftType
    let type: CValueType
    private let size: Int
    private let alignment: Int
    private let constants: SwiftValueConstants

    init(metadata: Any.Type, type: CValueType, resolver: SymbolResolver, retaining images: [NativeImage]) throws {
        self.type = type
        constants = SwiftValueConstants(metadata)
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(pointer)
        size = layout.stride
        alignment = layout.alignment
        let name = try swiftNativeTypeName(metadata)
        let image: NativeImage
        if let descriptor = ABISwiftTypeDescriptor(pointer),
           let definingImage = try swiftImplementationImage(containing: descriptor) {
            image = definingImage
        } else if let objectType = metadata as? AnyClass {
            image = try swiftClassImage(objectType, named: name, resolver: resolver)
        } else if let owner = images.first {
            image = owner
        } else {
            throw ABIResolutionError.metadataUnavailable("The runtime value's implementation image is unavailable.")
        }
        let declarationName = try swiftTypeDeclarationName(metadata, in: image, suggestedName: name, resolver: resolver)
        valueType = NativeSwiftType(name: declarationName, image: image, metadata: metadata,
            representation: nil, resolver: resolver,
            genericMetadata: try SwiftGenericTypeMetadata(metadata: metadata, retaining: images))
    }

    func makeStorage() -> NativeValueStorage {
        NativeValueStorage(size: size, alignment: alignment, owner: valueType,
                           codeLifetime: SwiftValueCodeLifetime(valueType.codeImages))
    }

    func restoredCallbackArgument(from address: UnsafeRawPointer) -> NativeValueStorage? {
        constants.isEmpty ? nil : constants.copyStorage(from: address)
    }

    // Callback preparation establishes Copyable and Escapable before publication.
    func copyCallbackArgument(from address: UnsafeRawPointer, type: NativeSwiftType) -> NativeSwiftValue {
        let storage = NativeValueStorage(size: size, alignment: alignment, owner: type,
            codeLifetime: type.codeLifetime)
        ABISwiftCopyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), storage.address, address)
        storage.assumeInitialized {
            ABISwiftDestroyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), $0)
        }
        return NativeSwiftValue(storage: storage, type: type)
    }

    func takeCallbackArgument(from address: UnsafeMutableRawPointer, type: NativeSwiftType) -> NativeSwiftValue {
        let storage = NativeValueStorage(size: size, alignment: alignment, owner: type,
            codeLifetime: type.codeLifetime)
        constants.initialize(at: address)
        ABISwiftTakeValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), storage.address, address)
        storage.assumeInitialized {
            ABISwiftDestroyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), $0)
        }
        return NativeSwiftValue(storage: storage, type: type)
    }

    func requireOwnedValue() throws {
        guard SwiftEscapability.accepts(valueType.metadata) else {
            throw ABIResolutionError.unsupportedDeclaration("An owned runtime value requires an Escapable native type.")
        }
    }

    func decode(_ storage: NativeValueStorage) throws -> NativeSwiftValue {
        if valueType.metadata is AnyClass, storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: valueType.name)
        }
        let retainedType = valueType.retainingCode(storage.codeLifetime!)
        constants.initialize(at: storage.address)
        storage.assumeInitialized(retaining: retainedType) {
            ABISwiftDestroyValue(unsafeBitCast(retainedType.metadata, to: UnsafeRawPointer.self), $0)
        }
        return NativeSwiftValue(storage: storage, type: retainedType)
    }

    func encode(_ value: Any, convention: SwiftArgumentConvention, asynchronous: Bool) throws -> NativeValueStorage {
        let actual: NativeSwiftType
        if let owned = value as? NativeSwiftValue { actual = owned.type }
        else { actual = (value as! NativeSwiftBorrowedValue).type }
        let compatible: Bool
        if actual.metadata == valueType.metadata {
            compatible = true
        } else if convention != .inoutValue, let actualClass = actual.metadata as? AnyClass {
            // An inout Base may replace a Derived reference with another Base.
            // Borrowing and consuming preserve the value's dynamic class.
            compatible = valueType.metadata == AnyObject.self
                || (valueType.metadata as? AnyClass).map { SwiftObjectType(actualClass)?.isSubclass(of: $0) == true } == true
        } else {
            compatible = false
        }
        guard compatible else {
            throw ABIInvocationError.incompatibleValue(expected: valueType.name, actual: actual.name)
        }
        if let owned = value as? NativeSwiftValue { return try owned.access(convention) }
        guard convention == .borrowing else {
            throw ABIResolutionError.unsupportedDeclaration("A borrowed runtime value cannot be mutated or consumed.")
        }
        return try (value as! NativeSwiftBorrowedValue).borrow.access(asynchronous: asynchronous, type: actual)
    }
}
