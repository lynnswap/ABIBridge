import ABIBridgeCore
import Synchronization

// The SIL discriminator hashes formal value types, not their register widths.
// Class identity, isolation, and ownership qualifiers are intentionally erased.
// https://github.com/swiftlang/swift/blob/main/lib/SIL/IR/SILFunctionType.cpp
func swiftClosureAuthType(_ type: Any.Type) throws -> String {
    guard !(type is any SwiftConventionArgument.Type) else {
        throw ABIResolutionError.unsupportedDeclaration("Inout and ownership-qualified callback parameters require a scoped native adapter.")
    }
    if let closure = type as? any SwiftClosureValue.Type {
        return "(" + (try SwiftFunctionSignature(closure.swiftFunctionType).closureAuthDescription()) + ")"
    }
    let base = (type as? any NativeOptionalValue.Type)?.wrappedType ?? type
    let managed = type is any ABIBridgeSwiftValue.Type
    guard (!(base is any ABIBridgeValue.Type) || managed) else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Closure signatures require built-in or explicitly described Swift values; foreign conversions are not supported."
        )
    }
    if base is AnyClass || base == AnyObject.self { return "-class" }
    if let metatype = SwiftMetatypeMetadata(base) {
        return type is any NativeOptionalValue.Type && metatype.isExistential ? "Optional<-metatype>" : "-metatype"
    }
    if let existential = SwiftExistentialRepresentation(base) {
        return existential.closureAuthType(optional: type is any NativeOptionalValue.Type)
    }
    if let value = type as? any ABIBridgeSwiftValue.Type {
        guard let components = value.swiftABIType.cType else { return "-indirect" }
        if withExtendedLifetime(components, { ABISwiftValueIsIndirect(components.handle) }) {
            return "-indirect"
        }
    }
    guard var name = _mangledTypeName(base) else {
        throw ABIResolutionError.metadataUnavailable("No Swift closure type identity for \(String(reflecting: type)).")
    }
    // SIL hashes these nominal declarations without their generic substitutions.
    if base is any SwiftArrayValue.Type {
        name = "Sa"
    } else if base is any NativePointerValue.Type {
        if name.hasPrefix("SPy") { name = "SP" }
        else if name.hasPrefix("Spy") { name = "Sp" }
    }
    if managed, name.hasSuffix("G") { name = try swiftNominalClosureName(name) }
    let nominal = "$s" + name
    return type is any NativeOptionalValue.Type ? "Optional<" + nominal + ">" : nominal
}

// A bound nominal mangling contains its declaration before the generic
// argument list. Let Swift's demangler validate candidate prefixes rather than
// interpreting identifier lengths, word substitutions, or nested contexts here.
private func swiftNominalClosureName(_ mangled: String) throws -> String {
    guard let fullName = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No generic Swift value identity.")
    }
    var nominalName = "", depth = 0
    for character in fullName {
        if character == "<" { depth += 1 }
        else if character == ">" { depth -= 1 }
        else if depth == 0 { nominalName.append(character) }
    }
    for index in mangled.indices where mangled[index] == "y" {
        let candidate = String(mangled[..<index])
        if DeclarationKey.demangle("$s" + candidate, language: .swift) == nominalName {
            return candidate
        }
    }
    throw ABIResolutionError.unsupportedDeclaration(
        "Cannot establish the nominal closure identity for " + fullName + "."
    )
}

private let swiftClosureDiscriminators = Mutex<[String: UInt16]>([:])

func swiftClosureDiscriminator(parameters: [String], result: String?) -> UInt16 {
    swiftClosureDiscriminator(parameters: parameters, results: result.map { [$0] } ?? [])
}

func swiftClosureDiscriminator(parameters: [String], results: [String]) -> UInt16 {
    let description = swiftClosureAuthDescription(parameters: parameters, results: results)
    return swiftClosureDiscriminators.withLock { cache in
        if let value = cache[description] { return value }
        let value = swiftPointerAuthHash(description)
        if cache.count == 128 { cache.removeAll(keepingCapacity: true) }
        cache[description] = value
        return value
    }
}

