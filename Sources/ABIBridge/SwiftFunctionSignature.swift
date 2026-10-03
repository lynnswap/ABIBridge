import ABIBridgeCore

/// The function metadata's formal types and effects, before declaration-level lowering.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
struct SwiftFunctionSignature: Sendable {
    let parameters: [Any.Type]
    let result: Any.Type
    let failure: Any.Type
    let isAsync: Bool
    let inheritsCallerIsolation: Bool

    init(_ type: Any.Type) throws {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x302 else {
            throw ABIResolutionError.unsupportedDeclaration("Expected a Swift function type: \(String(reflecting: type)).")
        }
        let flags = metadata.load(fromByteOffset: word, as: UInt.self)
        guard flags & 0x00ff0000 == 0 else {
            throw ABIResolutionError.unsupportedDeclaration("Expected the native Swift function convention.")
        }
        let count = Int(flags & 0xffff)
        result = metadata.load(fromByteOffset: 2 * word, as: Any.Type.self)
        parameters = (0..<count).map {
            metadata.load(fromByteOffset: (3 + $0) * word, as: Any.Type.self)
        }
        var offset = (3 + count) * word
        if flags & 0x02000000 != 0 {
            for index in 0..<count {
                let parameterFlags = metadata.load(fromByteOffset: offset + index * 4, as: UInt32.self)
                // Ownership wrappers carry the corresponding storage contract.
                // Raw inout/consuming function parameters cannot use value invocation.
                guard parameterFlags == 0 else {
                    throw ABIResolutionError.unsupportedDeclaration("Use explicit Swift argument wrappers for parameter conventions.")
                }
            }
            offset += count * 4
        }
        func alignToWord() { offset = (offset + word - 1) & ~(word - 1) }
        alignToWord()
        guard flags & 0x08000000 == 0, flags & 0x10000000 == 0 else {
            throw ABIResolutionError.unsupportedDeclaration("Differentiable and global-actor function types require their native invocation conventions.")
        }
        let extended = flags & 0x80000000 != 0
            ? metadata.load(fromByteOffset: offset, as: UInt32.self) : 0
        guard extended & 0x0e == 0 || extended & 0x0e == 4 else {
            throw ABIResolutionError.unsupportedDeclaration("An isolated-any function requires a dynamic isolation context.")
        }
        if flags & 0x80000000 != 0 { offset += 4 }
        alignToWord()
        if extended & 1 != 0 {
            failure = metadata.load(fromByteOffset: offset, as: Any.Type.self)
        } else if flags & 0x01000000 != 0 {
            failure = (any Error).self
        } else {
            failure = Never.self
        }
        isAsync = flags & 0x20000000 != 0
        inheritsCallerIsolation = extended & 0x0e == 4
    }

    func makeErrorPlan(genericType: CValueType? = nil) throws -> SwiftErrorPlan? {
        if failure == Never.self && genericType == nil { return nil }
        if failure == (any Error).self { return try SwiftErrorPlan.make((any Error).self, genericType: genericType) }
        guard let error = failure as? any Error.Type else {
            throw ABIResolutionError.unsupportedDeclaration("The function's thrown type does not conform to Error.")
        }
        return try SwiftErrorPlan.make(error, genericType: genericType)
    }

    var requiresClosureDeclaration: Bool {
        func containsClosure(_ type: Any.Type) -> Bool {
            if type is any SwiftGenericClosureValue.Type { return true }
            if let convention = type as? any SwiftConventionArgument.Type { return containsClosure(convention.wrappedType) }
            if let tuple = SwiftTupleMetadata(type) { return tuple.elements.contains { containsClosure($0.type) } }
            return false
        }
        return (parameters + [result]).contains(where: containsClosure)
    }

    func closureDiscriminator() throws -> UInt16 {
        let (parameters, results) = try closureAuthTypes()
        return swiftClosureDiscriminator(parameters: parameters, results: results)
    }

