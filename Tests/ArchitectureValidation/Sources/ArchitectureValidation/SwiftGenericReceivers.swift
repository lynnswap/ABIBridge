import ABIBridge
import Foundation
import SwiftValueFixtures

@MainActor func validateSwiftGenericReceivers() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    weak var observed: GenericMemberReceiver<GenericReceiverText>?
    var retained: NativeBoundSwiftMethod<(String) -> String>?
    do {
        let receiver = GenericMemberReceiver(GenericReceiverText(String(repeating: "owned", count: 100)))
        observed = receiver
        let object = runtime.object(receiver)
        retained = try await object.method(named: "concrete(_:)", as: ((String) -> String).self)
        let complete = try await object.method(named: "concrete(Swift.String) -> Swift.String", as: ((String) -> String).self)
        let getter = try await object.getter(named: "valueText", as: (() -> String).self)
        try check(unsafe retained!.unsafeInvoke("prefix:") == receiver.concrete("prefix:"),
                  "Generic Swift receiver uses its metadata and witness context")
        try check(unsafe complete.unsafeInvoke("") == receiver.concrete(""),
                  "Generic Swift complete concrete declaration")
        try check(unsafe getter.unsafeInvoke() == receiver.valueText, "Generic Swift concrete getter")
    }
    let inherited = InheritedGenericMemberReceiver(GenericReceiverNumber(42))
    let method = try await runtime.object(inherited).method(named: "concrete(_:)", as: ((String) -> String).self)
    try check(unsafe method.unsafeInvoke("") == inherited.concrete(""),
              "Generic Swift superclass implementation")
    let constrained = try await runtime.object(inherited).method(named: "specialized(_:)", as: ((String) -> String).self)
    let constrainedGetter = try await runtime.object(inherited).getter(named: "specializedText", as: (() -> String).self)
    try check(unsafe constrained.unsafeInvoke("prefix:") == inherited.specialized("prefix:"),
              "Swift same-type constrained superclass member")
    try check(unsafe constrainedGetter.unsafeInvoke() == inherited.specializedText,
              "Swift same-type constrained getter")
    let witness = try await runtime.object(inherited).method(named: "witnessText()", as: (() -> String).self)
    try check(unsafe witness.unsafeInvoke() == inherited.witnessText(),
              "Constrained superclass member receives its additional protocol witness")
    await runtime.removeCachedResults()
    try check(observed != nil, "Generic Swift receiver retained after cache removal")
    try check(unsafe retained!.unsafeInvoke("") == String(repeating: "owned", count: 100),
              "Generic Swift specialized metadata stays distinct")
    retained = nil
    try check(observed == nil, "Generic Swift receiver final release")
    return checks
}

