import Foundation

protocol NativeOptionalValue {
    var wrappedValue: Any? { get }
    static var wrappedType: Any.Type { get }
    static var nilValue: Any { get }
    static func wrapping(_ value: Any) throws -> Any
}
extension Optional: NativeOptionalValue {
    var wrappedValue: Any? {
        switch self {
        case .some(let value): value as Any
        case .none: nil
        }
    }
    static var wrappedType: Any.Type { Wrapped.self }
    static var nilValue: Any { Self.none as Any }
    static func wrapping(_ value: Any) throws -> Any {
        guard let value = value as? Wrapped else {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: Wrapped.self),
                                                      actual: String(reflecting: type(of: value)))
        }
        return Self.some(value) as Any
    }
}

protocol NativePointerValue: SendableMetatype {
    var rawPointer: UnsafeRawPointer { get }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any
}
extension UnsafeRawPointer: NativePointerValue {
    var rawPointer: UnsafeRawPointer { self }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { pointer }
}
extension UnsafeMutableRawPointer: NativePointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { UnsafeMutableRawPointer(mutating: pointer) }
}
extension UnsafePointer: NativePointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { pointer.assumingMemoryBound(to: Pointee.self) }
}
extension UnsafeMutablePointer: NativePointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any {
        UnsafeMutableRawPointer(mutating: pointer).assumingMemoryBound(to: Pointee.self)
    }
}
extension OpaquePointer: NativePointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { OpaquePointer(pointer) }
}
extension Unmanaged: NativePointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(toOpaque()) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { Self.fromOpaque(pointer) }
}
extension Selector: NativePointerValue {
    var rawPointer: UnsafeRawPointer { unsafeBitCast(self, to: UnsafeRawPointer.self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { unsafeBitCast(pointer, to: Selector.self) }
}

final class NativeValueStorage {
    let address: UnsafeMutableRawPointer
    private(set) var owner: AnyObject?
    private var destroyValue: ((UnsafeMutableRawPointer) -> Void)?
    private let ownsAllocation: Bool
    private let resultStorage: NativeValueStorage?
    let codeLifetime: SwiftValueCodeLifetime?
    var ownerForResult: NativeValueStorage { resultStorage ?? self }
    private var didRelinquish: (() -> Void)?
    var transfersOwnership: Bool { didRelinquish != nil }

    init(borrowing address: UnsafeMutableRawPointer, owner: AnyObject,
         retainingResourcesOf storage: NativeValueStorage? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         didRelinquish: (() -> Void)? = nil) {
        self.address = address
        self.owner = owner
        self.didRelinquish = didRelinquish
        // Escaping results retain the value's resources, not its active access.
        resultStorage = storage?.ownerForResult
        self.codeLifetime = codeLifetime ?? storage?.codeLifetime
        ownsAllocation = false
    }

    init(size: Int, alignment: Int, owner: AnyObject? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         destroyingWith destroy: ((UnsafeMutableRawPointer) -> Void)? = nil) {
        address = .allocate(byteCount: max(size, 1), alignment: max(alignment, 1))
        address.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
        self.owner = owner
        destroyValue = destroy
        resultStorage = nil
        self.codeLifetime = codeLifetime
        ownsAllocation = true
    }
    deinit {
        withExtendedLifetime((owner, codeLifetime)) { destroyValue?(address) }
        if ownsAllocation { address.deallocate() }
    }

    func initialize<Value>(_ value: Value) {
        address.initializeMemory(as: Value.self, repeating: value, count: 1)
        destroyValue = { $0.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
    }

    // Native success has initialized this storage; failure paths never adopt it.
    func assumeInitialized<Value: ~Copyable>(as type: Value.Type) {
        destroyValue = { $0.assumingMemoryBound(to: type).deinitialize(count: 1) }
    }

    func assumeInitialized(retaining owner: AnyObject? = nil, destroyingWith destroy: @escaping (UnsafeMutableRawPointer) -> Void) {
        if let owner { self.owner = owner }
        destroyValue = destroy
    }

    func take<Value: ~Copyable>(as type: Value.Type) -> Value {
        let value = address.assumingMemoryBound(to: type).move()
        destroyValue = nil
        return value
    }

    func writebackOwner(retaining images: [NativeImage]) -> Any {
        if let resultStorage { return resultStorage.writebackOwner(retaining: images) }
        if let value = owner as? NativeValue {
            return value.lifetimeForCopy(retaining: images)
        }
        return self
    }

    // Called only after a native call has consumed the initialized value.
    func relinquishValue() {
        destroyValue = nil
        let notify = didRelinquish
        didRelinquish = nil
        notify?()
    }

    func store<T>(_ value: T) {
        withUnsafeBytes(of: value) {
            if let base = $0.baseAddress, !$0.isEmpty { address.copyMemory(from: base, byteCount: $0.count) }
        }
    }
}
