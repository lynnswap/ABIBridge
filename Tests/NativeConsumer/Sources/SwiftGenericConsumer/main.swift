import ABIBridge
import Darwin
import Foundation

private enum GenericConsumerFailure: Error { case load(String), initialize(Int32) }

@MainActor
func exerciseGenericBindings(_ adapterPath: String) async throws {
    guard let original = dlopen(adapterPath, RTLD_NOW | RTLD_LOCAL) else {
        throw GenericConsumerFailure.load(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericTypeClass",
                                         genericArguments: [.type(String.self)])
    let initialize = try await type.initializer(named: "init(_:)", as: ((String) -> AnyObject).self,
        declaredAs: "<A where A: Swift.Equatable> (A) -> ManagedSwiftFixtures.GenericTypeClass<A>")
    let object = try unsafe initialize.unsafeInvoke("first")
    let set = try await runtime.object(object).setter(named: "value", as: String.self, declaredAs: "<A where A: Swift.Equatable> (A) -> ()")
    try unsafe set.unsafeInvoke("updated")
    let get = try await type.getter(named: "value", as: (() -> String).self)
    let updated = try unsafe get.unsafeInvoke(on: object)
    precondition(updated == "updated")
    let compare = try await runtime.object(object).method(named: "compare(_:)",
        as: ((Int64) -> (String, Int64, Bool)).self, genericArguments: [.type(Int64.self)],
        declaredAs: "<A, A1 where A: Swift.Equatable, A1: Swift.Equatable> (A1) -> (A, A1, Swift.Bool)")
    let comparison = try unsafe compare.unsafeInvoke(42)
    precondition(comparison == ("updated", 42, true))

    let closureType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericClosureOwner", genericArguments: [.type(String.self)])
    let makeClosureOwner = try await closureType.initializer(named: "init(_:)", as: ((NativeSwiftClosure<() -> String>) -> AnyObject).self)
    let closureOwner = try unsafe makeClosureOwner.unsafeInvoke(NativeSwiftClosure<() -> String> { "initialized" })
    let invokeStored = try await runtime.object(closureOwner).method(named: "run()", as: (() -> String).self)
    let initialized = try unsafe invokeStored.unsafeInvoke()
    precondition(initialized == "initialized")
    let setClosure = try await runtime.object(closureOwner).setter(named: "body", as: NativeSwiftClosure<() -> String>.self)
    try unsafe setClosure.unsafeInvoke(NativeSwiftClosure<() -> String> { "replaced" })
    let replaced = try unsafe invokeStored.unsafeInvoke()
    precondition(replaced == "replaced")

    let argument = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericSourceValue")
    _ = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericSourceBox", genericArguments: [.type(argument)])
    let pack = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.constrainedPackGeneric<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
        as: ((Int64, String) -> (Int64, String)).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])],
        declaredAs: "<each A where A: Swift.Equatable> (repeat A) -> (repeat A)")
    let packed = try unsafe pack.unsafeInvoke(43, "pack")
    precondition(packed == (43, "pack"))
    let transform = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.transformGeneric<A, B>([A], (A) throws -> B) throws -> [B]",
        as: (([Int64], NativeSwiftBorrowing<NativeSwiftClosure<(Int64) throws -> String>>) throws -> [String]).self,
        genericArguments: [.type(Int64.self), .type(String.self)])
    let callback = try NativeSwiftClosure<(Int64) throws -> String> { "value: \($0)" }
    let transformed = try unsafe transform.unsafeInvoke([1, 2], .init(callback))
    precondition(transformed == ["value: 1", "value: 2"])
    let select = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.selectGeneric<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
        as: ((String, [String]) -> String).self, genericArguments: [.type(String.self), .type([String].self)])
    let selected = try unsafe select.unsafeInvoke("fallback", ["element"])
    precondition(selected == "element")
    let suspended = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.suspendedGeneric<A>(A) async -> A",
        as: (nonisolated(nonsending) (String) async -> String).self, genericArguments: [.type(String.self)])
    let resumed = try unsafe await suspended.unsafeInvoke("resumed")
    precondition(resumed == "resumed")

    let getterType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericEffectfulGetter",
        genericArguments: [.type(String.self), .type(GenericConsumerFailure.self)])
    let makeGetter = try await getterType.initializer(named: "init(_:_:_:)",
        as: ((String, GenericConsumerFailure, Bool) -> AnyObject).self)
    let getterObject = try unsafe makeGetter.unsafeInvoke("checked", .initialize(44), false)
    let checked = try await getterType.getter(named: "checked",
        as: (() throws(GenericConsumerFailure) -> String).self, declaredAs: "() throws(B) -> A")
    let checkedValue = try unsafe checked.unsafeInvoke(on: getterObject)
    precondition(checkedValue == "checked")
    let delayed = try await runtime.object(getterObject).getter(named: "delayedChecked",
        as: (nonisolated(nonsending) () async throws(GenericConsumerFailure) -> String).self, declaredAs: "() async throws(B) -> A")
    let delayedValue = try unsafe await delayed.unsafeInvoke()
    precondition(delayedValue == "checked")
    let shouldThrow = try await getterType.setter(named: "shouldThrow", as: Bool.self)
    try unsafe shouldThrow.unsafeInvoke(on: getterObject, true)
    do {
        _ = try unsafe checked.unsafeInvoke(on: getterObject)
        preconditionFailure("Expected the provider's typed error.")
    } catch let error as NativeSwiftError {
        let matched = error.withUnderlyingError {
            if case GenericConsumerFailure.initialize(44) = $0 { return true }
            return false
        }
        precondition(matched)
    }
}

