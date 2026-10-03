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

    let valueOwner: SwiftRuntimeValueOwner

    init(storage: NativeValueStorage, type: NativeSwiftType) {
        valueOwner = storage.runtimeValueOwner ?? SwiftRuntimeValueOwner(storage: storage)
        storage.runtimeValueOwner = valueOwner
        self.type = type
        isCopyable = SwiftCopyability.accepts(type.metadata)
    }

    /// Whether this handle has transferred its value to native code or take(as:).
    /// The type and copyability remain available after consumption.
    public var isConsumed: Bool {
        valueOwner.isConsumed
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
        try valueOwner.access(convention)
    }
}

// Native storage and all public aliases share a single ownership state.
final class SwiftRuntimeValueOwner {
    private let lock = NSLock()
    private var storage: NativeValueStorage?
    private var readers = 0
    private var exclusive = false
    private var reservations = 0
    init(storage: NativeValueStorage) { self.storage = storage }
    var isConsumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage == nil
    }
    func ownedStorage() throws -> NativeValueStorage {
        lock.lock(); defer { lock.unlock() }
        guard let storage else { throw NativeSwiftValueError.consumedValue }
        return storage
    }
    func transferStorage() throws -> NativeValueStorage {
        lock.lock(); defer { lock.unlock() }
        guard let storage else { throw NativeSwiftValueError.consumedValue }
        guard !exclusive, readers == 0 else { throw NativeSwiftValueError.valueInUse }
        self.storage = nil
        storage.runtimeValueOwner = nil
        return storage
    }
    func reserve() { lock.lock(); reservations += 1; lock.unlock() }
    func releaseReservation() { lock.lock(); reservations -= 1; lock.unlock() }
    func access(_ convention: SwiftArgumentConvention) throws -> NativeValueStorage {
        lock.lock()
        guard let storage else { lock.unlock(); throw NativeSwiftValueError.consumedValue }
        let writes = convention != .borrowing
        guard !exclusive, !writes || readers == 0,
              convention != .consuming || reservations == 0 || SwiftHookRecoveryScope.authorizes(self) else {
            lock.unlock(); throw NativeSwiftValueError.valueInUse
        }
        if writes { exclusive = true } else { readers += 1 }
        lock.unlock()
        let access = SwiftRuntimeValueAccess(storage: storage, resume: {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.storage != nil else { throw NativeSwiftValueError.consumedValue }
            guard !self.exclusive, !writes || self.readers == 0 else { throw NativeSwiftValueError.valueInUse }
            if writes { self.exclusive = true } else { self.readers += 1 }
        }, release: {
            self.lock.lock()
            if writes { self.exclusive = false } else { self.readers -= 1 }
            self.lock.unlock()
        }, consume: {
            self.lock.lock()
            if self.storage === storage {
                storage.relinquishValue()
                self.storage = nil
            }
            self.lock.unlock()
        })
        let result = NativeValueStorage(borrowing: storage.address, owner: access, retainingResourcesOf: storage,
                                  didRelinquish: convention == .consuming ? { access.consume() } : nil)
        if convention == .consuming {
            result.suspendHookAccess = { access.suspend() }
            result.resumeHookAccess = { try access.resume() }
            result.transferHookOwnership = { try self.transferStorage() }
        }
        return result
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
    private let resumeAccess: () throws -> Void
    private let releaseAccess: () -> Void
    private let consumeValue: () -> Void
    private var active = true
    private var consumed = false
    init(storage: NativeValueStorage, resume: @escaping () throws -> Void,
         release: @escaping () -> Void, consume: @escaping () -> Void) {
        self.storage = storage; resumeAccess = resume; releaseAccess = release; consumeValue = consume
    }
    // A downstream hook runs before native execution. Its canonical owner may
    // be inspected while this forwarding lease retains storage for a later call.
    func suspend() {
        guard active else { return }
        active = false
        releaseAccess()
    }
    func resume() throws {
        guard !active else { return }
        try resumeAccess()
        active = true
    }
    func consume() {
        guard !consumed else { return }
        consumed = true
        consumeValue()
        suspend()
    }
    deinit { if active { releaseAccess() } }
}