func swiftClosureAuthDescription(parameters: [String], results: [String]) -> String {
    "function:\(parameters.count):" + parameters.map { $0 + ":" }.joined()
        + "\(results.count):" + results.map { $0 + ":" }.joined()
}

func swiftClosureAuthTypes(_ type: Any.Type) throws -> [String] {
    if let tuple = SwiftTupleMetadata(type) {
        return try tuple.elements.flatMap { try swiftClosureAuthTypes($0.type) }
    }
    return [try swiftClosureAuthType(type)]
}

// ABI-stable SipHash-2-4, with LLVM's fixed ptrauth key and nonzero 16-bit range.
// https://github.com/llvm/llvm-project/blob/main/llvm/lib/Support/SipHash.cpp
private func swiftPointerAuthHash(_ string: String) -> UInt16 {
    let bytes = Array(string.utf8)
    let key0: UInt64 = 0x794a1079ebc9d4b5, key1: UInt64 = 0xd48187421b8bec6f
    var a: UInt64 = 0x736f6d6570736575 ^ key0
    var b: UInt64 = 0x646f72616e646f6d ^ key1
    var c: UInt64 = 0x6c7967656e657261 ^ key0
    var d: UInt64 = 0x7465646279746573 ^ key1
    func rotate(_ value: UInt64, by amount: UInt64) -> UInt64 {
        value << amount | value >> (64 - amount)
    }
    func rounds(_ count: Int) {
        for _ in 0..<count {
            a &+= b; b = rotate(b, by: 13) ^ a; a = rotate(a, by: 32)
            c &+= d; d = rotate(d, by: 16) ^ c
            a &+= d; d = rotate(d, by: 21) ^ a
            c &+= b; b = rotate(b, by: 17) ^ c; c = rotate(c, by: 32)
        }
    }
    let full = bytes.count / 8 * 8
    for offset in stride(from: 0, to: full, by: 8) {
        var word: UInt64 = 0
        for index in 0..<8 { word |= UInt64(bytes[offset + index]) << (index * 8) }
        d ^= word; rounds(2); a ^= word
    }
    var tail = UInt64(bytes.count & 0xff) << 56
    for index in full..<bytes.count { tail |= UInt64(bytes[index]) << ((index - full) * 8) }
    d ^= tail; rounds(2); a ^= tail
    c ^= 0xff; rounds(4)
    return UInt16((a ^ b ^ c ^ d) % 0xffff + 1)
}

protocol SwiftClosureValue: SendableMetatype {
    static var swiftFunctionType: Any.Type { get }
    static var requiresExplicitDeclaration: Bool { get }
    static var supportsResult: Bool { get }
    static func makeClosureCodec() throws -> SwiftClosureCodec
    func encodeClosure() throws -> NativeValueStorage
    func encodeClosureResult() throws -> NativeValueStorage
}

extension SwiftClosureValue {
    static var requiresExplicitDeclaration: Bool { false }
    static var supportsResult: Bool { true }
    func encodeClosureResult() throws -> NativeValueStorage { try encodeClosure() }
}

struct SwiftClosureCodec: Sendable {
    let type: CValueType
    let nativeValueTypes: [ObjectIdentifier]
    let nativePlan: SwiftGenericClosurePlan?
    let encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
    let borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)?
    let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any

    init(type: CValueType, nativeValueTypes: [ObjectIdentifier] = [], nativePlan: SwiftGenericClosurePlan? = nil,
         encoding encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)? = nil,
         borrowing borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)? = nil,
         makeValue: @escaping @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any) {
        self.type = type
        self.nativeValueTypes = nativeValueTypes
        self.nativePlan = nativePlan
        self.encodeValue = encodeValue
        self.borrowValue = borrowValue
        self.makeValue = makeValue
    }
}

final class SwiftClosureStorage {
    let value: ABISwiftClosureValue
    private let ownsContext: Bool
    let callbackFactory: SwiftClosureBodyFactory?
    let implementation: SwiftImplementation
    let codeOwner: Any?
    let codeLifetime: SwiftValueCodeLifetime?