@MainActor
func prepare(_ path: String, destroyed: UnsafeMutablePointer<Int32>) async throws -> (
    NativeValue, NativeFunction<Int32, UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<Int64>>, UnsafeRawPointer
) {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        throw GenericConsumerFailure.load(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let argumentType = try await runtime.cFunction(named: "ABIGenericResilientArgument", as: (() -> UnsafeRawPointer).self)
    let argument = try unsafe argumentType.unsafeInvoke()
    let metadata = try await runtime.cFunction(
        named: "ABIGenericRecordMetadata", as: ((UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32).self, in: scope
    )
    var first: UnsafeRawPointer?, repeated: UnsafeRawPointer?
    let firstStatus = try withUnsafeMutablePointer(to: &first) { try unsafe metadata.unsafeInvoke(argument, $0) }
    let repeatedStatus = try withUnsafeMutablePointer(to: &repeated) { try unsafe metadata.unsafeInvoke(argument, $0) }
    precondition(firstStatus == 0 && repeatedStatus == 0 && first != nil && first == repeated)
    let layout = try await runtime.cFunction(
        named: "ABIGenericRecordLayout",
        as: ((UnsafeRawPointer?, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Int32).self, in: scope
    )
    var stride = 0, alignment = 0
    let layoutStatus = try withUnsafeMutablePointer(to: &stride) { stride in
        try withUnsafeMutablePointer(to: &alignment) { try unsafe layout.unsafeInvoke(argument, stride, $0) }
    }
    precondition(layoutStatus == 0)
    let create = try await runtime.cFunction(
        named: "ABIResilientRecordCreate", as: ((Int64, UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer).self, in: scope
    )
    let destroyInput = try await runtime.cFunction(named: "ABIResilientRecordDestroy", as: ((UnsafeMutableRawPointer) -> Void).self, in: scope)
    let initialize = try await runtime.cFunction(
        named: "ABIGenericRecordInitialize",
        as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutableRawPointer) -> Int32).self, in: scope
    )
    let destroy = try await runtime.cFunction(
        named: "ABIGenericRecordDestroy", as: ((UnsafeRawPointer?, UnsafeMutableRawPointer) -> Int32).self, in: scope
    )
    let measure = try await runtime.cFunction(
        named: "ABIGenericRecordMeasure",
        as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<Int64>) -> Int32).self, in: scope
    )
    let input = unsafe NativeValue(adopting: try create.unsafeInvoke(42, destroyed),
                                  as: try .opaque(named: "ResilientRecord"), retaining: destroyInput, release: { address in
        do { try unsafe destroyInput.unsafeInvoke(address) }
        catch { fatalError("Input destruction failed: \(error)") }
    })
    let value = try NativeValue(type: .opaque(named: "GenericRecord", size: stride, alignment: alignment),
                               retaining: (initialize, destroy, argumentType), destroy: { address in
        do {
            let status = try unsafe destroy.unsafeInvoke(argument, address)
            precondition(status == 0)
        } catch { fatalError("Generic destruction failed: \(error)") }
    }) { output in
        let status = try unsafe input.withUnsafeBytes {
            try unsafe initialize.unsafeInvoke(argument, $0.baseAddress!, output.baseAddress!)
        }
        guard status == 0 else { throw GenericConsumerFailure.initialize(status) }
    }
    await runtime.removeCachedResults()
    return (value, measure, argument)
}

let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
destroyed.initialize(to: 0)
defer { destroyed.deinitialize(count: 1); destroyed.deallocate() }
var value: NativeValue?
do {
    let prepared = try await prepare(CommandLine.arguments[1], destroyed: destroyed)
    value = prepared.0
    precondition(destroyed.pointee == 0)
    var actual: Int64 = -1
    let status = try unsafe prepared.0.withUnsafeBytes { input in
        try withUnsafeMutablePointer(to: &actual) {
            try unsafe prepared.1.unsafeInvoke(prepared.2, input.baseAddress!, $0)
        }
    }
    precondition(status == 0 && actual == 42)
}
// Only the value's destructor and retained owners remain; all lookup handles
// outside the value, the runtime, and the original loader reference have ended.
withExtendedLifetime(value) { precondition(destroyed.pointee == 0) }
value = nil
precondition(destroyed.pointee == 1)
print("Generic Swift consumer passed")
try await exerciseGenericBindings(CommandLine.arguments[1])
print("Generic Swift binding consumer passed")