/// Native metadata owns value operations; the formal declaration owns ABI placement.
struct SwiftRuntimeValuePlan: Sendable {
    let valueType: NativeSwiftType
    let type: CValueType
    let nativeTuple: SwiftTupleValuePlan?
    let nativeClosure: SwiftGenericClosurePlan?
    private let closureConversions: SwiftRuntimeClosureConversions
    var hasClosureConversions: Bool { !closureConversions.isEmpty }
    private let size: Int
    private let alignment: Int
    private let constants: SwiftValueConstants

    init(metadata: Any.Type, type: CValueType, resolver: SymbolResolver, retaining images: [NativeImage],
         nativeTuple: SwiftTupleValuePlan? = nil, nativeClosure: SwiftGenericClosurePlan? = nil) throws {
        self.type = type
        self.nativeTuple = nativeTuple
        self.nativeClosure = nativeClosure
        closureConversions = try SwiftRuntimeClosureConversions(metadata: metadata, tuple: nativeTuple, closure: nativeClosure)
        constants = SwiftValueConstants(ABISwiftValueIsIndirect(type.handle) ? Void.self : metadata)
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
        NativeSwiftValue(storage: copyCallbackStorage(from: address, type: type), type: type)
    }

    func copyCallbackStorage(from address: UnsafeRawPointer, type: NativeSwiftType) -> NativeValueStorage {
        let storage = copyStorage(from: address, type: type)
        normalizeCallbackArgument(storage)
        return storage
    }