    func closureAuthDescription() throws -> String {
        let (parameters, results) = try closureAuthTypes()
        return swiftClosureAuthDescription(parameters: parameters, results: results)
    }

    private func closureAuthTypes() throws -> ([String], [String]) {
        var parameters = isAsync && inheritsCallerIsolation ? ["-class"] : []
        for type in self.parameters {
            parameters.append(contentsOf: try swiftClosureAuthTypes(type))
        }
        return (parameters, try swiftClosureAuthTypes(result))
    }
}

enum SwiftCallablePlan: Sendable {
    case synchronous(SwiftCall)
    case asynchronous(SwiftAsyncCall, SwiftAsyncImplementation)

    init(signature: Any.Type, symbol: ResolvedSymbol, resolver: SymbolResolver?,
         trailingType: CValueType? = nil, consumesArguments: Bool = false,
         generic: SwiftGenericCallPlan? = nil) throws {
        let description = try SwiftFunctionSignature(signature)
        let errorPlan = try description.makeErrorPlan(genericType: generic?.errorType)
        let opaque = try generic?.resultType != nil ? nil
            : SwiftOpaqueResultPlan.make(for: description.result, symbol: symbol, resolver: resolver)
        if description.isAsync {
            guard let resolver else {
                throw ABIResolutionError.metadataUnavailable("Async calls require the native descriptor's resolver.")
            }
            self = .asynchronous(try SwiftAsyncCall(signature: signature, trailingType: trailingType,
                consumesArguments: consumesArguments, errorPlan: errorPlan,
                inheritsCallerIsolation: description.inheritsCallerIsolation,
                opaqueResult: opaque, generic: generic), try SwiftAsyncImplementation(symbol: symbol, resolver: resolver))
        } else {
            self = .synchronous(try SwiftCall(signature: signature, trailingType: trailingType,
                consumesArguments: consumesArguments, errorPlan: errorPlan, opaqueResult: opaque, generic: generic))
        }
    }

    var errorPlan: SwiftErrorPlan? {
        switch self {
        case .synchronous(let call): call.errorPlan
        case .asynchronous(let call, _): call.errorPlan
        }
    }
}

/// Shares value preparation between synchronous and asynchronous transports.
/// The containing signature establishes the types used by typed invocation.
struct SwiftCallValues: Sendable {
    struct Argument: Sendable {
        let type: CValueType
        let consumes: Bool
        let encode: @Sendable (UnsafeRawPointer, Any?) throws -> NativeValueStorage
    }
    struct Result: Sendable {
        let type: CValueType
        let makeStorage: @Sendable () -> NativeValueStorage
        let initialize: @Sendable (NativeValueStorage, Any?, Any?, UnsafeMutableRawPointer) throws -> Void
    }
    let arguments: [Argument]
    let result: Result

    init(signature: SwiftFunctionSignature, consumesArguments: Bool,
         opaqueResult: SwiftOpaqueResultPlan?, arguments argumentPlans: [SwiftGenericArgument] = [],
         result resultPlan: SwiftGenericResult = .concrete) throws {
        arguments = try signature.parameters.enumerated().map { index, type in
            func prepare<Value>(_ type: Value.Type) throws -> Argument {
                let codec = try SwiftArgumentCodec<Value>(defaultConsuming: consumesArguments,
                    generic: argumentPlans.isEmpty ? .concrete : argumentPlans[index])
                return Argument(type: codec.type, consumes: codec.consumes,
                    encode: { try codec.encode($0.load(as: Value.self), retainingCode: $1) })
            }
            return try _openExistential(type, do: prepare)
        }
        func prepareResult<Value>(_ type: Value.Type) throws -> Result {
            let codec = try SwiftResultCodec<Value>(opaque: opaqueResult, generic: resultPlan)
            return Result(type: codec.type, makeStorage: { codec.makeStorage() },
                initialize: { storage, owner, codeOwner, output in
                    let value = try codec.decode(storage, retaining: owner, retainingCode: codeOwner)
                    output.initializeMemory(as: Value.self, repeating: value, count: 1)
                })
        }
        result = try _openExistential(signature.result, do: prepareResult)
    }

