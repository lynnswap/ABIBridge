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

typealias SwiftWritebackPreparation = () throws -> (() -> Void)

func finishSwiftInvocation<Output: ~Copyable>(
    _ outcome: consuming Result<Output, any Error>, writeback: () throws -> Void
) throws -> Output {
    do {
        try writeback()
    } catch {
        if case .failure(let invocationError) = outcome {
            throw NativeSwiftWritebackError(invocationError: invocationError, writebackError: error)
        }
        throw error
    }
    return try outcome.get()
}

struct NativeCallStorageLayout: Sendable {
    let offsets: [Int]
    let resultOffset: Int
    let size: Int
    let alignment: Int

    init(result: (size: Int, alignment: Int), parameters: [(size: Int, alignment: Int)]) throws {
        var extent = 0
        var alignment = result.alignment
        func append(_ value: (size: Int, alignment: Int)) throws -> Int {
            let padding = (value.alignment - extent % value.alignment) % value.alignment
            let (offset, paddingOverflow) = extent.addingReportingOverflow(padding)
            let (end, sizeOverflow) = offset.addingReportingOverflow(max(value.size, 1))
            guard !paddingOverflow, !sizeOverflow else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Combined call storage is not representable."
                )
            }
            extent = end
            alignment = max(alignment, value.alignment)
            return offset
        }
        offsets = try parameters.map { try append($0) }
        resultOffset = try append(result)
        size = extent
        self.alignment = alignment
    }

    func withStorage<Result>(
        _ body: (UnsafeMutableBufferPointer<UnsafeMutableRawPointer?>, UnsafeMutableRawPointer)
            throws -> Result
    ) rethrows -> Result {
        try withUnsafeTemporaryAllocation(byteCount: size, alignment: alignment) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            return try withUnsafeTemporaryAllocation(
                of: UnsafeMutableRawPointer?.self,
                capacity: offsets.count
            ) { addresses in
                addresses.initialize(repeating: nil)
                defer { addresses.deinitialize() }
                let base = bytes.baseAddress!
                for (index, offset) in offsets.enumerated() { addresses[index] = base + offset }
                return try body(addresses, base + resultOffset)
            }
        }
    }
}

final class NativeValueStorage {
    let address: UnsafeMutableRawPointer
    weak var runtimeValueOwner: SwiftRuntimeValueOwner?
    private(set) var owner: AnyObject?
    private var destroyValue: ((UnsafeMutableRawPointer) -> Void)?
    private let ownsAllocation: Bool
    private let resultStorage: NativeValueStorage?
    private var resources: [AnyObject] = []
    let codeLifetime: SwiftValueCodeLifetime?
    var ownerForResult: NativeValueStorage { resultStorage ?? self }
    private var didRelinquish: (() -> Void)?
    var transfersOwnership: Bool { didRelinquish != nil }
    var prepareWriteback: SwiftWritebackPreparation?
    var suspendHookAccess: (() -> Void)?
    var resumeHookAccess: (() throws -> Void)?
    var transferHookOwnership: (() throws -> NativeValueStorage)?
    var destroyTransferredCopy: (() -> Void)?

    init(borrowing address: UnsafeMutableRawPointer, owner: AnyObject,
         retainingResourcesOf storage: NativeValueStorage? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         didRelinquish: (() -> Void)? = nil) {
        self.address = address
        self.owner = owner
        self.didRelinquish = didRelinquish
        // Escaping results retain the value's resources, not its active access.
        resultStorage = storage?.ownerForResult
        runtimeValueOwner = storage?.runtimeValueOwner
        self.codeLifetime = codeLifetime ?? storage?.codeLifetime
        ownsAllocation = false
    }

    init(size: Int, alignment: Int, owner: AnyObject? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         didRelinquish: (() -> Void)? = nil,
         destroyingWith destroy: ((UnsafeMutableRawPointer) -> Void)? = nil) {
        address = .allocate(byteCount: max(size, 1), alignment: max(alignment, 1))
        address.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
        self.owner = owner
        self.didRelinquish = didRelinquish
        destroyValue = destroy
        resultStorage = nil
        self.codeLifetime = codeLifetime
        ownsAllocation = true
    }
    deinit {
        withExtendedLifetime((owner, codeLifetime, resources)) { destroyValue?(address) }
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

    func retainResource(_ resource: AnyObject) {
        resources.append(resource)
    }

    func retainOwner(_ owner: AnyObject?) {
        self.owner = owner
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

    func destroyInitializedValue() {
        let destroy = destroyValue
        destroyValue = nil
        withExtendedLifetime((owner, codeLifetime)) { destroy?(address) }
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
