import ABIBridgeCore

/// The function metadata's formal types and effects, before declaration-level lowering.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
struct SwiftFunctionMetadata: Sendable {
    let flags: UInt
    let parameters: [Any.Type]
    let result: Any.Type
    let failure: Any.Type
    let parameterFlags: [UInt32]
    let attributes: SwiftFunctionAttributes
    let globalActor: Any.Type?
    let extendedFlags: UInt32

    init(_ type: Any.Type) throws {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x302 else {
            throw ABIResolutionError.unsupportedDeclaration("Expected a Swift function type: \(String(reflecting: type)).")
        }
        flags = metadata.load(fromByteOffset: word, as: UInt.self)
        let count = Int(flags & 0xffff)
        result = metadata.load(fromByteOffset: 2 * word, as: Any.Type.self)
        parameters = (0..<count).map { metadata.load(fromByteOffset: (3 + $0) * word, as: Any.Type.self) }
        var offset = (3 + count) * word
        parameterFlags = flags & 0x02000000 != 0
            ? (0..<count).map { metadata.load(fromByteOffset: offset + $0 * 4, as: UInt32.self) }
            : Array(repeating: 0, count: count)
        if flags & 0x02000000 != 0 { offset += count * 4 }
        func alignToWord() { offset = (offset + word - 1) & ~(word - 1) }
        alignToWord()
        let differentiability = flags & 0x08000000 != 0 ? metadata.load(fromByteOffset: offset, as: UInt.self) : 0
        if flags & 0x08000000 != 0 { offset += word }
        globalActor = flags & 0x10000000 != 0 ? metadata.load(fromByteOffset: offset, as: Any.Type.self) : nil
        if flags & 0x10000000 != 0 { offset += word }
        let extended = flags & 0x80000000 != 0 ? metadata.load(fromByteOffset: offset, as: UInt32.self) : 0
        extendedFlags = extended
        if flags & 0x80000000 != 0 { offset += 4 }
        alignToWord()
        if extended & 1 != 0 {
            failure = metadata.load(fromByteOffset: offset, as: Any.Type.self)
        } else {
            failure = flags & 0x01000000 != 0 ? (any Error).self : Never.self
        }
        guard let isolation = SwiftFunctionAttributes.Isolation(rawValue: extended & 0x0e),
              let differentiation = SwiftFunctionAttributes.Differentiability(rawValue: differentiability) else {
            throw ABIResolutionError.metadataUnavailable("The function metadata has an unknown effect convention.")
        }
        attributes = SwiftFunctionAttributes(isAsync: flags & 0x20000000 != 0,
            isEscaping: flags & 0x04000000 != 0, isSendable: flags & 0x40000000 != 0,
            isolation: isolation,
            differentiability: differentiation, hasSendingResult: extended & 0x10 != 0,
            parameterFlags: parameterFlags.map { $0 & ~7 })
    }
}

struct SwiftFunctionSignature: Sendable {
    private let metadata: SwiftFunctionMetadata
    var parameters: [Any.Type] { metadata.parameters }
    var result: Any.Type { metadata.result }
    var failure: Any.Type { metadata.failure }
    var isAsync: Bool { metadata.attributes.isAsync }
    var inheritsCallerIsolation: Bool { metadata.attributes.isolation == .caller }
    let parameterConventions: [SwiftArgumentConvention]

    init(_ type: Any.Type, nativeConventions: Bool = false) throws {
        let metadata = try SwiftFunctionMetadata(type)
        guard metadata.flags & 0x00ff0000 == 0 else {
            throw ABIResolutionError.unsupportedDeclaration("Expected the native Swift function convention.")
        }
        guard nativeConventions || metadata.parameterFlags.allSatisfy({ $0 == 0 }) else {
            throw ABIResolutionError.unsupportedDeclaration("Use explicit Swift argument wrappers for parameter conventions.")
        }
        parameterConventions = try metadata.parameterFlags.map {
            switch $0 & 7 {
            case 0, 2: return .borrowing
            case 1: return .inoutValue
            case 3: return .consuming
            default: throw ABIResolutionError.unsupportedDeclaration("The native function parameter uses an unsupported ownership convention.")
            }
        }
        guard metadata.attributes.differentiability == .none, metadata.globalActor == nil else {
            throw ABIResolutionError.unsupportedDeclaration("Differentiable and global-actor function types require their native invocation conventions.")
        }
        guard metadata.attributes.isolation != .isolatedAny else {
            throw ABIResolutionError.unsupportedDeclaration("An isolated-any function requires a dynamic isolation context.")
        }
        self.metadata = metadata
    }