    private func copyStorage(from address: UnsafeRawPointer, type: NativeSwiftType,
                             retaining owner: AnyObject? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
                             didRelinquish: (() -> Void)? = nil) -> NativeValueStorage {
        let storage = NativeValueStorage(size: size, alignment: alignment, owner: type,
            codeLifetime: codeLifetime ?? type.codeLifetime, didRelinquish: didRelinquish)
        ABISwiftCopyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), storage.address, address)
        storage.assumeInitialized(retaining: owner) {
            ABISwiftDestroyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), $0)
        }
        return storage
    }

    func normalizeCallbackArgument(_ storage: NativeValueStorage) {
        closureConversions.apply(to: storage, native: false, retainingCode: valueType,
                                 codeLifetime: storage.codeLifetime)
    }

    func prepareCallbackWriteback(from storage: NativeValueStorage, to nativeAddress: UnsafeMutableRawPointer) -> (() -> Void) {
        let replacement = copyStorage(from: storage.address, type: valueType, retaining: storage, codeLifetime: storage.codeLifetime)
        closureConversions.apply(to: replacement, native: true, retainingCode: valueType,
                                 codeLifetime: replacement.codeLifetime)
        return replaceValue(at: nativeAddress, with: replacement)
    }

    private func replaceValue(at address: UnsafeMutableRawPointer, with replacement: NativeValueStorage) -> (() -> Void) {
        let metadata = unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self)
        let previous = makeStorage()
        return {
            ABISwiftTakeValue(metadata, previous.address, address)
            previous.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
            ABISwiftTakeValue(metadata, address, replacement.address)
            replacement.relinquishValue()
        }
    }

    func takeCallbackArgument(from address: UnsafeMutableRawPointer, type: NativeSwiftType) -> NativeSwiftValue {
        let storage = NativeValueStorage(size: size, alignment: alignment, owner: type,
            codeLifetime: type.codeLifetime)
        constants.initialize(at: address)
        ABISwiftTakeValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), storage.address, address)
        storage.assumeInitialized {
            ABISwiftDestroyValue(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self), $0)
        }
        normalizeCallbackArgument(storage)
        return NativeSwiftValue(storage: storage, type: type)
    }

    func requireOwnedValue(as representation: Any.Type = NativeSwiftValue.self) throws {
        guard representation != NativeSwiftBorrowedValue.self else {
            throw ABIResolutionError.unsupportedDeclaration("A borrowed runtime result requires a scoped result lifetime.")
        }
        guard SwiftEscapability.accepts(valueType.metadata) else {
            throw ABIResolutionError.unsupportedDeclaration("An owned runtime value requires an Escapable native type.")
        }
    }

    func initializeResult(_ storage: NativeValueStorage) throws -> NativeSwiftType {
        if valueType.metadata is AnyClass, storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: valueType.name)
        }
        let retainedType = valueType.retainingCode(storage.codeLifetime!)
        guard storage.runtimeValueOwner == nil else { return retainedType }
        constants.initialize(at: storage.address)
        storage.assumeInitialized(retaining: retainedType) {
            ABISwiftDestroyValue(unsafeBitCast(retainedType.metadata, to: UnsafeRawPointer.self), $0)
        }
        normalizeCallbackArgument(storage)
        return retainedType
    }

    func decode(_ storage: NativeValueStorage) throws -> NativeSwiftValue {
        NativeSwiftValue(storage: storage, type: try initializeResult(storage))
    }

    func withBorrowedResult<Output: ~Copyable>(_ storage: NativeValueStorage,
        _ body: (NativeSwiftBorrowedValue) throws -> Output) throws -> Output {
        let type = try initializeResult(storage)
        let borrow = SwiftValueBorrow(UnsafeRawPointer(storage.address))
        defer { borrow.expire(); storage.destroyInitializedValue() }
        return try body(NativeSwiftBorrowedValue(type: type, borrow: borrow))
    }

    nonisolated(nonsending) func withBorrowedResult<Output: ~Copyable>(_ storage: NativeValueStorage,
        _ body: (NativeSwiftBorrowedValue) async throws -> Output) async throws -> Output {
        let type = try initializeResult(storage)
        let borrow = SwiftValueBorrow(UnsafeRawPointer(storage.address), allowsSuspension: true)
        defer { borrow.expire(); storage.destroyInitializedValue() }
        return try await body(NativeSwiftBorrowedValue(type: type, borrow: borrow))
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
        let access: NativeValueStorage
        if let owned = value as? NativeSwiftValue { access = try owned.access(convention) }
        else {
            access = try (value as! NativeSwiftBorrowedValue).borrow.access(
                asynchronous: asynchronous, type: actual, convention: convention)
        }
        guard hasClosureConversions else { return access }
        let metadata = unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self)
        // Conversion owns a copy until native invocation commits. Consuming that
        // copy also ends the handle's original canonical value and exclusive access.
        let native = copyStorage(from: access.address, type: valueType, retaining: access,
            codeLifetime: access.codeLifetime, didRelinquish: convention == .consuming ? {
                ABISwiftDestroyValue(metadata, access.address)
                access.relinquishValue()
            } : nil)
        closureConversions.apply(to: native, native: true, retainingCode: valueType,
                                 codeLifetime: native.codeLifetime)
        if convention == .consuming {
            let address = native.address
            native.destroyTransferredCopy = { ABISwiftDestroyValue(metadata, address) }
        }
        if convention == .inoutValue {
            let address = native.address
            let lifetime = native.codeLifetime
            native.prepareWriteback = {
                let replacement = self.copyStorage(from: address, type: self.valueType, codeLifetime: lifetime)
                self.normalizeCallbackArgument(replacement)
                return self.replaceValue(at: access.address, with: replacement)
            }
        }
        return native
    }

    func encodeArgument(_ value: Any, convention: SwiftArgumentConvention, asynchronous: Bool) throws -> NativeValueStorage {
        let access = try encode(value, convention: convention, asynchronous: asynchronous)
        guard convention != .inoutValue, let nativeTuple else { return access }
        let addresses = nativeTuple.nativeArgumentAddresses(access.address)
        let vector = NativeValueStorage(size: addresses.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
            alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment, owner: access, codeLifetime: access.codeLifetime,
            didRelinquish: convention == .consuming ? { access.relinquishValue() } : nil)
        if convention == .consuming {
            vector.destroyTransferredCopy = {
                ABISwiftDestroyValue(unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self), access.address)
            }
        }
        for (index, address) in addresses.enumerated() {
            vector.address.storeBytes(of: address,
                toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride, as: UnsafeMutableRawPointer?.self)
        }
        return vector
    }
}
