import ABIBridgeCore
import Foundation
import Darwin

/// A borrowed native value was accessed outside its synchronous callback.
public enum NativeSwiftBorrowError: Error, Sendable, Equatable {
    /// The callback providing this value has returned.
    case expiredBorrow
    /// Access attempted to leave the thread executing the callback.
    case wrongThread
}

final class SwiftValueBorrow {
    private let lock = NSLock()
    private let thread = pthread_self()
    private var address: UnsafeRawPointer?

    init(_ address: UnsafeRawPointer) { self.address = address }

    func withAddress<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result {
        lock.lock()
        guard let address else { lock.unlock(); throw NativeSwiftBorrowError.expiredBorrow }
        guard pthread_equal(thread, pthread_self()) != 0 else {
            lock.unlock(); throw NativeSwiftBorrowError.wrongThread
        }
        lock.unlock()
        return try body(address)
    }

    func expire() { lock.lock(); address = nil; lock.unlock() }
}

/// A runtime-only Swift value borrowed for one synchronous callback.
///
/// Its initialized storage belongs to the native caller. This handle never
/// copies or destroys that value. Saving the handle does not extend its borrow;
/// member invocation after return or from another thread throws. The value is
/// not Sendable and must satisfy the native declaration's isolation contract.
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
