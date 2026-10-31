import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime
import Foundation

/// A failure creating, inspecting, copying, or accessing a runtime Swift value.
public enum NativeSwiftValueError: Error, Sendable, Equatable {
    /// The native value has already been transferred out of this handle.
    case consumedValue
    /// The native type does not support copying.
    case noncopyableType
    /// An active native operation holds conflicting access to the value.
    case valueInUse
    /// No runtime enum case has the requested name.
    case enumCaseNotFound(name: String)
    /// More than one runtime enum case has the requested name.
    case ambiguousEnumCase(name: String)
    /// The runtime enum case requires an associated payload.
    case enumCaseRequiresPayload(name: String)
    /// The tuple has no element at this zero-based index.
    case tupleElementIndexOutOfBounds(index: Int, count: Int)
}

/// Owns an Escapable Swift value whose concrete type need not be available at compile time.
///
/// Assignment shares this handle. Use copy() for an independent native value. Native code, metadata, and value witnesses remain retained through destruction. The value stays in the caller's isolation domain and is not Sendable.
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

    /// Whether this handle has transferred its value to native code or take(as:). The type and copyability remain available after consumption.
    public var isConsumed: Bool {
        valueOwner.isConsumed
    }

    /// Creates an independent native copy, retaining its implementation images. The native type must be Copyable.
    public func copy() throws -> NativeSwiftValue {
        let source = try access(.borrowing)
        guard isCopyable else { throw NativeSwiftValueError.noncopyableType }
        return try withExtendedLifetime(source) { try Self.copy(from: source.address, type: type) }
    }

    /// Passes an Any copy to body while retaining its implementation images. The native type must be Copyable.
    ///
    /// Standard Swift casts can inspect the copy's existing conformances. If a value escapes body, keep this handle alive while that value may execute dynamically loaded code, including during destruction.
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
    /// This also supports noncopyable Swift types. A type or access error leaves the value owned by this handle. Keep its type handle alive while the returned value may execute code from a dynamically loaded image.
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
    /// The view expires at the end of this scope even if it is saved elsewhere. A conflicting mutation or transfer fails while this borrow remains active. An async member started during the scope retains its read access until native completion, even after the view expires at the end of body.
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

/// Gives up a source handle's value once, when native code or a forwarding
/// hook takes the Optional that holds a copy of it.
final class SwiftOptionalSourceTransfer {
    private let lock = NSLock()
    private var pending: (() -> Void)?
    init(_ giveUp: @escaping () -> Void) { pending = giveUp }
    func complete() {
        lock.lock()
        let giveUp = pending
        pending = nil
        lock.unlock()
        giveUp?()
    }
}

/// Native metadata owns value operations; the formal declaration owns ABI placement.
struct SwiftRuntimeValuePlan: Sendable {
    let valueType: NativeSwiftType
    let type: CValueType
    private(set) var nativeTuple: SwiftTupleValuePlan?
    let nativeClosure: SwiftGenericClosurePlan?
    /// How the host represents the native value, when not as a handle of it.
    enum Projection: @unchecked Sendable {
        /// `NativeSwiftValue?` or `NativeSwiftBorrowedValue?` for this Optional:
        /// nil is the empty case, and a value of the wrapped type is the payload.
        case optional(payload: NativeSwiftType)
        /// A host collection of handles for this Array, Set, or Dictionary.
        case collection(SwiftRuntimeCollectionPlan)
    }
    private(set) var projection: Projection?
    var optionalPayload: NativeSwiftType? {
        if case .optional(let payload) = projection { payload } else { nil }
    }
    private var collection: SwiftRuntimeCollectionPlan? {
        if case .collection(let collection) = projection { collection } else { nil }
    }
    /// The owned host type for the native value.
    var hostType: Any.Type {
        switch projection {
        case nil: NativeSwiftValue.self
        case .optional: NativeSwiftValue?.self
        case .collection(let collection): collection.host.type
        }
    }
    private var closureConversions: SwiftRuntimeClosureConversions
    var hasClosureConversions: Bool { !closureConversions.isEmpty }
    private let size: Int
    private let alignment: Int
    private let constants: SwiftValueConstants
    private let knownTypes: [NativeSwiftType]