    func makeErrorPlan(genericType: CValueType? = nil) throws -> SwiftErrorPlan? {
        if failure == Never.self && genericType == nil { return nil }
        if failure == (any Error).self { return try SwiftErrorPlan.make((any Error).self, genericType: genericType) }
        guard let error = failure as? any Error.Type else {
            throw ABIResolutionError.unsupportedDeclaration("The function's thrown type does not conform to Error.")
        }
        return try SwiftErrorPlan.make(error, genericType: genericType)
    }

    var requiresValueDeclaration: Bool {
        func needsDeclaration(_ type: Any.Type) -> Bool {
            if type is any SwiftClosureValue.Type || type == NativeSwiftValue.self || type == NativeSwiftBorrowedValue.self { return true }
            if let convention = type as? any SwiftConventionArgument.Type { return needsDeclaration(convention.wrappedType) }
            if let tuple = SwiftTupleMetadata(type) { return tuple.elements.contains { needsDeclaration($0.type) } }
            return false
        }
        return (parameters + [result]).contains(where: needsDeclaration)
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

    var generic: SwiftGenericCallPlan? {
        switch self {
        case .synchronous(let call): call.generic
        case .asynchronous(let call, _): call.generic
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
                let argument = argumentPlans.isEmpty ? .concrete : argumentPlans[index]
                let consuming: Bool
                // Initializers consume escaping closure arguments, but their
                // nonescaping closure parameters are guaranteed borrows.
                if case .closure(let plan, _) = argument { consuming = consumesArguments && plan.isEscaping }
                else { consuming = consumesArguments }
                let codec = try SwiftArgumentCodec<Value>(defaultConsuming: consuming,
                    generic: argument, asynchronous: signature.isAsync)
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

    func finishInvocation<Output>(_ outcome: Swift.Result<Output, any Error>,
                                  storage: [NativeValueStorage]) throws -> Output {
        try finishSwiftInvocation(outcome) {
            let commits = try storage.compactMap(\.prepareWriteback).map { try $0() }
            for commit in commits { commit() }
        }
    }
}

// Native function parameters can contain stack closure contexts. Their handles
// borrow the entry frame; resolving them is a throwing invocation operation.
final class SwiftCallbackScope {
    private var borrows: [SwiftValueBorrow] = []
    private var storage: [NativeValueStorage] = []
    private var writebacks: [SwiftWritebackPreparation] = []
    private var pendingInputs: [Int: () -> Void] = [:]
    private let asynchronous: Bool
    init(asynchronous: Bool) { self.asynchronous = asynchronous }
    var hasWritebacks: Bool { !writebacks.isEmpty }
    func retainInput(at index: Int, cleanup: @escaping () -> Void) { pendingInputs[index] = cleanup }
    func claimInput(at index: Int) { pendingInputs.removeValue(forKey: index) }
    func prepareWriteback(_ body: @escaping SwiftWritebackPreparation) { writebacks.append(body) }
    func finishInvocation<Output>(_ outcome: Result<Output, any Error>) throws -> Output {
        try finishSwiftInvocation(outcome) {
            let commits = try writebacks.map { try $0() }
            for commit in commits { commit() }
        }
    }
    func borrow(_ address: UnsafeRawPointer, retaining storage: NativeValueStorage? = nil,
                allowsSuspension: Bool? = nil, allowsMutation: Bool = false) -> SwiftValueBorrow {
        if let storage { self.storage.append(storage) }
        let borrow = SwiftValueBorrow(address, allowsSuspension: allowsSuspension ?? asynchronous, allowsMutation: allowsMutation)
        borrows.append(borrow)
        return borrow
    }
    deinit {
        for cleanup in pendingInputs.values { cleanup() }
        for borrow in borrows { borrow.expire() }
        withExtendedLifetime(storage) {}
    }
}

typealias SwiftCallbackDecoder = @Sendable (UnsafeMutableRawPointer, SwiftCallbackScope) throws -> Any

struct SwiftCallbackValues: Sendable {
    private let decoders: [SwiftCallbackDecoder?]
    private let constants: [SwiftValueConstants]
    private let needsScope: Bool
    private let inputDestructors: [(@Sendable (UnsafeMutableRawPointer) -> Void)?]

    init(_ signature: SwiftFunctionSignature, arguments: [SwiftGenericArgument] = [], consumingArguments: [Bool]? = nil) throws {
        let arguments = try arguments.isEmpty ? SwiftGenericParameters.concreteArguments(signature: signature) : arguments
        let consuming = consumingArguments ?? arguments.map { $0.convention == .consuming }
        constants = zip(signature.parameters, arguments).map { type, argument in
            if case .value = argument { return SwiftValueConstants(Void.self) }
            return SwiftValueConstants(type)
        }
        decoders = try signature.parameters.enumerated().map { index, type in
            let argument: SwiftGenericArgument = arguments.isEmpty ? .concrete : arguments[index]
            if case .value = argument {
                guard consuming[index] else { return nil }
                func prepare<Value>(_ type: Value.Type) throws -> SwiftCallbackDecoder {
                    try Self.decoder(for: type, generic: argument, consuming: true)
                }
                return try _openExistential(type, do: prepare)
            }
            if case .tuple(let tuple, _, _) = argument { return try tuple.callbackDecoder(consuming: consuming[index]) }
            if case .runtimeValue = argument {
                if type == NativeSwiftBorrowedValue.self {
                    return try Self.decoder(for: NativeSwiftBorrowedValue.self, generic: argument, consuming: false)
                }
                return try Self.decoder(for: NativeSwiftValue.self, generic: argument, consuming: consuming[index])
            }
            if let convention = type as? any SwiftConventionArgument.Type {
                let codec: SwiftConventionCodec
                if case .convention(let prepared) = argument { codec = prepared }
                else { codec = try convention.makeArgumentCodec(generic: argument) }
                return try codec.prepareCallback(signature.failure)
            }
            if let closure = type as? any SwiftClosureValue.Type {
                let codec: SwiftClosureCodec
                if !arguments.isEmpty, case .closure(let plan, _) = arguments[index] {
                    codec = try closure.makeGenericClosureCodec(plan: plan)
                } else { codec = try closure.makeClosureCodec() }
                if consuming[index] {
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
            if consuming[index] {
                func prepare<Value>(_ type: Value.Type) throws -> SwiftCallbackDecoder {
                    try Self.decoder(for: type, generic: argument, consuming: true)
                }
                return try _openExistential(type, do: prepare)
            }
            if type is any ABIBridgeValue.Type, !(type is any ABIBridgeSwiftValue.Type) {
                func prepare<Value>(_ type: Value.Type) throws -> SwiftCallbackDecoder {
                    let codec = try SwiftValueCodec<Value>()
                    return { address, scope in
                        let value = NativeValueStorage(borrowing: address, owner: scope)
                        return try codec.copy(from: value, retaining: value)
                    }
                }
                return try _openExistential(type, do: prepare)
            }
            return nil
        }
        inputDestructors = zip(signature.parameters, arguments).enumerated().map { index, pair in
            guard consuming[index] else { return nil }
            return Self.inputDestructor(pair.0, argument: pair.1)
        }
        needsScope = decoders.contains { $0 != nil } || inputDestructors.contains { $0 != nil }
    }

    private static func inputDestructor(_ host: Any.Type, argument: SwiftGenericArgument) -> @Sendable (UnsafeMutableRawPointer) -> Void {
        if case .convention(let codec) = argument {
            return inputDestructor((host as! any SwiftConventionArgument.Type).wrappedType, argument: codec.argument)
        }
        if let tuple = argument.tuple {
            let fields = tuple.leaves.map { ($0.nativeType, SwiftValueConstants($0.nativeType)) }
            return { vector in
                let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                for (index, field) in fields.enumerated() {
                    field.1.initialize(at: addresses[index]!)
                    ABISwiftDestroyValue(unsafeBitCast(field.0, to: UnsafeRawPointer.self), addresses[index]!)
                }
            }
        }
        let nativeClosure: Bool
        if case .value = argument { nativeClosure = false }
        else { nativeClosure = argument.closure != nil || host is any SwiftClosureValue.Type }
        if nativeClosure {
            return { ABIReleaseSwiftClosureContext($0.load(as: ABISwiftClosureValue.self).context) }
        }
        let metadata = argument.runtimeValue?.valueType.metadata ?? host
        let constants = SwiftValueConstants(metadata)
        return {
            constants.initialize(at: $0)
            ABISwiftDestroyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), $0)
        }
    }

    static func decoder<Value>(for type: Value.Type, generic: SwiftGenericArgument,
                               consuming: Bool) throws -> SwiftCallbackDecoder {
        if case .tuple(let tuple, _, _) = generic { return try tuple.callbackDecoder(consuming: consuming) }
        if case .runtimeValue(let plan, let convention, let asynchronous) = generic {
            if Value.self == NativeSwiftValue.self {
                try plan.requireOwnedValue()
                if !consuming, !SwiftCopyability.accepts(plan.valueType.metadata) { throw NativeSwiftValueError.noncopyableType }
            }
            return { address, scope in
                let lifetime = SwiftValueCodeLifetime.current ?? plan.valueType.codeLifetime
                SwiftValueCodeLifetime.connect([lifetime, plan.valueType.codeLifetime], retaining: [])
                let nativeType = plan.valueType
                if let tuple = plan.nativeTuple, convention != .inoutValue {
                    let materialized = tuple.materializeArgument(from: address, consuming: consuming)
                    if consuming {
                        let value = plan.takeCallbackArgument(from: materialized.address, type: nativeType)
                        materialized.relinquishValue()
                        return value
                    }
                    plan.normalizeCallbackArgument(materialized)
                    if Value.self == NativeSwiftBorrowedValue.self {
                        return NativeSwiftBorrowedValue(type: nativeType,
                            borrow: scope.borrow(materialized.address, retaining: materialized,
                                allowsSuspension: asynchronous))
                    }
                    return NativeSwiftValue(storage: materialized, type: nativeType)
                }
                if consuming { return plan.takeCallbackArgument(from: address, type: nativeType) }
                let restored = convention == .inoutValue ? nil : plan.restoredCallbackArgument(from: address)
                let source = convention == .inoutValue
                    ? address.load(as: UnsafeMutableRawPointer.self) : restored?.address ?? address
                if Value.self == NativeSwiftBorrowedValue.self {
                    if plan.hasClosureConversions {
                        let canonical = plan.copyCallbackStorage(from: source, type: nativeType)
                        if convention == .inoutValue {
                            scope.prepareWriteback {
                                plan.prepareCallbackWriteback(from: canonical, to: source)
                            }
                        }
                        return NativeSwiftBorrowedValue(type: nativeType,
                            borrow: scope.borrow(canonical.address, retaining: canonical,
                                allowsSuspension: asynchronous, allowsMutation: convention == .inoutValue))
                    }
                    return NativeSwiftBorrowedValue(type: nativeType,
                        borrow: scope.borrow(source, retaining: restored, allowsSuspension: asynchronous,
                            allowsMutation: convention == .inoutValue))
                }
                return plan.copyCallbackArgument(from: source, type: nativeType)
            }
        }
        let usesSwiftStorage = if case .value = generic { true } else { false }
        if !usesSwiftStorage, let closure = Value.self as? any SwiftClosureValue.Type {
            let codec: SwiftClosureCodec
            if case .closure(let plan, _) = generic { codec = try closure.makeGenericClosureCodec(plan: plan) }
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
        let constants = SwiftValueConstants(usesSwiftStorage ? Void.self : Value.self)
        return { address, _ in
            if consuming {
                constants.initialize(at: address)
                return address.assumingMemoryBound(to: Value.self).move()
            }
            return constants.load(from: address, as: Value.self)
        }
    }

    func makeScope(asynchronous: Bool, arguments: UnsafePointer<UnsafeMutableRawPointer?>?) -> SwiftCallbackScope? {
        guard needsScope else { return nil }
        let scope = SwiftCallbackScope(asynchronous: asynchronous)
        for (index, destroy) in inputDestructors.enumerated() {
            if let destroy, let address = arguments?[index] { scope.retainInput(at: index) { destroy(address) } }
        }
        return scope
    }

    func decode<Value>(_ address: UnsafeMutableRawPointer, at index: Int, scope: SwiftCallbackScope?, as type: Value.Type) throws -> Value {
        scope?.claimInput(at: index)
        if let decode = decoders[index] { return try decode(address, scope!) as! Value }
        return constants[index].load(from: address, as: type)
    }
}

struct SwiftCallbackResult<Value>: Sendable {
    let initializeNativeResult: SwiftResultInitializer
    private let closure: Bool
    private let encode: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
    private let runtimeValue: SwiftRuntimeValuePlan?
    private let tuple: SwiftTupleValuePlan?
    private let ordinary: SwiftValueCodec<Value>?
    init(failure: Any.Type, generic: SwiftGenericResult = .concrete) throws {
        if case .tuple(let tuple) = generic { self.tuple = tuple }
        else if case .concrete = generic { tuple = try SwiftGenericCallPlan.concreteTuple(Value.self) }
        else { tuple = nil }
        try tuple?.validateOwnedResult()
        if case .concrete = generic, tuple?.needsConversion != true, !(Value.self is any SwiftClosureValue.Type) {
            ordinary = try SwiftValueCodec<Value>()
        } else { ordinary = nil }
        initializeNativeResult = ordinary?.initializeNativeResult ?? swiftResultInitializer(nativeMetadata: Value.self, generic: generic, tuple: tuple)
        if case .runtimeValue(let plan) = generic {
            try plan.requireOwnedValue(as: Value.self)
            runtimeValue = plan
        } else { runtimeValue = nil }
        if case .closure(let codec) = generic { encode = codec.encodeValue } else { encode = nil }
        if case .value = generic { closure = false }
        else { closure = Value.self is any SwiftClosureValue.Type }
        if (closure || runtimeValue != nil || tuple?.needsConversion == true) && failure != (any Error).self {
            throw ABIResolutionError.unsupportedDeclaration("A host callback returning a converted value requires throws(any Error) to report ownership and conversion failures.")
        }
    }

    func prepare(_ value: Value) throws -> (UnsafeMutableRawPointer) -> Void {
        if let ordinary {
            let storage = try ordinary.encode(value)
            return { output in
                ordinary.initializeNativeResult(0, ordinary.type.size, output, storage.address)
                storage.relinquishValue()
            }
        }
        if let tuple, tuple.needsConversion {
            return try withUnsafePointer(to: value) { try tuple.prepareResult(fromHost: $0) }
        }
        if let runtimeValue {
            let source = try runtimeValue.encode(value, convention: .consuming, asynchronous: false)
            SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current, source.codeLifetime].compactMap { $0 }, retaining: [])
            return { output in
                ABISwiftTakeValue(unsafeBitCast(runtimeValue.valueType.metadata, to: UnsafeRawPointer.self), output, source.address)
                source.relinquishValue()
            }
        }
        if closure {
            let encoded = try encode?(value, nil) ?? (value as! any SwiftClosureValue).encodeClosureResult()
            SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current, encoded.codeLifetime].compactMap { $0 }, retaining: [])
            return { output in
                output.copyMemory(from: encoded.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
                encoded.relinquishValue()
            }
        }
        let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
        storage.initialize(value)
        return { output in
            ABISwiftTakeValue(unsafeBitCast(Value.self, to: UnsafeRawPointer.self), output, storage.address)
            storage.relinquishValue()
        }
    }
    func initialize(_ value: Value, at output: UnsafeMutableRawPointer) throws {
        if ordinary != nil || runtimeValue != nil || tuple?.needsConversion == true { try prepare(value)(output); return }
        guard closure else { output.initializeMemory(as: Value.self, repeating: value, count: 1); return }
        let encoded = try encode?(value, nil) ?? (value as! any SwiftClosureValue).encodeClosureResult()
        output.copyMemory(from: encoded.address, byteCount: MemoryLayout<ABISwiftClosureValue>.size)
        SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current, encoded.codeLifetime].compactMap { $0 }, retaining: [])
        encoded.relinquishValue()
    }
}