    // Consumes one native context reference, including on preparation failure.
    init(adopting value: ABISwiftClosureValue, discriminator: UInt16, retaining owner: Any?,
         codeLifetime: SwiftValueCodeLifetime? = nil, ownsContext: Bool = true) throws {
        self.ownsContext = ownsContext
        do {
            guard let function = ABIAuthenticateSwiftClosureFunction(value.function, discriminator) else {
                throw ABIInvocationError.unexpectedNilResult(expected: "a Swift closure")
            }
            implementation = try SwiftImplementation(function: function, retaining: nil)
        } catch {
            withExtendedLifetime(owner) { if ownsContext { ABIReleaseSwiftClosureContext(value.context) } }
            throw error
        }
        self.value = value
        let callbackOwner = ABICopySwiftClosureCallbackCodeOwner(implementation.function, value.context).map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        callbackFactory = ABICopySwiftClosureCallbackBodyOwner(implementation.function, value.context).map {
            Unmanaged<SwiftClosureBodyFactory>.fromOpaque($0).takeRetainedValue()
        }
        codeOwner = (owner, implementation, callbackOwner)
        let callbackLifetime = (callbackOwner as? SwiftClosureCodeOwner)?.codeLifetime
        let images = implementation.image.map { [$0] } ?? []
        let lifetime = codeLifetime ?? callbackLifetime
            ?? (images.isEmpty ? nil : SwiftValueCodeLifetime(images))
        self.codeLifetime = SwiftValueCodeLifetime.connect([lifetime, callbackLifetime].compactMap { $0 },
            retaining: images)
    }

    deinit {
        withExtendedLifetime((implementation, codeOwner)) { if ownsContext { ABIReleaseSwiftClosureContext(value.context) } }
    }

    func encoded(codeLifetime: SwiftValueCodeLifetime? = nil) -> NativeValueStorage {
        if ownsContext { return Self.copy(value, retaining: self, codeLifetime: codeLifetime ?? self.codeLifetime) }
        let storage = NativeValueStorage(size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment, owner: self, codeLifetime: self.codeLifetime)
        storage.store(value)
        return storage
    }

    static func copy(_ value: ABISwiftClosureValue, retaining owner: AnyObject,
                     codeLifetime: SwiftValueCodeLifetime? = nil) -> NativeValueStorage {
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            owner: owner, codeLifetime: codeLifetime, destroyingWith: destroy
        )
        ABIRetainSwiftClosureContext(value.context)
        storage.store(value)
        return storage
    }

    static func destroy(_ address: UnsafeMutableRawPointer) {
        ABIReleaseSwiftClosureContext(address.load(as: ABISwiftClosureValue.self).context)
    }
}

// A prepared entry is shared by individual native closure contexts. Preparing
// nested adapters can fail before publication; dispatch only moves valid native
// function pairs and uses the caller's ownership and lifetime guarantees.
final class SwiftNativeClosureAdapter {
    private enum Entry {
        case synchronous(SwiftClosureCallbackOwner)
        case asynchronous(SwiftAsyncClosureCallbackOwner)
    }
    private let source: SwiftGenericClosurePlan
    private let target: SwiftGenericClosurePlan
    private let arguments: [(index: Int, adapter: SwiftNativeClosureAdapter, escaping: Bool)]
    private let result: SwiftNativeClosureAdapter?
    private let entry: Entry