    init(metadata: Any.Type, type: CValueType, resolver: SymbolResolver, retaining images: [NativeImage],
        knownTypes: [NativeSwiftType] = [],
        nativeTuple: SwiftTupleValuePlan? = nil,
        nativeClosure: SwiftGenericClosurePlan? = nil
    ) throws {
        try validateSwiftRuntimeValueStorage(metadata)
        self.type = type
        self.knownTypes = knownTypes
        self.nativeTuple = nativeTuple
        self.nativeClosure = nativeClosure
        closureConversions = try SwiftRuntimeClosureConversions(metadata: metadata, tuple: nativeTuple, closure: nativeClosure)
        constants = SwiftValueConstants(ABISwiftValueIsIndirect(type.handle) ? Void.self : metadata)
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(pointer)
        size = layout.stride
        alignment = layout.alignment
        // Bound runtime types may have metadata without a nominal descriptor,
        // such as a generated Objective-C class. Reuse their established owner.
        if let knownType = knownTypes.first(where: { $0.metadata == metadata }) {
            valueType = knownType.retainingCode(
                SwiftValueCodeLifetime(images + knownType.codeImages)
            )
            return
        }
        let name = try swiftNativeTypeName(metadata)
        let image: NativeImage
        if let descriptor = ABISwiftTypeDescriptor(pointer),
           let definingImage = try swiftImplementationImage(containing: descriptor) {
            image = definingImage
        } else if let objectType = metadata as? AnyClass {
            image = try swiftClassImage(
                objectType,
                named: name,
                resolver: resolver,
                retaining: images.first
            )
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

    func makeStorage(didRelinquish: (() -> Void)? = nil) -> NativeValueStorage {
        NativeValueStorage(size: size, alignment: alignment, owner: valueType,
                           codeLifetime: SwiftValueCodeLifetime(valueType.codeImages), didRelinquish: didRelinquish)
    }

    /// This plan with the host passing the Optional as `NativeSwiftValue?` or
    /// `NativeSwiftBorrowedValue?`.
    func projectingOptional() throws -> SwiftRuntimeValuePlan {
        guard runtimeMetadataKind(valueType.metadata) == .optional else {
            throw ABIResolutionError.signatureMismatch(
                .init(expected: "An Optional native type for an Optional runtime value", found: [valueType.name])
            )
        }
        let metadata = unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self)
        guard let payload = ABISwiftEnumCasePayloadMetadata(metadata, 0) else {
            throw ABIResolutionError.metadataUnavailable("The Optional has no payload metadata.")
        }
        let payloadType = unsafeBitCast(payload, to: Any.Type.self)
        // A value passed to native code is copied into the Optional.
        guard SwiftCopyability.accepts(payloadType) else { throw NativeSwiftValueError.noncopyableType }
        var plan = self
        plan.projection = .optional(
            payload: try swiftRuntimeValueType(
                metadata: payloadType,
                retaining: [valueType] + knownTypes
            )
        )
        return plan
    }

    /// This plan with the host passing the collection as `host`.
    func projectingCollection(_ host: SwiftHostCollection) throws -> SwiftRuntimeValuePlan {
        var plan = self
        plan.projection = .collection(
            try SwiftRuntimeCollectionPlan(native: valueType, host: host, retaining: knownTypes)
        )
        return plan
    }

    /// Builds the Optional from the host's `NativeSwiftValue?` or
    /// `NativeSwiftBorrowedValue?`. A value is copied into the payload; a
    /// consumed handle gives up its value when native code takes the Optional.
    private func wrapOptional(_ value: Any, payload: NativeSwiftType, convention: SwiftArgumentConvention,
                              asynchronous: Bool) throws -> (value: NativeSwiftValue, transfer: SwiftOptionalSourceTransfer?) {
        guard convention != .inoutValue else {
            throw ABIResolutionError.unsupportedDeclaration("An inout Optional runtime value is unsupported.")
        }
        let metadata = unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self)
        let source: (type: NativeSwiftType, access: NativeValueStorage)?
        if let owned = value as? NativeSwiftValue {
            source = (owned.type, try owned.access(convention))
        } else if let borrowed = value as? NativeSwiftBorrowedValue {
            source = (borrowed.type, try borrowed.borrow.access(
                asynchronous: asynchronous, type: borrowed.type, convention: convention))
        } else {
            source = nil
        }
        guard let source else {
            let storage = makeStorage()
            ABISwiftInitializeEmptyEnumCase(metadata, storage.address, 1)
            storage.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
            return (NativeSwiftValue(storage: storage, type: valueType), nil)
        }
        guard Self.accepts(source.type, as: payload, convention: convention) else {
            throw ABIInvocationError.incompatibleValue(expected: payload.name, actual: source.type.name)
        }
        let payloadMetadata = unsafeBitCast(payload.metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(payloadMetadata)
        let copy = NativeValueStorage(size: layout.stride, alignment: layout.alignment)
        ABISwiftCopyValue(payloadMetadata, copy.address, source.access.address)
        let transfer = convention == .consuming ? SwiftOptionalSourceTransfer {
            ABISwiftDestroyValue(payloadMetadata, source.access.address)
            source.access.relinquishValue()
        } : nil
        let storage = makeStorage(didRelinquish: transfer.map { transfer in { transfer.complete() } })
        // The Optional also needs the code the payload's value needs.
        if let lifetime = storage.codeLifetime, let payloadLifetime = source.access.codeLifetime {
            _ = SwiftValueCodeLifetime.connect([lifetime, payloadLifetime], retaining: [])
        }
        ABISwiftInitializeEnumCase(metadata, storage.address, 0, payloadMetadata, false, copy.address)
        storage.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
        storage.retainResource(source.access)
        return (NativeSwiftValue(storage: storage, type: valueType), transfer)
    }

    /// Projects a native Optional for the host: nil, or its payload as an
    /// independently owned value. This consumes `value`.
    func unwrapOptional(_ value: NativeSwiftValue) throws -> NativeSwiftValue? {
        guard optionalPayload != nil else { return value }
        return projectOptional(try value.valueOwner.transferStorage())
    }

    /// Projects Optional storage the caller owns: nil, or its payload, which
    /// the projection takes out of `storage`.
    func projectOptional(_ storage: NativeValueStorage) -> NativeSwiftValue? {
        guard let payload = optionalPayload, !isEmptyOptional(at: storage.address) else { return nil }
        let metadata = unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self)
        let payloadMetadata = unsafeBitCast(payload.metadata, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(payloadMetadata)
        // The payload keeps the code lifetime the Optional's result retained.
        let type = storage.codeLifetime.map { payload.retainingCode($0) } ?? payload
        let projected = NativeValueStorage(size: layout.stride, alignment: layout.alignment, owner: type,
                                           codeLifetime: storage.codeLifetime ?? type.codeLifetime)
        ABISwiftTakeEnumPayload(metadata, storage.address, payloadMetadata, false, projected.address)
        storage.relinquishValue()
        projected.assumeInitialized { ABISwiftDestroyValue(payloadMetadata, $0) }
        return NativeSwiftValue(storage: projected, type: type)
    }

    /// Projects a borrowed native Optional for the host: nil, or a borrow of
    /// its payload, which a single-payload enum stores at the same address.
    func unwrapOptional(_ value: NativeSwiftBorrowedValue) throws -> NativeSwiftBorrowedValue? {
        guard let payload = optionalPayload else { return value }
        guard try !value.borrow.withAddress(isEmptyOptional(at:)) else { return nil }
        return NativeSwiftBorrowedValue(type: payload, borrow: value.borrow)
    }

    /// A borrow of the native Optional at `address` for the host.
    func borrowOptional(at address: UnsafeRawPointer, borrow: SwiftValueBorrow,
                        lifetime: SwiftValueCodeLifetime) -> NativeSwiftBorrowedValue? {
        guard let payload = optionalPayload, !isEmptyOptional(at: address) else { return nil }
        return NativeSwiftBorrowedValue(type: payload.retainingCode(lifetime), borrow: borrow)
    }

    private func isEmptyOptional(at address: UnsafeRawPointer) -> Bool {
        var tag: UInt32 = 0
        _ = ABISwiftGetEnumTag(unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self), address, &tag)
        return tag != 0
    }

