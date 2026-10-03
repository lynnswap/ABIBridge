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
    let genericOpaque = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRuntimeOpaque<A>(A) -> some",
        as: ((String) -> NativeSwiftValue).self, genericArguments: [.type(String.self)])
    let genericValue = try unsafe genericOpaque.unsafeInvoke("generic")
    try check(try genericValue.withCopy { $0 as? String } == "generic", "Opaque descriptors bind function generic metadata")
    let pair = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeRuntimeOpaquePair<A, B>(A, B) -> (some, some)",
        as: ((String, Int) -> (NativeSwiftValue, NativeSwiftValue)).self,
        genericArguments: [.type(String.self), .type(Int.self)])
    let pairValue = try unsafe pair.unsafeInvoke("pair", 42)
    try check(try pairValue.0.withCopy { $0 as? String } == "pair" && pairValue.1.withCopy { $0 as? Int } == 42,
        "Tuple results resolve independent opaque type indexes")
    let nested = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeRuntimeOpaqueClosure<A>(A) -> () -> some",
        as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self, genericArguments: [.type(String.self)])
    let nestedValue = try unsafe nested.unsafeInvoke("nested")
    try check(try unsafe nestedValue.unsafeInvoke().withCopy { $0 as? String } == "nested",
        "Returned closures preserve generic opaque result metadata and authentication")
    let genericOwner = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeOpaqueOwner", genericArguments: [.type(String.self)])
    let genericInitializer = try await genericOwner.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
    let genericInstance = try unsafe genericInitializer.unsafeInvoke("owner")
    let genericGetter = try await genericOwner.getter(named: "opaque", as: (() -> NativeSwiftValue).self)
    let getterValue = try unsafe genericGetter.unsafeInvoke(on: genericInstance)
    try check(try getterValue.withCopy { $0 as? String } == "owner", "Opaque getters bind enclosing generic metadata")
    let genericMethod = try await genericOwner.method(named: "make(_:)", as: ((Int) -> NativeSwiftValue).self,
        genericArguments: [.type(Int.self)])
    let methodValue = try unsafe genericMethod.unsafeInvoke(on: genericInstance, 42)
    try check(try methodValue.withCopy { ($0 as? (String, Int))?.1 } == 42,
        "Opaque members combine enclosing and introduced type bindings")
    for name in ["makeOptionalOpaqueObject", "makeOptionalClassOpaqueObject"] {
        let call = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.\(name)(SwiftValueFixtures.ErrorToken, Swift.Bool) -> some?",
            as: ((ErrorToken, Bool) -> NativeSwiftValue).self)
        for present in [false, true] {
            let value = try unsafe call.unsafeInvoke(ErrorToken(), present)
            try check(try value.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil),
                name + " preserves the formal result convention with present=\(present)")
        }
    }
    let optionalClosure = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeOptionalOpaqueClosure(SwiftValueFixtures.ErrorToken) -> (Swift.Bool) -> some?",
        as: ((ErrorToken) -> NativeSwiftClosure<(Bool) -> NativeSwiftValue>).self)
    let optionalBody = try unsafe optionalClosure.unsafeInvoke(ErrorToken())
    for present in [false, true] {
        let value = try unsafe optionalBody.unsafeInvoke(present)
        try check(try value.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil),
            "Returned optional opaque closure authenticates its indirect result with present=\(present)")
    }
    let throwingOptionalFactory = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeOptionalOpaqueThrowingClosure(SwiftValueFixtures.ErrorToken) -> (Swift.Bool) throws(SwiftValueFixtures.SmallError) -> some?",
        as: ((ErrorToken) -> NativeSwiftClosure<(Bool) throws(SmallError) -> NativeSwiftValue>).self)
    let throwingOptional = try unsafe throwingOptionalFactory.unsafeInvoke(ErrorToken())
    do { _ = try unsafe throwingOptional.unsafeInvoke(false); throw ArchitectureValidationFailure(description: "Expected native opaque closure failure") }
    catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code } == 42,
            "Opaque closures retain typed error storage in the erased function convention")
    }
    let asyncOptionalFactory = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeOptionalOpaqueAsyncClosure(SwiftValueFixtures.ErrorToken) -> @Sendable (Swift.Bool) async -> some?",
        as: ((ErrorToken) -> NativeSwiftClosure<@Sendable @concurrent (Bool) async -> NativeSwiftValue>).self)
    let asyncOptional = try unsafe asyncOptionalFactory.unsafeInvoke(ErrorToken())
    for present in [false, true] {
        let value = try unsafe await asyncOptional.unsafeInvoke(present)
        try check(try value.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil),
            "Async opaque closure preserves indirect storage with present=\(present)")
    }
    let opaqueBox = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeInlineOpaqueBox(SwiftValueFixtures.ErrorToken) -> SwiftValueFixtures.InlineOpaqueBox<some>",
        as: ((ErrorToken) -> NativeSwiftValue).self)
    let boxedValue = try unsafe opaqueBox.unsafeInvoke(ErrorToken())
    try check(try boxedValue.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42",
        "A nominal inline opaque field preserves formal indirection")
    checks += try await validateRuntimeValueArguments()
    checks += try await validateRuntimeClassArguments()
    return checks
}

