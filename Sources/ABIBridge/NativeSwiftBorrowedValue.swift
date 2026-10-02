import ABIBridgeCore
import Foundation
import Darwin

/// A borrowed native value was used outside its lifetime or suspension contract.
public enum NativeSwiftBorrowError: Error, Sendable, Equatable {
    /// The scope providing this value has returned.
    case expiredBorrow
    /// Access attempted to leave the thread executing the callback.
    case wrongThread
    /// The native source guarantees this borrowed storage only until its synchronous callback returns.
    case synchronousBorrow
}

final class SwiftValueBorrow {
    private let lock = NSLock()
    private let thread = pthread_self()
    private var address: UnsafeRawPointer?
    private var storageOwner: NativeValueStorage?

    init(_ address: UnsafeRawPointer, retaining owner: NativeValueStorage? = nil) {
        self.address = address
        storageOwner = owner
    }

    func withAddress<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result {
        try withStorage { address, _ in try body(address) }
    }

    private func withStorage<Result>(
        _ body: (UnsafeRawPointer, NativeValueStorage?) throws -> Result
    ) throws -> Result {
        lock.lock()
        guard let address else { lock.unlock(); throw NativeSwiftBorrowError.expiredBorrow }
        guard pthread_equal(thread, pthread_self()) != 0 else {
            lock.unlock(); throw NativeSwiftBorrowError.wrongThread
        }
        let owner = storageOwner
        lock.unlock()
        return try withExtendedLifetime(owner) { try body(address, owner) }
    }

    func access(asynchronous: Bool, type: NativeSwiftType) throws -> NativeValueStorage {
        try withStorage { address, owner in
            // An owned-value borrow can keep its read access through suspension.
            // A synchronous native callback gives us no way to extend its storage.
            guard !asynchronous || owner != nil else { throw NativeSwiftBorrowError.synchronousBorrow }
            return NativeValueStorage(borrowing: UnsafeMutableRawPointer(mutating: address), owner: owner ?? self,
                                      retainingResourcesOf: owner, codeLifetime: type.codeLifetime)
        }
    }

    func expire() {
        lock.lock()
        address = nil
        let owner = storageOwner
        storageOwner = nil
        lock.unlock()
        withExtendedLifetime(owner) {}
    }
}

/// A scoped view of a runtime-only Swift value.
///
/// The storage belongs to a native caller or NativeSwiftValue. Saving this view
/// does not extend its scope; new access after return or from another thread
/// throws. An owned-value borrow can keep a started async member's read access
/// until completion. A synchronous native callback cannot extend its storage
/// across suspension and rejects async member entry with synchronousBorrow.
/// The value is not Sendable and retains the declaration's isolation contract.
public struct NativeSwiftBorrowedValue {
    /// The actual native type and its retained implementation image.
    public let type: NativeSwiftType
    let borrow: SwiftValueBorrow

    init(type: NativeSwiftType, borrow: SwiftValueBorrow) {
        self.type = type
        self.borrow = borrow
    }

    /// Copies the native value into an independent owner while the borrow is active.
    public func copy() throws -> NativeSwiftValue {
        try borrow.withAddress { try NativeSwiftValue.copy(from: $0, type: type) }
    }
}

/// A synchronous Swift callback borrowing one formally indirect native value.
///
/// Use a complete source-level declaration when passing this callback to
/// `swiftFunction`: its argument type is known at runtime. The native declaration
/// must pass that exact type indirectly with guaranteed ownership. This is an
/// explicit ABI contract, not an inference from the value's size or metadata.
/// The native callee may retain the callback; each later invocation creates a
/// fresh borrow. Returned runtime-typed closures are outside this subset.
public struct NativeSwiftBorrowingClosure<Result> {
    private let storage: SwiftClosureStorage

    /// Creates a callback whose argument remains owned by its native caller.
    ///
    /// The body runs synchronously on the native caller's thread, without an
    /// executor hop. It must be safe for the declaration's possible callers.
    /// Prepare member handles before entering the callback. Results use the
    /// same supported concrete Swift representations as NativeSwiftClosure.
    public init(borrowing type: NativeSwiftType,
                _ body: @escaping @Sendable (NativeSwiftBorrowedValue) -> Result) throws {
        guard !(type.metadata is AnyClass) else {
            throw ABIResolutionError.unsupportedDeclaration("A resilient value callback requires a Swift value type.")
        }
        func layout<Value>(_ value: Value.Type) throws -> CValueType {
            try CValueType(indirectSwiftSize: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        }
        let argument = try _openExistential(type.metadata, do: layout)
        let result = try SwiftValueCodec<Result>()
        let discriminator = swiftClosureDiscriminator(parameters: ["-indirect"], results: try swiftClosureAuthTypes(Result.self))
        let interface = try SwiftCallInterface.cached(result: result.type, parameters: [argument])
        let callback = try SwiftClosureCallbackOwner(interface: interface, body: SwiftClosureBody(retainingCode: type) { arguments, output in
            let borrow = SwiftValueBorrow(UnsafeRawPointer(arguments![0]!))
            defer { borrow.expire() }
            let value = body(NativeSwiftBorrowedValue(type: type, borrow: borrow))
            output.initializeMemory(as: Result.self, repeating: value, count: 1)
        })
        let value = ABISwiftClosureValue(
            function: ABISignSwiftClosureFunction(callback.function, discriminator),
            context: Unmanaged.passRetained(callback).toOpaque()
        )
        storage = try SwiftClosureStorage(adopting: value, discriminator: discriminator, retaining: type)
    }
}

extension NativeSwiftBorrowingClosure: SwiftClosureValue {
    static var swiftFunctionType: Any.Type { ((NativeSwiftBorrowedValue) -> Result).self }
    static var requiresExplicitDeclaration: Bool { true }
    static var supportsResult: Bool { false }
    func encodeClosure() -> NativeValueStorage { storage.encoded() }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        let pointer = try CValueType(scalar: ABIValuePointer)
        return SwiftClosureCodec(type: try CValueType(fields: [pointer, pointer])) { _, _, _ in
            throw ABIResolutionError.unsupportedDeclaration("Runtime-typed callbacks cannot be decoded as returned closures.")
        }
    }
}
