import ABIBridge
import Darwin
import Foundation

private enum GenericConsumerFailure: Error { case load(String), initialize(Int32) }

private struct GenericConsumerBool: ABIBridgeValue {
    let value: Bool
    init(_ value: Bool) { self.value = value }
    static let abiType: NativeType = .bool
    init(nativeValue: NativeValue) throws { value = try unsafe nativeValue.read(as: Bool.self) }
    static func nativeValue(from value: Self) throws -> NativeValue { try NativeValue(copying: value.value, as: .bool) }
}

@MainActor
func exerciseGenericBindings(_ adapterPath: String) async throws {
    guard let original = dlopen(adapterPath, RTLD_NOW | RTLD_LOCAL) else {
        throw GenericConsumerFailure.load(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    typealias TextBody = NativeSwiftClosure<() -> String>
    typealias NumberBody = NativeSwiftClosure<() -> Int64>
    let closurePack = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.closurePackGeneric<each A>(repeat () -> A) -> (repeat A)",
        as: ((TextBody, NumberBody) -> (String, Int64)).self,
        genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
    let packValues = try unsafe closurePack.unsafeInvoke(TextBody { "pack" }, NumberBody { 42 })
    precondition(packValues == ("pack", 42))
    let packOwnerType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericClosurePackOwner",
        genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
    let makePackOwner = try await packOwnerType.initializer(named: "init(_:)", as: ((TextBody, NumberBody) -> AnyObject).self)
    let packOwner = try unsafe makePackOwner.unsafeInvoke(TextBody { "owned pack" }, NumberBody { 43 })
    let callPackOwner = try await runtime.object(packOwner).method(named: "call()", as: (() -> (String, Int64)).self)
    let ownedPackValues = try unsafe callPackOwner.unsafeInvoke()
    precondition(ownedPackValues == ("owned pack", 43))
    let callbackType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericCallbackConventions",
        genericArguments: [.type(Int64.self)])
    let makeCallbackOwner = try await callbackType.initializer(named: "init()", as: (() -> AnyObject).self)
    let callbacks = runtime.object(try unsafe makeCallbackOwner.unsafeInvoke())
    let selectedCallback = try await callbacks.method(named: "callback(_:)", as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self)
    let callbackValue = try unsafe selectedCallback.unsafeInvoke(NativeSwiftClosure<(Int64) -> Int64> { $0 + 2 })
    precondition(callbackValue == 42)
    let returnedCallback = try await callbacks.method(named: "returnedCallback()", as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self)
    let returnedBody = try unsafe returnedCallback.unsafeInvoke()
    let returnedValue = try unsafe returnedBody.unsafeInvoke(40)
    precondition(returnedValue == 42)
    let objectIdentity = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.objectConstraintGeneric<A where A: AnyObject>(A) -> A",
        as: ((AnyObject) -> AnyObject).self, genericArguments: [.type(AnyObject.self)])
    let originalObject = NSObject()
    let returnedObject = try unsafe objectIdentity.unsafeInvoke(originalObject)
    precondition(returnedObject === originalObject)
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
    let makeGetter = try await getterType.initializer(
        named: "init(A, B, Swift.Bool) -> ManagedSwiftFixtures.GenericEffectfulGetter<A, B>",
        as: ((String, GenericConsumerFailure, GenericConsumerBool) -> AnyObject).self)
    let getterObject = try unsafe makeGetter.unsafeInvoke("checked", .initialize(44), GenericConsumerBool(false))
    let checked = try await getterType.getter(named: "checked",
        as: (() throws(GenericConsumerFailure) -> String).self, declaredAs: "() throws(B) -> A")
    let checkedValue = try unsafe checked.unsafeInvoke(on: getterObject)
    precondition(checkedValue == "checked")
    let delayed = try await runtime.object(getterObject).getter(named: "delayedChecked",
        as: (nonisolated(nonsending) () async throws(GenericConsumerFailure) -> String).self, declaredAs: "() async throws(B) -> A")
    let delayedValue = try unsafe await delayed.unsafeInvoke()
    precondition(delayedValue == "checked")
    let flag = try await runtime.object(getterObject).getter(named: "shouldThrow.getter : Swift.Bool", as: (() -> GenericConsumerBool).self)
    let initialFlag = try unsafe flag.unsafeInvoke()
    precondition(!initialFlag.value)
    let shouldThrow = try await getterType.setter(named: "shouldThrow.setter : Swift.Bool", as: GenericConsumerBool.self)
    try unsafe shouldThrow.unsafeInvoke(on: getterObject, GenericConsumerBool(true))
    let updatedFlag = try unsafe flag.unsafeInvoke()
    precondition(updatedFlag.value)
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
