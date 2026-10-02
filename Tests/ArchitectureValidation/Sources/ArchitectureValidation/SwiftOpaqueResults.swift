import ABIBridge
import SwiftValueFixtures
import SwiftOpaqueExtensions
import Foundation

private struct OpaqueWordResult: ABIBridgeValue {
    static let abiType = NativeType.int64
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.storage }
    func read() throws -> Int64 { try unsafe storage.read(as: Int64.self) }
}

@MainActor func validateSwiftOpaqueResults() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaque(_:_:)",
        as: ((ErrorToken, Int64) -> NativeSwiftValue).self)
    let counts = ArgumentCounts()
    weak var observed: ErrorToken?
    var stored: NativeSwiftValue?
    do {
        let token = ErrorToken { counts.destroyed() }
        observed = token
        stored = try unsafe make.unsafeInvoke(token, 42)
    }
    try stored!.withCopy {
        try check(($0 as? any ExistentialValue)?.number == 42 && ($0 as? any ExistentialLabel)?.label.count == 600,
                  "Opaque metadata supports an aligned hidden managed value and existing protocol witnesses")
    }
    let underlyingType = try await runtime.swiftType(named: stored!.type.name, in: stored!.type.image)
    try check(underlyingType.image.identity == stored!.type.image.identity,
              "Opaque values expose the underlying declaration name for type lookup")
    var copy = stored
    stored = nil
    await runtime.removeCachedResults()
    try copy!.withCopy { try check(($0 as? any ExistentialValue)?.number == 42 && observed != nil,
                                   "Copied opaque handle remains valid after resolver cache removal") }
    copy = nil
    try check(observed == nil && counts.destructions == 1, "Final opaque release destroys its hidden payload exactly once")

    let integer = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueInteger(_:)",
        as: ((Int64) -> NativeSwiftValue).self)
    try unsafe integer.unsafeInvoke(42).withCopy {
        try check($0 as? Int64 == 42, "Scalar opaque values use the native indirect result convention")
    }
    let owned = try unsafe integer.unsafeInvoke(42)
    let copied = try owned.copy()
    try check(try copied.take(as: Int64.self) == 42 && copied.isConsumed && !owned.isConsumed,
              "A native copy can be consumed independently of the original owner")
    var escapedBorrow: NativeSwiftBorrowedValue?
    let borrowedCopy = try owned.withBorrowedValue { borrow in
        escapedBorrow = borrow
        return try borrow.copy()
    }
    do {
        _ = try escapedBorrow!.copy()
        throw ArchitectureValidationFailure(description: "Expected an expired owned-value borrow")
    } catch NativeSwiftBorrowError.expiredBorrow {
        checks.append("Owned-value borrows expire when their synchronous scope returns")
    }
    try check(try borrowedCopy.take(as: Int64.self) == 42 && owned.take(as: Int64.self) == 42,
              "A copied borrow owns an independent native value")
    do {
        _ = try owned.copy()
        throw ArchitectureValidationFailure(description: "Expected a consumed runtime value")
    } catch NativeSwiftValueError.consumedValue {
        checks.append("A consumed owner reports its ownership state")
    }

    let makeTicket = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueTicket(_:)",
        as: ((ErrorToken) -> NativeSwiftValue).self)
    let ticketCounts = ArgumentCounts()
    weak var ticketToken: ErrorToken?
    let ownedTicket: NativeSwiftValue
    do {
        let token = ErrorToken { ticketCounts.destroyed() }
        ticketToken = token
        ownedTicket = try unsafe makeTicket.unsafeInvoke(token)
    }
    do {
        _ = try ownedTicket.copy()
        throw ArchitectureValidationFailure(description: "Expected a noncopyable runtime value")
    } catch NativeSwiftValueError.noncopyableType {
        checks.append("Noncopyable native values reject copying without consuming their payload")
    }
    do {
        let ticket = try ownedTicket.take(as: OpaqueTicket.self)
        try check(ticket.number == 42 && ownedTicket.isConsumed && ticketToken != nil,
                  "Typed transfer supports an owned noncopyable native value")
    }
    try check(ticketToken == nil && ticketCounts.destructions == 1,
              "A transferred noncopyable payload is destroyed exactly once")

    let memberCounts = ArgumentCounts()
    let memberValue = try unsafe makeTicket.unsafeInvoke(ErrorToken { memberCounts.destroyed() })
    let selfABI = try NativeType.opaque(named: memberValue.type.name)
    let readMember = try await memberValue.type.method(named: "read()", as: (() -> Int64).self, receiverABI: selfABI)
    let addMember = try await memberValue.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
        receiverABI: selfABI, mutating: true)
    let adaptedRead = try await memberValue.type.method(named: "read() -> Swift.Int64",
        as: (() -> OpaqueWordResult).self, receiverABI: selfABI)
    let retainedReadResult = try unsafe adaptedRead.unsafeInvoke(on: memberValue)
    let takeMember = try await memberValue.type.method(named: "takeNumber() async -> Swift.Int64",
        as: (nonisolated(nonsending) () async -> OpaqueWordResult).self,
        receiverABI: selfABI, consuming: true)
    try check(try unsafe readMember.unsafeInvoke(on: memberValue) == 42,
              "An owned noncopyable value uses ordinary member invocation")
    try unsafe addMember.unsafeInvoke(on: memberValue, 5)
    try check(try unsafe readMember.unsafeInvoke(on: memberValue) == 47,
              "A mutating member updates the runtime owner's storage directly")
    var memberBorrow: NativeSwiftBorrowedValue?
    try memberValue.withBorrowedValue { borrowed in
        memberBorrow = borrowed
        try check(try unsafe readMember.unsafeInvoke(on: borrowed) == 47,
                  "The same member handle accepts a scoped borrowed value")
        do {
            try unsafe addMember.unsafeInvoke(on: memberValue, 1)
            throw ArchitectureValidationFailure(description: "Expected conflicting runtime access")
        } catch NativeSwiftValueError.valueInUse {
            checks.append("An active borrow prevents alias mutation")
        }
    }
    do {
        _ = try unsafe readMember.unsafeInvoke(on: memberBorrow!)
        throw ArchitectureValidationFailure(description: "Expected an expired member receiver")
    } catch NativeSwiftBorrowError.expiredBorrow {
        checks.append("Ordinary member calls reject an expired borrowed receiver")
    }
    if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
        let readAfter = try await memberValue.type.method(named: "readAfter(_:)",
            as: (nonisolated(nonsending) (AsyncValueGate) async -> Int64).self, receiverABI: selfABI)
        let gate = AsyncValueGate()
        let operation = try memberValue.withBorrowedValue { borrowed in
            Task.immediate { @MainActor in try unsafe await readAfter.unsafeInvoke(on: borrowed, gate) }
        }
        await gate.waitUntilSuspended()
        do {
            try unsafe addMember.unsafeInvoke(on: memberValue, 1)
            throw ArchitectureValidationFailure(description: "Suspended member lost its borrowed self access")
        } catch NativeSwiftValueError.valueInUse {
            checks.append("A started async member retains borrowed self access after scope exit")
        }
        await gate.open()
        let number = try await operation.value
        try check(number == 47, "Retained borrowed self remains valid until native async completion")
    }
    let consumed = try unsafe await takeMember.unsafeInvoke(on: memberValue)
    try withExtendedLifetime((retainedReadResult, consumed)) {
        try check(try consumed.read() == 47 && memberValue.isConsumed,
                  "An async consuming member transfers the owned noncopyable value")
        try check(memberCounts.destructions == 1,
                  "Async consuming self destroys its managed payload once")
        try check(try retainedReadResult.read() == 42,
                  "Result adapters retain native resources without extending receiver access")
    }

    let empty = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueEmpty()",
        as: (() -> NativeSwiftValue).self)
    try unsafe empty.unsafeInvoke().withCopy { try check($0 is Void, "Empty opaque values preserve their runtime type") }

    let throwing = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueThrowing(_:_:)",
        as: ((ErrorToken, Bool) throws(SmallError) -> NativeSwiftValue).self)
    do {
        _ = try unsafe throwing.unsafeInvoke(ErrorToken(), true)
        throw ArchitectureValidationFailure(description: "Expected opaque failure")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? SmallError)?.code == 42,
            "Throwing opaque calls keep error storage separate from uninitialized result storage") }
    }

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.OpaqueOwner")
    let owner = OpaqueOwner(ErrorToken())
    let getter = try await type.getter(named: "summary", as: (() -> NativeSwiftValue).self)
    try unsafe getter.unsafeInvoke(on: owner).withCopy {
        try check(($0 as? any ExistentialValue)?.number == 42, "Opaque getter resolves the property's descriptor")
    }

    let async = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueAsync(_:_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken, Bool) async throws(SmallError) -> NativeSwiftValue).self)
    for cancel in [false, true] {
        let gate = AsyncValueGate()
        let task = Task {
            let result = try unsafe await async.unsafeInvoke(gate, ErrorToken(), false)
            return try result.withCopy { ($0 as? any ExistentialValue)?.number ?? -100 }
        }
        await gate.waitUntilSuspended()
        if cancel { task.cancel() }
        await gate.open()
        do { try check(try await task.value == 42 && !cancel, "Async opaque result survives native suspension") }
        catch let error as NativeSwiftError {
            try error.withUnderlyingError { try check(cancel && ($0 as? SmallError)?.code == -1,
                "Cancelled opaque call preserves its native error without adopting a result") }
        }
    }
    for (name, expected) in [("makeOpaqueClassAny", 41), ("makeOpaqueClassProtocol", 42),
                              ("makeOpaqueSuperclass", 43), ("makeOpaqueUnconstrainedClass", 44)] {
        let call = try await runtime.swiftFunction(named: "SwiftValueFixtures." + name + "(_:)",
            as: ((ErrorToken) -> NativeSwiftValue).self)
        try unsafe call.unsafeInvoke(ErrorToken()).withCopy {
            try check(($0 as? OpaqueBase)?.number == Int64(expected), name + " follows its declared class constraint")
        }
    }
    let objc = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueObjC(_:)",
        as: ((ErrorToken) -> NativeSwiftValue).self)
    try unsafe objc.unsafeInvoke(ErrorToken()).withCopy { try check($0 is NSObject, "ObjC protocol constraint uses a direct object result") }
    let extensionMethod = try await type.method(named: "extensionOpaque(_:)", as: ((Int64) -> NativeSwiftValue).self)
    let extensionGetter = try await type.getter(named: "extensionSummary", as: (() -> NativeSwiftValue).self)
    let extensionObject = try await type.method(named: "extensionClassOpaque()", as: (() -> NativeSwiftValue).self)
    try unsafe extensionMethod.unsafeInvoke(on: owner, 47).withCopy {
        try check(($0 as? any ExistentialValue)?.number == 47, "Extension method locates its matched opaque descriptor")
    }
    try unsafe extensionGetter.unsafeInvoke(on: owner).withCopy {
        try check(($0 as? any ExistentialValue)?.number == 48, "Extension getter retains its declaring module qualifier")
    }
    try unsafe extensionObject.unsafeInvoke(on: owner).withCopy {
        try check(($0 as? any ExistentialObjectValue)?.number == 49, "Imported class protocol descriptor is authenticated through its indirect reference")
    }
    let directAsync = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueClassAsync(_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken) async -> NativeSwiftValue).self)
    let directGate = AsyncValueGate()
    let directTask = Task {
        let value = try unsafe await directAsync.unsafeInvoke(directGate, ErrorToken())
        return try value.withCopy { ($0 as? any ExistentialObjectValue)?.number }
    }
    await directGate.waitUntilSuspended(); await directGate.open()
    try check(try await directTask.value == 46, "Async class-constrained opaque result resumes with a direct object pointer")
    return checks
}