@MainActor private func validateRuntimeValueArguments() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueTicket(_:)",
        as: ((ErrorToken) -> NativeSwiftValue).self)
    let counts = ArgumentCounts()
    let original = try unsafe make.unsafeInvoke(ErrorToken { counts.destroyed() })
    let arguments: [NativeSwiftGenericArgument] = [.type(original.type)]
    let borrow = try await runtime.swiftFunction(named: "SwiftValueFixtures.borrowRuntimeValue<A where A: ~Swift.Copyable>(A) -> Swift.Int64",
        as: ((NativeSwiftValue) -> Int64).self, genericArguments: arguments)
    try check(try unsafe borrow.unsafeInvoke(original) == Int64(MemoryLayout<OpaqueTicket>.size),
              "Generic argument borrowing uses the noncopyable value's native storage")
    do {
        _ = try await runtime.swiftFunction(named: "SwiftValueFixtures.copyRuntimeValue<A>(A) -> A",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: arguments)
        throw ArchitectureValidationFailure(description: "A Copyable requirement accepted a noncopyable value")
    } catch ABIResolutionError.signatureMismatch {
        checks.append("Implicit Copyable requirements reject noncopyable generic substitutions")
    }
    let move = try await runtime.swiftFunction(named: "SwiftValueFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: arguments)
    let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(original))
    try check(original.isConsumed && !moved.isConsumed && counts.destructions == 0,
              "Generic native results own the transferred noncopyable value")
    let replace = try await runtime.swiftFunction(named: "SwiftValueFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
        as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>) -> Void).self,
        genericArguments: arguments)
    let buffer = NativeSwiftInout(moved)
    do {
        try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(moved))
        throw ArchitectureValidationFailure(description: "Conflicting argument access reached the native function")
    } catch NativeSwiftValueError.valueInUse {
        checks.append("Conflicting generic argument aliases fail without consuming the native value")
    }
    let replacement = try unsafe make.unsafeInvoke(ErrorToken { counts.destroyed() })
    try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(replacement))
    try check(!moved.isConsumed && replacement.isConsumed && counts.destructions == 1,
              "Runtime inout replaces and destroys the original native payload exactly once")
    if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
        let asynchronous = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.borrowRuntimeValueAsync<A where A: ~Swift.Copyable>(A, SwiftValueFixtures.AsyncValueGate) async -> Swift.Int64",
            as: (nonisolated(nonsending) (NativeSwiftBorrowedValue, AsyncValueGate) async -> Int64).self,
            genericArguments: arguments)
        let gate = AsyncValueGate()
        let operation = try moved.withBorrowedValue { borrowed in
            Task.immediate { @MainActor in try unsafe await asynchronous.unsafeInvoke(borrowed, gate) }
        }
        await gate.waitUntilSuspended()
        do {
            _ = try moved.take(as: OpaqueTicket.self)
            throw ArchitectureValidationFailure(description: "Suspended argument lost its borrowed access")
        } catch NativeSwiftValueError.valueInUse {
            checks.append("An async runtime argument preserves access after the view's scope expires")
        }
        await gate.open()
        try check(try await operation.value == Int64(MemoryLayout<OpaqueTicket>.size),
                  "An async borrowed generic argument completes using retained native storage")
    }
    let moveAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.moveRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A) async -> A",
        as: (nonisolated(nonsending) (NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self,
        genericArguments: arguments)
    let final = try unsafe await moveAsync.unsafeInvoke(NativeSwiftConsuming(moved))
    try check(moved.isConsumed && !final.isConsumed && counts.destructions == 1,
              "Async generic results preserve a noncopyable ownership transfer")
    let boxType = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeValueBox", genericArguments: arguments)
    let makeBox = try await boxType.initializer(named: "init(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
    let box = try unsafe makeBox.unsafeInvoke(NativeSwiftConsuming(final))
    try check(final.isConsumed && !box.isCopyable, "Generic initializers transfer noncopyable runtime inputs into owned results")
    do {
        _ = try box.copy()
        throw ArchitectureValidationFailure(description: "A generic noncopyable value allowed copying")
    } catch NativeSwiftValueError.noncopyableType {
        checks.append("Runtime Copyable constraints protect generic types whose value-witness flags omit noncopyability")
    }
    let takeBox = try await boxType.method(named: "takeValue()", as: (() -> NativeSwiftValue).self, consuming: true)
    do {
        _ = try await boxType.method(named: "copiedValue()", as: (() -> NativeSwiftValue).self)
        throw ArchitectureValidationFailure(description: "A noncopyable argument selected a Copyable-only member")
    } catch ABIResolutionError.declarationNotFound {
        checks.append("A member's Copyable requirement overrides nominal suppression")
    }
    let unboxed = try unsafe takeBox.unsafeInvoke(on: box)
    try check(box.isConsumed && !unboxed.isConsumed && counts.destructions == 1,
              "Ordinary generic members transfer runtime result ownership")
    let consume = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.consumeRuntimeValueAndThrow<A where A: ~Swift.Copyable>(__owned A) throws -> ()",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) throws -> Void).self, genericArguments: arguments)
    do {
        try unsafe consume.unsafeInvoke(NativeSwiftConsuming(unboxed))
        throw ArchitectureValidationFailure(description: "A native consuming failure was lost")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check($0 is SmallError && unboxed.isConsumed && counts.destructions == 2,
            "A native error consumes and destroys the runtime argument exactly once") }
    }
    let integer = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueInteger(_:)", as: ((Int64) -> NativeSwiftValue).self)
    let scalar = try unsafe integer.unsafeInvoke(42)
    let conditional = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeConditionalValueBox", genericArguments: [.type(scalar.type)])
    let makeConditional = try await conditional.initializer(named: "init(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
    let copyable = try unsafe makeConditional.unsafeInvoke(NativeSwiftConsuming(scalar))
    let copied = try copyable.copy()
    try check(copyable.isCopyable && (try copied.take(as: RuntimeConditionalValueBox<Int64>.self)).value == 42,
              "Conditional Copyable conformance permits a native generic value copy")
    let copyableBoxType = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeValueBox",
        genericArguments: [.type(Int64.self)])
    let makeCopyableBox = try await copyableBoxType.initializer(named: "init(_:)",
        as: ((NativeSwiftConsuming<Int64>) -> NativeSwiftValue).self)
    let copyableBox = try unsafe makeCopyableBox.unsafeInvoke(NativeSwiftConsuming(Int64(42)))
    let copyMember = try await copyableBoxType.method(named: "copiedValue()", as: (() -> Int64).self)
    try check(try unsafe copyMember.unsafeInvoke(on: copyableBox) == 42,
              "A Copyable-only member accepts a copyable argument on a noncopyable nominal owner")
    let ticket = try unsafe make.unsafeInvoke(ErrorToken {})
    let noncopyableType = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeConditionalValueBox", genericArguments: [.type(ticket.type)])
    let makeNoncopyable = try await noncopyableType.initializer(named: "init(_:)",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
    let noncopyable = try unsafe makeNoncopyable.unsafeInvoke(NativeSwiftConsuming(ticket))
    try check(!noncopyable.isCopyable, "Conditional Copyable conformance checks the actual noncopyable type argument")
    let metatype = try await runtime.swiftFunction(named: "SwiftValueFixtures.runtimeValueMetatype<A>(A) -> (Swift.Int64.Type, A)",
        as: ((String) -> NativeSwiftValue).self, genericArguments: [.type(String.self)])
    let metatypeResult = try unsafe metatype.unsafeInvoke("retained").take(as: (Int64.Type, String).self)
    try check(unsafeBitCast(metatypeResult.0, to: UInt.self) == unsafeBitCast(Int64.self, to: UInt.self) && metatypeResult.1 == "retained",
              "Runtime result storage restores elided singleton metatypes alongside managed generic fields")
    return checks
}

@MainActor private func validateRuntimeClassArguments() async throws -> [String] {
    let runtime = ABIRuntime()
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueClassAny(_:)",
        as: ((ErrorToken) -> NativeSwiftValue).self)
    let original = try unsafe make.unsafeInvoke(ErrorToken {})
    let copy = try await runtime.swiftFunction(named: "SwiftValueFixtures.copyRuntimeValue<A>(A) -> A",
        as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(OpaqueBase.self)])
    let copied = try unsafe copy.unsafeInvoke(original)
    let object = try copied.take(as: OpaqueBase.self)
    guard object.number == 41 else { throw ArchitectureValidationFailure(description: "Runtime subclass upcast lost its value") }
    let borrowedCopy = try await runtime.swiftFunction(named: "SwiftValueFixtures.copyRuntimeValue<A>(A) -> A",
        as: ((NativeSwiftBorrowedValue) -> NativeSwiftValue).self, genericArguments: [.type(AnyObject.self)])
    try original.withBorrowedValue { value in
        let copied = try unsafe borrowedCopy.unsafeInvoke(value)
        guard try copied.take(as: AnyObject.self) === object else {
            throw ArchitectureValidationFailure(description: "Runtime AnyObject upcast changed object identity")
        }
    }
    let replace = try await runtime.swiftFunction(named: "SwiftValueFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
        as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>) -> Void).self,
        genericArguments: [.type(OpaqueBase.self)])
    let replacement = try unsafe copy.unsafeInvoke(original)
    do {
        try unsafe replace.unsafeInvoke(NativeSwiftInout(original), NativeSwiftConsuming(replacement))
        throw ArchitectureValidationFailure(description: "Inout Base accepted storage owned as a derived type")
    } catch ABIInvocationError.incompatibleValue { }
    guard !original.isConsumed && !replacement.isConsumed else {
        throw ArchitectureValidationFailure(description: "Rejected inout upcast consumed a value")
    }
    let move = try await runtime.swiftFunction(named: "SwiftValueFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
        as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self,
        genericArguments: [.type(OpaqueBase.self)], declaredAs: "<A where A: ~Swift.Copyable>(__owned A) -> A")
    let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(original))
    guard original.isConsumed, try moved.take(as: OpaqueBase.self) === object else {
        throw ArchitectureValidationFailure(description: "Consuming a runtime subclass lost ownership or identity")
    }
    return ["Runtime class arguments preserve subclass and AnyObject upcasts",
            "Inout runtime classes require the declared storage type before replacement",
            "Consuming a runtime subclass transfers the same object to its base type"]
}