    init(source: SwiftGenericClosurePlan, target: SwiftGenericClosurePlan) throws {
        try source.validateNativeValues(for: target)
        self.source = source; self.target = target
        arguments = try zip(source.parameters.arguments, target.parameters.arguments).enumerated().compactMap { index, pair in
            guard case .closure(let expected) = pair.0, case .closure(let incoming) = pair.1 else { return nil }
            return (index, try SwiftNativeClosureAdapter(source: incoming, target: expected), incoming.isEscaping)
        }
        if case .closure(let produced) = source.result, case .closure(let expected) = target.result {
            result = try SwiftNativeClosureAdapter(source: produced.nativePlan!, target: expected.nativePlan!)
        } else { result = nil }
        var failure: OpaquePointer?
        switch target.transport {
        case .synchronous(let interface):
            var functions = ABISwiftThrowingClosureCallbackFunctions()
            functions.usesNativeContext = true
            functions.invoke = { context, arguments, result, error in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue()
                return value.adapter.invoke(value, arguments: arguments, result: result!, error: error)
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, nil, &failure) else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
            }
            entry = .synchronous(SwiftClosureCallbackOwner(handle: handle))
        case .asynchronous(let interface, _):
            var functions = ABISwiftAsyncClosureCallbackFunctions()
            functions.usesNativeContext = true
            functions.createBody = { context, arguments, result, error, didThrow in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue()
                let body = SwiftAsyncClosureBody(inheritsCallerIsolation: value.adapter.inheritsCallerIsolation,
                    codeLifetime: value.codeLifetime) { arguments, result, error in
                    await value.adapter.invokeAsync(value, arguments: arguments, result: result, error: error)
                }
                let invocation = SwiftAsyncClosureInvocation(body, arguments, result!, error, didThrow!)
                if body.inheritsCallerIsolation {
                    let operation: nonisolated(nonsending) @Sendable () async -> Void = { await invocation.run() }
                    return retainedValue(operation)
                }
                let operation: @Sendable @concurrent () async -> Void = { await invocation.run() }
                return retainedValue(operation)
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard let handle = ABICreateSwiftAsyncClosureCallback(interface.handle, functions, nil, &failure) else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
            }
            entry = .asynchronous(SwiftAsyncClosureCallbackOwner(handle: handle))
        }
    }

    private var inheritsCallerIsolation: Bool {
        if case .asynchronous(_, let isolation) = target.transport { return isolation }
        return false
    }

    func encode(_ value: ABISwiftClosureValue, taking: Bool, escaping: Bool, retainingValue valueOwner: AnyObject? = nil,
                retainingCode owner: Any?, codeLifetime: SwiftValueCodeLifetime?) -> NativeValueStorage {
        let context = SwiftNativeClosureContext(adapter: self, value: value, taking: taking, escaping: escaping, retainingValue: valueOwner,
                                               retainingCode: owner, codeLifetime: codeLifetime)
        let function: UnsafeRawPointer?
        switch entry {
        case .synchronous(let entry): function = ABISignSwiftClosureFunction(entry.function, target.discriminator)
        case .asynchronous(let entry):
            function = ABISignSwiftAsyncClosureDescriptor(ABISwiftAsyncClosureCallbackDescriptor(entry.handle), target.discriminator)
        }
        let storage = NativeValueStorage(size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment, codeLifetime: codeLifetime,
            destroyingWith: SwiftClosureStorage.destroy)
        storage.store(ABISwiftClosureValue(function: function, context: Unmanaged.passRetained(context).toOpaque()))
        return storage
    }

    private func convertArguments(_ incoming: UnsafePointer<UnsafeMutableRawPointer?>?, context: SwiftNativeClosureContext)
        -> (SwiftGenericParameters.Encoded, [NativeValueStorage]) {
        var addresses = target.parameters.unpack(incoming)
        var storage: [NativeValueStorage] = []
        for argument in arguments {
            let value = addresses[argument.index]!.load(as: ABISwiftClosureValue.self)
            let encoded = argument.adapter.encode(value, taking: false, escaping: argument.escaping,
                retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
            storage.append(encoded)
            addresses[argument.index] = encoded.address
        }
        return (source.parameters.encode(addresses), storage)
    }

    private func initializeResult(_ storage: NativeValueStorage?, at output: UnsafeMutableRawPointer,
                                  context: SwiftNativeClosureContext) {
        if let result, let storage {
            let encoded = result.encode(storage.address.load(as: ABISwiftClosureValue.self), taking: true, escaping: true,
                retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
            output.copyMemory(from: encoded.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
            encoded.relinquishValue()
        }
        target.resultConstants.initialize(at: output)
    }

    private func resultStorage() -> NativeValueStorage? {
        result == nil ? nil : NativeValueStorage(size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment)
    }

    private func invoke(_ context: SwiftNativeClosureContext, arguments: UnsafePointer<UnsafeMutableRawPointer?>?,
                        result output: UnsafeMutableRawPointer, error: UnsafeMutableRawPointer?) -> Bool {
        guard case .synchronous(let interface) = source.transport else {
            preconditionFailure("A native reabstraction preserves its synchronous convention.")
        }
        let (arguments, storage) = convertArguments(arguments, context: context)
        let result = resultStorage()
        let unusedError = target.errorPlan == nil ? source.errorPlan?.makeStorage() : nil
        let function = ABIAuthenticateSwiftClosureFunction(context.value.function, source.discriminator)!
        var didThrow = false
        let success = arguments.addresses.withUnsafeBufferPointer { arguments in
            if source.errorPlan != nil {
                return ABIUnsafeInvokeSwiftThrowingCallInterface(interface.handle, function, result?.address ?? output,
                    arguments.baseAddress, context.value.context, error ?? unusedError?.address, &didThrow, nil)
            }
            return ABIUnsafeInvokeSwiftCallInterface(interface.handle, function, result?.address ?? output,
                arguments.baseAddress, context.value.context, nil)
        }
        defer { withExtendedLifetime((context, storage, arguments, unusedError)) {} }
        precondition(success, "A prepared native reabstraction has a valid call frame.")
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }

    private nonisolated(nonsending) func invokeAsync(_ context: SwiftNativeClosureContext,
        arguments: UnsafePointer<UnsafeMutableRawPointer?>?, result output: UnsafeMutableRawPointer,
        error: UnsafeMutableRawPointer?) async -> Bool {
        guard case .asynchronous(let interface, _) = source.transport else {
            preconditionFailure("A native reabstraction preserves its asynchronous convention.")
        }
        let (arguments, storage) = convertArguments(arguments, context: context)
        let pointers = SwiftGenericArgumentBuffer(arguments.addresses.map { UInt(bitPattern: $0) })
        let forwarded = UnsafeRawPointer(bitPattern: pointers.address)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        let result = resultStorage()
        let unusedError = target.errorPlan == nil ? source.errorPlan?.makeStorage() : nil
        // The native caller supplies a live descriptor under the prepared ABI.
        // Its code lifetime is inherited from the active native call, so dispatch
        // does not reopen images or perform fallible public-handle preparation.
        let descriptor = ABIAuthenticateSwiftAsyncClosureDescriptor(context.value.function, source.discriminator)!
        let offset = descriptor.load(as: Int32.self)
        let function = ABIUnsafeFunctionAtAddress(descriptor.advanced(by: Int(offset)))
        let contextSize = descriptor.load(fromByteOffset: 4, as: UInt32.self)
        let invocation = ABICreateSwiftAsyncInvocation(interface.handle, function, contextSize,
            result?.address ?? output, forwarded, context.value.context, error ?? unusedError?.address, nil)
        precondition(invocation != nil, "A prepared native async reabstraction has a valid call frame.")
        defer { withExtendedLifetime((context, arguments, storage, pointers, unusedError)) { ABIReleaseSwiftAsyncInvocation(invocation!) } }
        await invokeSwiftAsync(invocation!)
        let didThrow = ABISwiftAsyncInvocationDidThrow(invocation!)
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }
}

private final class SwiftNativeClosureContext {
    let adapter: SwiftNativeClosureAdapter
    let value: ABISwiftClosureValue
    let codeOwner: SwiftClosureCodeOwner
    let codeLifetime: SwiftValueCodeLifetime?
    private let ownsContext: Bool
    private let valueOwner: AnyObject?

    init(adapter: SwiftNativeClosureAdapter, value: ABISwiftClosureValue, taking: Bool, escaping: Bool, retainingValue valueOwner: AnyObject?,
         retainingCode owner: Any?, codeLifetime: SwiftValueCodeLifetime?) {
        self.adapter = adapter; self.value = value; self.codeLifetime = codeLifetime; self.valueOwner = valueOwner
        codeOwner = SwiftClosureCodeOwner((adapter, owner), codeLifetime: codeLifetime)!
        ownsContext = taking || escaping
        if escaping && !taking { ABIRetainSwiftClosureContext(value.context) }
    }
    deinit { withExtendedLifetime((codeOwner, valueOwner)) { if ownsContext { ABIReleaseSwiftClosureContext(value.context) } } }
}
