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
    }
    if (managed || base is any NativePointerValue.Type), name.hasSuffix("G") {
        name = try swiftNominalClosureName(name)
    }
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
    if let convention = type as? any SwiftConventionArgument.Type {
        if convention.convention == .inoutValue { return ["-indirect"] }
        return try swiftClosureAuthTypes(convention.wrappedType)
    }
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
    static func makeClosureCodec() throws -> SwiftClosureCodec
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec
    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?, asynchronous: Bool, consuming: Bool) throws -> NativeValueStorage
    func encodeClosure(consuming: Bool) throws -> NativeValueStorage
    func encodeClosureResult() throws -> NativeValueStorage
}

extension SwiftClosureValue {
    func encodeClosureResult() throws -> NativeValueStorage { try encodeClosure(consuming: false) }
}

struct SwiftClosureCodec: Sendable {
    let type: CValueType
    let nativePlan: SwiftGenericClosurePlan?
    let encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
    let borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)?
    let takeValue: (@Sendable (ABISwiftClosureValue, SwiftValueCodeLifetime?) -> Any)?
    let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any

    init(type: CValueType, nativePlan: SwiftGenericClosurePlan? = nil,
         encoding encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)? = nil,
         borrowing borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)? = nil,
         taking takeValue: (@Sendable (ABISwiftClosureValue, SwiftValueCodeLifetime?) -> Any)? = nil,
         makeValue: @escaping @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any) {
        self.type = type
        self.nativePlan = nativePlan
        self.encodeValue = encodeValue
        self.borrowValue = borrowValue
        self.takeValue = takeValue
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
         codeLifetime: SwiftValueCodeLifetime? = nil, ownsContext: Bool = true,
         implementation prepared: SwiftImplementation? = nil) throws {
        self.ownsContext = ownsContext
        do {
            guard let function = ABIAuthenticateSwiftClosureFunction(value.function, discriminator) else {
                throw ABIInvocationError.unexpectedNilResult(expected: "a Swift closure")
            }
            implementation = try prepared ?? SwiftImplementation(function: function, retaining: nil)
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
final class SwiftNativeClosureAdapter: Sendable {
    private enum Entry: Sendable {
        case synchronous(SwiftClosureCallbackOwner)
        case asynchronous(SwiftAsyncClosureCallbackOwner)
    }
    private struct Field: Sendable {
        let offset: Int
        let adapter: SwiftNativeClosureAdapter
        let reverse: SwiftNativeClosureAdapter?
    }
    // A formal tuple carries leaf addresses; a generic T bound to the same
    // tuple still carries one contiguous native value.
    private struct TupleRepresentation: Sendable {
        let metadata: Any.Type
        let expanded: SwiftTupleValuePlan?
        let projections: [SwiftTupleValuePlan.NativeProjection]
        private let stride: Int
        private let alignment: Int
        private let constants: SwiftValueConstants

        init(metadata: Any.Type, expanded: SwiftTupleValuePlan?) {
            self.metadata = metadata; self.expanded = expanded
            let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
            stride = layout.stride; alignment = layout.alignment
            constants = SwiftValueConstants(metadata)
            func leaves(_ type: Any.Type, at offset: Int) -> [SwiftTupleValuePlan.NativeProjection] {
                if let tuple = SwiftTupleMetadata(type) {
                    return tuple.elements.flatMap { leaves($0.type, at: offset + $0.offset) }
                }
                let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
                return [.init(offset: offset, size: layout.size, metadata: type)]
            }
            projections = leaves(metadata, at: 0)
        }

        func makeResultStorage() -> NativeValueStorage {
            expanded?.makeResultStorage() ?? NativeValueStorage(size: stride, alignment: alignment,
                codeLifetime: SwiftValueCodeLifetime.current)
        }

        func materializeArgument(from source: UnsafeMutableRawPointer, consuming: Bool) -> NativeValueStorage {
            if let expanded { return expanded.materializeArgument(from: source, consuming: consuming) }
            let type = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
            let storage = NativeValueStorage(size: stride, alignment: alignment,
                codeLifetime: SwiftValueCodeLifetime.current, destroyingWith: { value in
                    if consuming { ABISwiftTakeValue(type, source, value) }
                    else { ABISwiftDestroyValue(type, value) }
                })
            if consuming { ABISwiftTakeValue(type, storage.address, source) }
            else { ABISwiftCopyValue(type, storage.address, source) }
            constants.initialize(at: storage.address)
            return storage
        }

        func closure(at offset: Int, result: Bool) throws -> SwiftGenericClosurePlan {
            for leaf in expanded?.leaves ?? [] where leaf.nativeOffset == offset {
                if let closure = leaf.nativeClosure { return closure }
                if result, case .closure(let codec) = leaf.result { return codec.nativePlan! }
                if !result, let closure = leaf.argument.closure { return closure }
            }
            let projection = projections.first {
                $0.offset == offset && unsafeBitCast($0.metadata, to: UnsafeRawPointer.self).load(as: UInt.self) == 0x302
            }!
            return try SwiftGenericClosurePlan.nativeValue(projection.metadata)
        }

        func closureOffsets(result: Bool) -> [Int] {
            expanded?.leaves.compactMap { leaf in
                if leaf.nativeClosure != nil { return leaf.nativeOffset }
                if result, case .closure = leaf.result { return leaf.nativeOffset }
                if !result, leaf.argument.closure != nil { return leaf.nativeOffset }
                return nil
            } ?? []
        }
    }
    private enum ValueConversion: Sendable {
        case closure(SwiftNativeClosureAdapter, reverse: SwiftNativeClosureAdapter?)
        case tuple(source: TupleRepresentation, target: TupleRepresentation, fields: [Field])
    }
    private struct Argument: Sendable {
        let index: Int
        let conversion: ValueConversion
        let convention: SwiftArgumentConvention
        let escaping: Bool
    }
    private struct Arguments {
        let encoded: SwiftGenericParameters.Encoded
        let storage: [NativeValueStorage]
        let consumed: [NativeValueStorage]
        let writebacks: [() -> Void]

        func finishInvocation() {
            encoded.finishInvocation()
            for value in consumed { value.relinquishValue() }
            for writeback in writebacks { writeback() }
        }
    }
    private let source: SwiftGenericClosurePlan
    private let target: SwiftGenericClosurePlan
    private let arguments: [Argument]
    private let result: ValueConversion?
    private let initializeNativeResult: SwiftResultInitializer
    private let entry: Entry

    init(source: SwiftGenericClosurePlan, target: SwiftGenericClosurePlan) throws {
        try source.validateNativeValues(for: target)
        self.source = source; self.target = target
        let sourceResultTuple = source.result.tuple
        let resultTuple = target.result.tuple
        initializeNativeResult = swiftResultInitializer(nativeMetadata: target.nativeResult, generic: target.result, tuple: resultTuple)
        arguments = try zip(source.parameters.arguments, target.parameters.arguments).enumerated().compactMap { index, pair in
            let convention = pair.1.convention
            if pair.0.tuple != nil || pair.1.tuple != nil {
                let expected = TupleRepresentation(metadata: source.nativeParameters[index], expanded: pair.0.tuple)
                let incoming = TupleRepresentation(metadata: target.nativeParameters[index], expanded: pair.1.tuple)
                let fields = try Self.argumentFields(source: incoming, target: expected, mutable: convention == .inoutValue)
                return Argument(index: index, conversion: .tuple(source: incoming, target: expected, fields: fields),
                                convention: convention, escaping: true)
            }
            guard let expected = source.nativeArgumentClosures[index],
                  let incoming = target.nativeArgumentClosures[index] else { return nil }
            let adapter = try SwiftNativeClosureAdapter(source: incoming, target: expected)
            let reverse = try convention == .inoutValue ? SwiftNativeClosureAdapter(source: expected, target: incoming) : nil
            return Argument(index: index, conversion: .closure(adapter, reverse: reverse),
                            convention: convention, escaping: incoming.isEscaping)
        }
        if let produced = source.nativeResultClosure, let expected = target.nativeResultClosure {
            result = .closure(try SwiftNativeClosureAdapter(source: produced, target: expected), reverse: nil)
        } else if sourceResultTuple != nil || resultTuple != nil {
            let expected = TupleRepresentation(metadata: target.nativeResult, expanded: resultTuple)
            let produced = TupleRepresentation(metadata: source.nativeResult, expanded: sourceResultTuple)
            result = .tuple(source: produced, target: expected, fields: try Self.resultFields(source: produced, target: expected))
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
            functions.initializeResult = { context, offset, size, destination, source in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue()
                SwiftValueCodeLifetime.withCurrent(value.codeLifetime) {
                    value.adapter.initializeNativeResult(offset, size, destination!, source!)
                }
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, nil, &failure) else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
            }
            entry = .synchronous(try SwiftClosureCallbackOwner(handle: handle))
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
            functions.initializeResult = { context, offset, size, destination, source in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue()
                SwiftValueCodeLifetime.withCurrent(value.codeLifetime) {
                    value.adapter.initializeNativeResult(offset, size, destination!, source!)
                }
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!).takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard let handle = ABICreateSwiftAsyncClosureCallback(interface.handle, functions, nil, &failure) else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
            }
            entry = .asynchronous(try SwiftAsyncClosureCallbackOwner(handle: handle))
        }
    }

    private static func argumentFields(source: TupleRepresentation, target: TupleRepresentation,
                                       mutable: Bool) throws -> [Field] {
        let offsets = Set(source.closureOffsets(result: false) + target.closureOffsets(result: false)).sorted()
        return try offsets.map { offset in
            let incoming = try source.closure(at: offset, result: false)
            let expected = try target.closure(at: offset, result: false)
            return Field(offset: offset, adapter: try SwiftNativeClosureAdapter(source: incoming, target: expected),
                         reverse: try mutable ? SwiftNativeClosureAdapter(source: expected, target: incoming) : nil)
        }
    }

    private static func resultFields(source: TupleRepresentation, target: TupleRepresentation) throws -> [Field] {
        let offsets = Set(source.closureOffsets(result: true) + target.closureOffsets(result: true)).sorted()
        return try offsets.map { offset in
            Field(offset: offset, adapter: try SwiftNativeClosureAdapter(source: source.closure(at: offset, result: true),
                target: target.closure(at: offset, result: true)), reverse: nil)
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
        -> Arguments {
        let unpacked = target.parameters.unpack(incoming)
        var addresses = unpacked.addresses
        var storage = unpacked.storage
        var consumed: [NativeValueStorage] = []
        var writebacks: [() -> Void] = []
        for argument in arguments {
            let address = addresses[argument.index]!
            switch argument.conversion {
            case .closure(let adapter, let reverse):
                let mutable = argument.convention == .inoutValue
                let source = mutable ? address.load(as: UnsafeMutableRawPointer.self) : address
                let encoded = adapter.encode(source.load(as: ABISwiftClosureValue.self),
                    taking: argument.convention == .consuming, escaping: mutable || argument.escaping,
                    retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
                storage.append(encoded)
                if argument.convention == .consuming { consumed.append(encoded) }
                if let reverse {
                    let pointer = NativeValueStorage(size: MemoryLayout<UnsafeMutableRawPointer>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment, owner: encoded)
                    pointer.store(encoded.address)
                    storage.append(pointer)
                    addresses[argument.index] = pointer.address
                    writebacks.append {
                        let replacement = reverse.encode(encoded.address.load(as: ABISwiftClosureValue.self),
                            taking: true, escaping: true, retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
                        encoded.relinquishValue()
                        let previous = source.load(as: ABISwiftClosureValue.self)
                        source.storeBytes(of: replacement.address.load(as: ABISwiftClosureValue.self), as: ABISwiftClosureValue.self)
                        replacement.relinquishValue()
                        ABIReleaseSwiftClosureContext(previous.context)
                    }
                } else { addresses[argument.index] = encoded.address }
            case .tuple(let incoming, let expected, let fields):
                let mutable = argument.convention == .inoutValue
                let native: NativeValueStorage
                if mutable {
                    native = incoming.makeResultStorage()
                    let source = address.load(as: UnsafeMutableRawPointer.self)
                    let metadata = unsafeBitCast(incoming.metadata, to: UnsafeRawPointer.self)
                    ABISwiftCopyValue(metadata, native.address, source)
                    native.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
                    let previous = incoming.makeResultStorage()
                    writebacks.append {
                        Self.reabstractFields(fields, at: native.address, reverse: true, context: context)
                        ABISwiftTakeValue(metadata, previous.address, source)
                        previous.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
                        ABISwiftTakeValue(metadata, source, native.address)
                        native.relinquishValue()
                    }
                } else {
                    native = incoming.materializeArgument(from: address, consuming: argument.convention == .consuming)
                    if argument.convention == .consuming { consumed.append(native) }
                }
                Self.reabstractFields(fields, at: native.address, reverse: false, context: context)
                storage.append(native)
                if mutable {
                    let pointer = NativeValueStorage(size: MemoryLayout<UnsafeMutableRawPointer>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment, owner: native)
                    pointer.store(native.address)
                    storage.append(pointer)
                    addresses[argument.index] = pointer.address
                } else if let expanded = expected.expanded {
                    let vector = NativeValueStorage(size: expanded.leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment, owner: native)
                    for (index, address) in expanded.nativeArgumentAddresses(native.address).enumerated() {
                        vector.address.storeBytes(of: address, toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                                                  as: UnsafeMutableRawPointer?.self)
                    }
                    storage.append(vector)
                    addresses[argument.index] = vector.address
                } else { addresses[argument.index] = native.address }
            }
        }
        return Arguments(encoded: source.parameters.encode(addresses), storage: storage, consumed: consumed, writebacks: writebacks)
    }

    private static func reabstractFields(_ fields: [Field], at address: UnsafeMutableRawPointer,
                                        reverse: Bool, context: SwiftNativeClosureContext) {
        for field in fields {
            let location = address.advanced(by: field.offset)
            let adapter = reverse ? field.reverse! : field.adapter
            let replacement = adapter.encode(location.load(as: ABISwiftClosureValue.self), taking: true, escaping: true,
                retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
            location.storeBytes(of: replacement.address.load(as: ABISwiftClosureValue.self), as: ABISwiftClosureValue.self)
            replacement.relinquishValue()
        }
    }

    private func initializeResult(_ storage: NativeValueStorage?, at output: UnsafeMutableRawPointer,
                                  context: SwiftNativeClosureContext) {
        if let result, let storage {
            switch result {
            case .closure(let adapter, _):
                let encoded = adapter.encode(storage.address.load(as: ABISwiftClosureValue.self), taking: true, escaping: true,
                    retainingCode: context.codeOwner, codeLifetime: context.codeLifetime)
                output.copyMemory(from: encoded.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
                encoded.relinquishValue()
            case .tuple(_, let target, let fields):
                source.resultConstants.initialize(at: storage.address)
                Self.reabstractFields(fields, at: storage.address, reverse: false, context: context)
                ABISwiftTakeValue(unsafeBitCast(target.metadata, to: UnsafeRawPointer.self), output, storage.address)
            }
        }
        target.resultConstants.initialize(at: output)
    }

    private func resultStorage() -> NativeValueStorage? {
        switch result {
        case .none: nil
        case .closure: NativeValueStorage(size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment)
        case .tuple(let source, _, _): source.makeResultStorage()
        }
    }

    private func invoke(_ context: SwiftNativeClosureContext, arguments: UnsafePointer<UnsafeMutableRawPointer?>?,
                        result output: UnsafeMutableRawPointer, error: UnsafeMutableRawPointer?) -> Bool {
        guard case .synchronous(let interface) = source.transport else {
            preconditionFailure("A native reabstraction preserves its synchronous convention.")
        }
        let arguments = convertArguments(arguments, context: context)
        let result = resultStorage()
        let unusedError = target.errorPlan == nil ? source.errorPlan?.makeStorage() : nil
        let function = ABIAuthenticateSwiftClosureFunction(context.value.function, source.discriminator)!
        var didThrow = false
        let success = arguments.encoded.addresses.withUnsafeBufferPointer { arguments in
            if source.errorPlan != nil {
                return ABIUnsafeInvokeSwiftThrowingCallInterface(interface.handle, function, result?.address ?? output,
                    arguments.baseAddress, context.value.context, error ?? unusedError?.address, &didThrow, nil)
            }
            return ABIUnsafeInvokeSwiftCallInterface(interface.handle, function, result?.address ?? output,
                arguments.baseAddress, context.value.context, nil)
        }
        defer { withExtendedLifetime((context, arguments, unusedError)) {} }
        precondition(success, "A prepared native reabstraction has a valid call frame.")
        arguments.finishInvocation()
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }

    private nonisolated(nonsending) func invokeAsync(_ context: SwiftNativeClosureContext,
        arguments: UnsafePointer<UnsafeMutableRawPointer?>?, result output: UnsafeMutableRawPointer,
        error: UnsafeMutableRawPointer?) async -> Bool {
        guard case .asynchronous(let interface, _) = source.transport else {
            preconditionFailure("A native reabstraction preserves its asynchronous convention.")
        }
        let arguments = convertArguments(arguments, context: context)
        let pointers = SwiftGenericArgumentBuffer(arguments.encoded.addresses.map { UInt(bitPattern: $0) })
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
        defer { withExtendedLifetime((context, arguments, pointers, unusedError)) { ABIReleaseSwiftAsyncInvocation(invocation!) } }
        await invokeSwiftAsync(invocation!)
        arguments.finishInvocation()
        let didThrow = ABISwiftAsyncInvocationDidThrow(invocation!)
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }
}

struct SwiftRuntimeClosureConversions: Sendable {
    private struct Field: Sendable {
        let offset: Int
        let toStorage: SwiftNativeClosureAdapter
        let toNative: SwiftNativeClosureAdapter
        let ownsContext: Bool
    }
    private let fields: [Field]
    var isEmpty: Bool { fields.isEmpty }

    init(metadata: Any.Type, tuple: SwiftTupleValuePlan?, closure: SwiftGenericClosurePlan?) throws {
        var functions: [(Int, Any.Type, SwiftGenericClosurePlan)] = []
        if let closure { functions.append((0, metadata, closure)) }
        if let tuple {
            functions += tuple.leaves.compactMap { leaf in
                leaf.nativeClosure.map { (leaf.nativeOffset, leaf.nativeType, $0) }
            }
        }
        fields = try functions.compactMap { offset, metadata, native in
            let storage = try SwiftGenericClosurePlan.nativeValue(metadata)
            guard !native.hasSameNativeABI(as: storage) else { return nil }
            return Field(offset: offset,
                toStorage: try SwiftNativeClosureAdapter(source: native, target: storage),
                toNative: try SwiftNativeClosureAdapter(source: storage, target: native),
                ownsContext: storage.isEscaping)
        }
    }

    func apply(to storage: NativeValueStorage, native: Bool, retainingCode owner: Any?,
               codeLifetime: SwiftValueCodeLifetime?) {
        for field in fields {
            let location = storage.address.advanced(by: field.offset)
            let adapter = native ? field.toNative : field.toStorage
            let replacement = adapter.encode(location.load(as: ABISwiftClosureValue.self),
                taking: field.ownsContext, escaping: field.ownsContext,
                retainingCode: owner, codeLifetime: codeLifetime)
            location.storeBytes(of: replacement.address.load(as: ABISwiftClosureValue.self), as: ABISwiftClosureValue.self)
            if field.ownsContext { replacement.relinquishValue() }
            else { storage.retainResource(replacement) }
        }
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