    /// The host value for a native result or callback input: the value itself,
    /// or its projection for the host's `NativeSwiftValue?` or collection.
    func hostValue(_ value: NativeSwiftValue) throws -> Any {
        switch projection {
        case nil: return value
        case .optional: return try unwrapOptional(value) as Any
        case .collection(let collection):
            let storage = try value.valueOwner.transferStorage()
            return collection.hostValue(ofNative: storage.address, lifetime: storage.codeLifetime)
        }
    }

    func hostValue(_ value: NativeSwiftBorrowedValue) throws -> Any {
        switch projection {
        case nil: return value
        case .optional: return try unwrapOptional(value) as Any
        case .collection(let collection):
            return try value.borrow.withAddress {
                collection.hostValue(ofNative: $0, lifetime: value.type.codeLifetime)
            }
        }
    }

    /// Projects native storage the caller owns for the host, which owns the
    /// projection. Requires a projection.
    func project(_ storage: NativeValueStorage) -> Any {
        if let collection {
            return collection.hostValue(ofNative: storage.address, lifetime: storage.codeLifetime)
        }
        return projectOptional(storage) as Any
    }

    /// Takes the host value a callback returned in `storage`.
    func takeHostValue(from storage: NativeValueStorage) -> Any {
        func take<Host>(_: Host.Type) -> Any { storage.take(as: Host.self) }
        return _openExistential(hostType, do: take)
    }