    func encode<each Argument>(_ values: repeat each Argument, retainingCode owner: Any?) throws -> [NativeValueStorage] {
        var storage: [NativeValueStorage] = []
        storage.reserveCapacity(arguments.count)
        var index = 0
        for value in repeat each values {
            storage.append(try withUnsafePointer(to: value) { try arguments[index].encode($0, owner) })
            index += 1
        }
        return storage
    }

    func decode<Output>(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any?) throws -> Output {
        try withUnsafeTemporaryAllocation(of: Output.self, capacity: 1) { buffer in
            try result.initialize(storage, owner, codeOwner, buffer.baseAddress!)
            return buffer.baseAddress!.move()
        }
    }

    func relinquishConsumed(_ storage: [NativeValueStorage]) {
        for (argument, value) in zip(arguments, storage) where argument.consumes { value.relinquishValue() }
    }
}

// Native function parameters can contain stack closure contexts. Their handles
// borrow the entry frame; resolving them is a throwing invocation operation.
final class SwiftCallbackScope {
    private var borrows: [SwiftValueBorrow] = []
    private var storage: [NativeValueStorage] = []
    private var writebacks: [() -> Void] = []
    private let asynchronous: Bool
    init(asynchronous: Bool) { self.asynchronous = asynchronous }
    func writeback(_ body: @escaping () -> Void) { writebacks.append(body) }
    func borrow(_ address: UnsafeRawPointer, retaining storage: NativeValueStorage? = nil,
                allowsSuspension: Bool? = nil) -> SwiftValueBorrow {
        if let storage { self.storage.append(storage) }
        let borrow = SwiftValueBorrow(address, allowsSuspension: allowsSuspension ?? asynchronous)
        borrows.append(borrow)
        return borrow
    }
    deinit {
        for writeback in writebacks { writeback() }
        for borrow in borrows { borrow.expire() }
        withExtendedLifetime(storage) {}
    }
}

typealias SwiftCallbackDecoder = @Sendable (UnsafeMutableRawPointer, SwiftCallbackScope) -> Any

struct SwiftCallbackValues: Sendable {
    private let closures: [(@Sendable (UnsafeMutableRawPointer, SwiftCallbackScope) -> Any)?]
    private let constants: [SwiftValueConstants]
    private let needsScope: Bool

    init(_ signature: SwiftFunctionSignature, arguments: [SwiftGenericArgument] = []) throws {
        needsScope = signature.parameters.contains { $0 is any SwiftClosureValue.Type || $0 is any SwiftConventionArgument.Type }
        constants = signature.parameters.map(SwiftValueConstants.init)
        closures = try signature.parameters.enumerated().map { index, type in
            let argument: SwiftGenericArgument = arguments.isEmpty ? .concrete : arguments[index]
            if let convention = type as? any SwiftConventionArgument.Type {
                let codec: SwiftConventionCodec
                if case .convention(let prepared) = argument { codec = prepared }
                else if case .value = argument { return nil }
                else { codec = try convention.makeArgumentCodec(generic: argument) }
                return try codec.prepareCallback()
            }
            if let closure = type as? any SwiftClosureValue.Type {
                let codec: SwiftClosureCodec
                if !arguments.isEmpty, case .closure(let plan) = arguments[index] {
                    codec = try (closure as! any SwiftGenericClosureValue.Type).makeGenericClosureCodec(plan: plan)
                } else { codec = try closure.makeClosureCodec() }
                guard let borrow = codec.borrowValue else {
                    throw ABIResolutionError.unsupportedDeclaration("This closure representation cannot borrow native callback inputs.")
                }
                return { borrow($1.borrow($0), SwiftValueCodeLifetime.current) }
            }
            return nil
        }
    }

