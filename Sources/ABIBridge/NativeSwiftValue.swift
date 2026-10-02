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

/// Owns a Swift value whose concrete type need not be available at compile time.
///
/// Assignment shares this handle. Use copy() for an independent native value.
/// Native code, metadata, and value witnesses remain retained through destruction.
/// The value stays in the caller's isolation domain and is not Sendable.
public final class NativeSwiftValue {
    /// The actual runtime type and its retained implementation images.
    public let type: NativeSwiftType
    /// Whether the native value-witness table permits copying.
    public let isCopyable: Bool

    private let lock = NSLock()
    private var storage: NativeValueStorage?
    private var readers = 0
    private var exclusive = false

    init(storage: NativeValueStorage, type: NativeSwiftType) {
        self.storage = storage
        self.type = type
        isCopyable = ABISwiftGetValueLayout(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)).isCopyable
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
            try body(_openExistential(type.metadata, do: read))
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
    public func withBorrowedValue<Result>(
        _ body: (NativeSwiftBorrowedValue) throws -> Result
    ) throws -> Result {
        let source = try access(.borrowing)
        let borrow = SwiftValueBorrow(UnsafeRawPointer(source.address))
        defer { withExtendedLifetime(source) { borrow.expire() } }
        return try body(NativeSwiftBorrowedValue(type: type, borrow: borrow))
    }

    static func copy(from source: UnsafeRawPointer, type: NativeSwiftType) throws -> NativeSwiftValue {
        let metadata = unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        let destination = NativeValueStorage(size: layout.stride, alignment: layout.alignment, owner: type)
        guard ABISwiftCopyValue(metadata, destination.address, source) else {
            throw NativeSwiftValueError.noncopyableType
        }
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
        return NativeValueStorage(borrowing: storage.address, owner: access,
                                  didRelinquish: convention == .consuming ? { access.consume() } : nil)
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