    /// Storage holding `value` as the host type.
    func hostStorage(_ value: Any, codeLifetime: SwiftValueCodeLifetime?) -> NativeValueStorage {
        func store<Host>(_: Host.Type) -> NativeValueStorage {
            let storage = NativeValueStorage(size: MemoryLayout<Host>.stride, alignment: MemoryLayout<Host>.alignment,
                                             codeLifetime: codeLifetime)
            storage.initialize(value as! Host)
            return storage
        }
        return _openExistential(hostType, do: store)
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
        guard SwiftGenericCallPlan.runtimeHandle(representation)?.type != NativeSwiftBorrowedValue.self else {
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

    static func accepts(_ actual: NativeSwiftType, as expected: NativeSwiftType,
                                convention: SwiftArgumentConvention) -> Bool {
        if actual.metadata == expected.metadata { return true }
        // An inout Base may replace a Derived reference with another Base.
        // Borrowing and consuming preserve the value's dynamic class.
        guard convention != .inoutValue, let actualClass = actual.metadata as? AnyClass else { return false }
        return expected.metadata == AnyObject.self
            || (expected.metadata as? AnyClass).map { SwiftObjectType(actualClass)?.isSubclass(of: $0) == true } == true
    }

    func encode(_ value: Any, convention: SwiftArgumentConvention, asynchronous: Bool) throws -> NativeValueStorage {
        if let collection {
            guard convention != .inoutValue else {
                throw ABIResolutionError.unsupportedDeclaration("An inout runtime collection is unsupported.")
            }
            var plan = self
            plan.projection = nil
            return try plan.encode(try collection.makeNative(value, type: valueType), convention: convention,
                                   asynchronous: asynchronous)
        }
        if let optionalPayload {
            let wrapped = try wrapOptional(value, payload: optionalPayload, convention: convention,
                                           asynchronous: asynchronous)
            var plan = self
            plan.projection = nil
            let access = try plan.encode(wrapped.value, convention: convention, asynchronous: asynchronous)
            // A hook forwarding the Optional takes it without native code
            // consuming it, so the transfer also gives up the source's value.
            if let transfer = wrapped.transfer, let forward = access.transferHookOwnership {
                access.transferHookOwnership = {
                    let storage = try forward()
                    transfer.complete()
                    return storage
                }
            }
            return access
        }
        let actual: NativeSwiftType
        if let owned = value as? NativeSwiftValue { actual = owned.type }
        else { actual = (value as! NativeSwiftBorrowedValue).type }
        guard Self.accepts(actual, as: valueType, convention: convention) else {
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

    func usingTupleStorageConvention(binding: SwiftGenericBinding) throws -> Self {
        guard let nativeTuple, nativeTuple.hasNestedClosures else { return self }
        var plan = self
        plan.nativeTuple = try nativeTuple.usingStorageConvention(binding: binding)
        plan.closureConversions = try SwiftRuntimeClosureConversions(
            metadata: valueType.metadata, tuple: plan.nativeTuple, closure: nativeClosure)
        return plan
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