    static func decoder<Value>(for type: Value.Type, generic: SwiftGenericArgument,
                               consuming: Bool) throws -> SwiftCallbackDecoder {
        if case .runtimeValue(let plan, _, let asynchronous) = generic {
            if Value.self == NativeSwiftValue.self {
                try plan.requireOwnedValue()
                if !consuming, !SwiftCopyability.accepts(plan.valueType.metadata) { throw NativeSwiftValueError.noncopyableType }
            }
            return { address, scope in
                let lifetime = SwiftValueCodeLifetime.current ?? plan.valueType.codeLifetime
                SwiftValueCodeLifetime.connect([lifetime, plan.valueType.codeLifetime], retaining: [])
                let nativeType = plan.valueType.retainingCode(lifetime)
                if consuming { return plan.takeCallbackArgument(from: address, type: nativeType) }
                let restored = plan.restoredCallbackArgument(from: address)
                let source = restored?.address ?? address
                if Value.self == NativeSwiftBorrowedValue.self {
                    return NativeSwiftBorrowedValue(type: nativeType,
                        borrow: scope.borrow(source, retaining: restored, allowsSuspension: asynchronous))
                }
                return plan.copyCallbackArgument(from: source, type: nativeType)
            }
        }
        if let closure = Value.self as? any SwiftClosureValue.Type {
            let codec: SwiftClosureCodec
            if case .closure(let plan) = generic { codec = try (closure as! any SwiftGenericClosureValue.Type).makeGenericClosureCodec(plan: plan) }
            else { codec = try closure.makeClosureCodec() }
            if consuming {
                guard let take = codec.takeValue else {
                    throw ABIResolutionError.unsupportedDeclaration("This closure representation cannot own native callback inputs.")
                }
                return { address, _ in take(address.load(as: ABISwiftClosureValue.self), SwiftValueCodeLifetime.current) }
            }
            guard let borrow = codec.borrowValue else {
                throw ABIResolutionError.unsupportedDeclaration("This closure representation cannot borrow native callback inputs.")
            }
            return { borrow($1.borrow($0), SwiftValueCodeLifetime.current) }
        }
        let constants = SwiftValueConstants(Value.self)
        return { address, _ in
            if consuming {
                constants.initialize(at: address)
                return address.assumingMemoryBound(to: Value.self).move()
            }
            return constants.load(from: address, as: Value.self)
        }
    }

    func makeScope(asynchronous: Bool) -> SwiftCallbackScope? {
        needsScope ? SwiftCallbackScope(asynchronous: asynchronous) : nil
    }

    func decode<Value>(_ address: UnsafeMutableRawPointer, at index: Int, scope: SwiftCallbackScope?, as type: Value.Type) -> Value {
        if let closure = closures[index] { return closure(address, scope!) as! Value }
        return constants[index].load(from: address, as: type)
    }
}

struct SwiftCallbackResult<Value>: Sendable {
    private let closure: Bool
    private let encode: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
    init(failure: Any.Type, generic: SwiftGenericResult = .concrete) throws {
        if case .closure(let codec) = generic { encode = codec.encodeValue } else { encode = nil }
        closure = Value.self is any SwiftClosureValue.Type
        if closure && failure != (any Error).self {
            throw ABIResolutionError.unsupportedDeclaration("A host callback returning a closure requires throws(any Error) to report ownership and conversion failures.")
        }
    }
    func initialize(_ value: Value, at output: UnsafeMutableRawPointer) throws {
        guard closure else { output.initializeMemory(as: Value.self, repeating: value, count: 1); return }
        let encoded = try encode?(value, nil) ?? (value as! any SwiftClosureValue).encodeClosureResult()
        output.copyMemory(from: encoded.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
        SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current, encoded.codeLifetime].compactMap { $0 }, retaining: [])
        encoded.relinquishValue()
    }
}