@MainActor func validateSwiftGenericBindings() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let string = try await runtime.swiftType(named: "Swift.String")
    let boxType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingBox",
        genericArguments: [.type(string)])
    let initialize = try await boxType.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
    let box = try unsafe initialize.unsafeInvoke("initial")
    let set = try await runtime.object(box).setter(named: "value", as: String.self)
    let get = try await boxType.getter(named: "value", as: (() -> String).self)
    try unsafe set.unsafeInvoke("updated")
    try check(unsafe get.unsafeInvoke(on: box) == "updated", "Generic class construction, AnyObject result, setter, and getter")
    let compare = try await runtime.object(box).method(named: "compare(_:)",
        as: ((Int64) -> (String, Int64, Bool)).self, genericArguments: [.type(Int64.self)])
    try check(unsafe compare.unsafeInvoke(42) == ("updated", 42, true), "Member parameters combine with retained enclosing types and witnesses")

    let valueType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingValue",
        genericArguments: [.type(String.self)])
    let createValue = try await valueType.initializer(named: "init(_:)", as: ((String) -> BindingValue<String>).self)
    var value = try unsafe createValue.unsafeInvoke("value")
    let replace = try await valueType.method(named: "replace(_:)", as: ((String) -> Void).self, mutating: true)
    try unsafe replace.unsafeInvoke(on: &value, "replaced")
    let take = try await valueType.method(named: "take()", as: (() -> String).self, consuming: true)
    try check(unsafe take.unsafeInvoke(on: value) == "replaced" && value.value == "replaced",
        "Generic value initialization, mutation, and consuming receiver preserve ownership")

    let select = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingSelect<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
        as: ((String, [String]) -> String).self, genericArguments: [.type(String.self), .type([String].self)])
    try check(unsafe select.unsafeInvoke("fallback", ["selected"]) == bindingSelect("fallback", ["selected"]),
        "Associated types and same-type constraints match the compiler call")
    let pack = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPack<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
        as: ((Int64, String) -> (Int64, String)).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    try check(unsafe pack.unsafeInvoke(41, "pack") == bindingPack(Int64(41), "pack"), "Pack metadata and witnesses preserve mixed results")
    let empty = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPack<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
        as: (() -> Void).self, genericArguments: [.pack([])])
    try unsafe empty.unsafeInvoke()
    checks.append("Empty constrained pack preserves its shape")
    let packCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPackCallback<each A>((repeat A) -> (repeat A), repeat A) -> (repeat A)",
        as: ((NativeSwiftClosure<(Int64, String) -> (Int64, String)>, Int64, String) -> (Int64, String)).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    let packBody = try NativeSwiftClosure<(Int64, String) -> (Int64, String)> { ($0 + 1, $1 + "!") }
    try check(unsafe packCallback.unsafeInvoke(packBody, 41, "pack") == (42, "pack!"),
        "Pack callback authenticates its generic entry and reabstracts both directions")
    let packSource = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPackSource<each A where A: Swift.Equatable>(SwiftValueFixtures.BindingPackSource<Pack{repeat A}>, repeat A) -> Swift.Int64",
        as: ((BindingPackSource<Int64, String>, Int64, String) -> Int64).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    try check(unsafe packSource.unsafeInvoke(BindingPackSource(), 41, "pack") == 2,
        "Generic class arguments fulfill pack metadata and conformance requirements")

    let transform = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingTransform<A, B>([A], (A) throws -> B) throws -> [B]",
        as: (([Int64], NativeSwiftClosure<(Int64) throws -> String>) throws -> [String]).self,
        genericArguments: [.type(Int64.self), .type(String.self)])
    let body = try NativeSwiftClosure<(Int64) throws -> String> { "value: \($0)" }
    try check(unsafe transform.unsafeInvoke([1, 2], body) == ["value: 1", "value: 2"],
        "Generic collection callback preserves rethrows and managed results")
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.bindingClosure<A>(A) -> (A) -> A",
        as: ((String) -> NativeSwiftClosure<(String) -> String>).self, genericArguments: [.type(String.self)])
    let closure = try unsafe make.unsafeInvoke(String(repeating: "retained", count: 100))
    await runtime.removeCachedResults()
    try check(unsafe closure.unsafeInvoke("ignored") == String(repeating: "retained", count: 100),
        "Returned generic closure retains its capture and authenticates after cache removal")

    let never = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingError<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
        as: ((Never.Type) -> Int64).self, genericArguments: [.type(Never.self)])
    try check(unsafe never.unsafeInvoke(Never.self) == 44, "Never substitution preserves the generic throwing convention")
    let erased = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingError<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
        as: (((any Error).Type) throws -> Int64).self, genericArguments: [.type((any Error).self)])
    try check(unsafe erased.unsafeInvoke((any Error).self) == 44, "Error existential binding supplies its self-conformance witness")
    let neverCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
        as: ((NativeSwiftClosure<() -> Int64>) -> Int64).self, genericArguments: [.type(Never.self)])
    try check(unsafe neverCallback.unsafeInvoke(NativeSwiftClosure<() -> Int64> { 45 }) == 45,
        "Never-bound callback authenticates with the formal error convention")
    let erasedCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
        as: ((NativeSwiftClosure<() throws -> Int64>) throws -> Int64).self, genericArguments: [.type((any Error).self)])
    do {
        _ = try unsafe erasedCallback.unsafeInvoke(NativeSwiftClosure<() throws -> Int64> { throw SmallError(46) })
        throw ArchitectureValidationFailure(description: "Missing existential-bound callback error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 46 }, "Existential-bound callback transfers the original error")
    }

    let asyncValue = try await runtime.swiftFunction(named: "SwiftValueFixtures.bindingAsync<A>(A) async -> A",
        as: (nonisolated(nonsending) (String) async -> String).self, genericArguments: [.type(String.self)])
    try check(unsafe await asyncValue.unsafeInvoke("async") == "async", "Generic async result preserves caller isolation")
    let asyncCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncCallback<A, B where B: Swift.Error>(A, nonisolated(nonsending) (A) async throws(B) -> A) async throws(B) -> A",
        as: (nonisolated(nonsending) (String, NativeSwiftClosure<nonisolated(nonsending) (String) async throws(SmallError) -> String>) async throws(SmallError) -> String).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    for shouldThrow in [false, true] {
        let operation: (nonisolated(nonsending) @Sendable (String) async throws(SmallError) -> String) = {
            value async throws(SmallError) in
            await Task.yield()
            if shouldThrow { throw SmallError(47) }
            return value + "!"
        }
        let callback = try NativeSwiftClosure<nonisolated(nonsending) (String) async throws(SmallError) -> String>(operation)
        do {
            let result = try unsafe await asyncCallback.unsafeInvoke("callback", callback)
            try check(!shouldThrow && result == "callback!", "Generic async callback authenticates across suspension")
        } catch let error as NativeSwiftError {
            try check(shouldThrow && error.withUnderlyingError { ($0 as? SmallError)?.code == 47 },
                "Generic async callback preserves its typed failure")
        }
    }
    let makeAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncClosure<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
        as: ((String) -> NativeSwiftClosure<nonisolated(nonsending) @Sendable (String) async -> String>).self,
        genericArguments: [.type(String.self)])
    let asyncClosure = try unsafe makeAsync.unsafeInvoke("captured")
    try check(unsafe await asyncClosure.unsafeInvoke("ignored") == "captured", "Returned async generic closure authenticates and retains its context")

    let mutate = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMutate<A, B where B: Swift.Error>(inout A, __owned A, B, Swift.Bool) throws(B) -> ()",
        as: ((NativeSwiftInout<String>, NativeSwiftConsuming<String>, SmallError, Bool) throws(SmallError) -> Void).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    let storage = NativeSwiftInout("before")
    do {
        try unsafe mutate.unsafeInvoke(storage, NativeSwiftConsuming("after"), SmallError(48), true)
        throw ArchitectureValidationFailure(description: "Missing generic mutation error")
    } catch let error as NativeSwiftError {
        try check(storage.value == "after" && error.withUnderlyingError { ($0 as? SmallError)?.code == 48 },
            "Generic consuming input and inout writeback survive typed errors")
    }
    let getter = BindingGetter("delayed", SmallError(49), false)
    let checked = try await runtime.object(getter).getter(named: "checkedNumber",
        as: (() throws(SmallError) -> Int64).self, declaredAs: "() throws(B) -> Swift.Int64")
    let fixed = try await runtime.object(getter).getter(named: "fixedNumber",
        as: (() throws(SmallError) -> Int64).self, declaredAs: "() throws(SwiftValueFixtures.SmallError) -> Swift.Int64")
    try check(unsafe checked.unsafeInvoke() == 42 && fixed.unsafeInvoke() == 43,
        "Generic and fixed getter errors keep distinct conventions with equal concrete types")
    let delayed = try await runtime.object(getter).getter(named: "delayed",
        as: (nonisolated(nonsending) () async throws(SmallError) -> String).self, declaredAs: "() async throws(B) -> A")
    try check(unsafe await delayed.unsafeInvoke() == "delayed", "Generic async getter returns its dependent value")
    getter.shouldThrow = true
    do {
        _ = try unsafe checked.unsafeInvoke()
        throw ArchitectureValidationFailure(description: "Missing generic getter error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 49 }, "Generic getter transfers typed error storage")
    }
    do {
        _ = try unsafe fixed.unsafeInvoke()
        throw ArchitectureValidationFailure(description: "Missing fixed getter error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 43 }, "Fixed getter preserves its direct error convention")
    }

    let metatypes = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMetatypes<A>(A.Type, Swift.Int64.Type?, A) -> (A.Type, Swift.Int64.Type?, A)",
        as: ((String.Type, Int64.Type?, String) -> (String.Type, Int64.Type?, String)).self,
        genericArguments: [.type(String.self)])
    let nonnil = try unsafe metatypes.unsafeInvoke(String.self, nil, "metadata")
    let nilResult = try unsafe metatypes.unsafeInvoke(String.self, Int64.self, "metadata")
    try check(nonnil.0 == String.self && nonnil.1 == Int64.self && nonnil.2 == "metadata"
        && nilResult.1 == nil, "Generic thick and optional thin metatypes preserve physical result components")
    let metatypeCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMetatypeCallback<A>(A.Type, (A.Type) -> A.Type) -> A.Type",
        as: ((String.Type, NativeSwiftClosure<(String.Type) -> String.Type>) -> String.Type).self,
        genericArguments: [.type(String.self)])
    try check(unsafe metatypeCallback.unsafeInvoke(String.self, NativeSwiftClosure<(String.Type) -> String.Type> { $0 }) == String.self,
        "Thin concrete metatype callback restores the generic metadata word")
    let existential = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingExistentialMetatype<A>(Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A) -> (Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A)",
        as: ((any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)
            -> (any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)).self,
        genericArguments: [.type(String.self)])
    let types = try unsafe existential.unsafeInvoke(Int64.self, (any CustomStringConvertible).self, "existential")
    try check(ObjectIdentifier(types.0) == ObjectIdentifier(Int64.self)
        && types.1 == (any CustomStringConvertible).self && types.2 == "existential",
        "Existential and protocol metatypes preserve witnesses and singleton identity")
    return checks
}
