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
    private let thread: pthread_t?
    private let allowsSuspension: Bool
    private let allowsMutation: Bool
    private var address: UnsafeRawPointer?
    private var storageOwner: NativeValueStorage?
    private var readers = 0
    private var exclusive = false

    init(_ address: UnsafeRawPointer, retaining owner: NativeValueStorage? = nil,
         allowsSuspension: Bool = false, allowsMutation: Bool = false) {
        self.address = address
        self.allowsSuspension = allowsSuspension
        self.allowsMutation = allowsMutation
        thread = allowsSuspension ? nil : pthread_self()
        storageOwner = owner
    }

    func withAddress<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result {
        let access = try access(asynchronous: false, codeLifetime: nil)
        return try withExtendedLifetime(access) { try body(UnsafeRawPointer(access.address)) }
    }

    func access(asynchronous: Bool, type: NativeSwiftType,
                convention: SwiftArgumentConvention = .borrowing) throws -> NativeValueStorage {
        try access(asynchronous: asynchronous, codeLifetime: type.codeLifetime, convention: convention)
    }

    func access(asynchronous: Bool, codeLifetime: SwiftValueCodeLifetime?,
                convention: SwiftArgumentConvention = .borrowing) throws -> NativeValueStorage {
        lock.lock()
        guard let address else { lock.unlock(); throw NativeSwiftBorrowError.expiredBorrow }
        if let thread, pthread_equal(thread, pthread_self()) == 0 {
            lock.unlock(); throw NativeSwiftBorrowError.wrongThread
        }
        let owner = storageOwner
        guard !asynchronous || owner != nil || allowsSuspension else {
            lock.unlock(); throw NativeSwiftBorrowError.synchronousBorrow
        }
        let writes = convention != .borrowing
        guard convention != .consuming, !writes || allowsMutation,
              !exclusive, !writes || readers == 0 else {
            lock.unlock(); throw NativeSwiftValueError.valueInUse
        }
        if writes { exclusive = true } else { readers += 1 }
        lock.unlock()
        let access = SwiftBorrowAccess(owner: owner) {
            self.lock.lock()
            if writes { self.exclusive = false } else { self.readers -= 1 }
            self.lock.unlock()
        }
        return NativeValueStorage(borrowing: UnsafeMutableRawPointer(mutating: address), owner: access,
            retainingResourcesOf: owner, codeLifetime: codeLifetime)
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

private final class SwiftBorrowAccess {
    let owner: NativeValueStorage?
    private let finish: () -> Void
    init(owner: NativeValueStorage?, finish: @escaping () -> Void) { self.owner = owner; self.finish = finish }
    deinit { finish() }
}

/// A scoped view of a runtime-only Swift value.
///
/// The storage belongs to a native caller or NativeSwiftValue. Saving this view
/// does not extend its scope; new access after return throws. Synchronous scopes
/// also reject access from another thread. An owned-value borrow can keep a
/// started async member's read access until completion. A native async callback
/// may await operations on its borrow, and must finish those operations before
/// returning. A synchronous native callback cannot extend its storage across
/// suspension and rejects async member entry with synchronousBorrow.
/// A native inout callback parameter grants mutable access through ordinary
/// mutating members and inout arguments. Other borrows remain read-only;
/// overlapping mutations and consuming borrowed storage are rejected.
/// The value is not Sendable and retains the declaration's isolation contract.
public final class NativeSwiftBorrowedValue {
    /// The actual native type and its retained implementation image.
    public let type: NativeSwiftType
    let borrow: SwiftValueBorrow

    init(type: NativeSwiftType, borrow: SwiftValueBorrow) {
        self.type = type
        self.borrow = borrow
    }

    /// Copies the native value into an independent owner while the borrow is active.
    /// The native type must be Copyable and Escapable.
    public func copy() throws -> NativeSwiftValue {
        try borrow.withAddress { try NativeSwiftValue.copy(from: $0, type: type) }
    }
}
