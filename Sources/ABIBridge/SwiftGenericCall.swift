import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
    indirect case convention(SwiftConventionCodec)
    case value(CValueType, consuming: Bool)
    case closure(SwiftGenericClosurePlan, asynchronous: Bool = false)
    case runtimeValue(SwiftRuntimeValuePlan, convention: SwiftArgumentConvention, asynchronous: Bool)
    case tuple(SwiftTupleValuePlan, consuming: Bool = false, asynchronous: Bool = false)

    var tuple: SwiftTupleValuePlan? {
        switch self {
        case .tuple(let plan, _, _): plan
        case .runtimeValue(let plan, _, _): plan.nativeTuple
        case .convention(let codec): codec.argument.tuple
        default: nil
        }
    }

    var closure: SwiftGenericClosurePlan? {
        switch self {
        case .closure(let plan, _): plan
        case .runtimeValue(let plan, _, _): plan.nativeClosure
        case .convention(let codec): codec.argument.closure
        default: nil
        }
    }

    var runtimeValue: SwiftRuntimeValuePlan? {
        switch self {
        case .runtimeValue(let plan, _, _): plan
        case .convention(let codec): codec.argument.runtimeValue
        default: nil
        }
    }

    var convention: SwiftArgumentConvention {
        switch self {
        case .convention(let codec): codec.convention
        case .runtimeValue(_, let convention, _): convention
        case .value(_, let consuming): consuming ? .consuming : .borrowing
        case .tuple(_, let consuming, _): consuming ? .consuming : .borrowing
        default: .borrowing
        }
    }
}


enum SwiftGenericResult: Sendable {
    case concrete
    case value(CValueType)
    case closure(SwiftClosureCodec)
    case runtimeValue(SwiftRuntimeValuePlan)
    case tuple(SwiftTupleValuePlan)

    var closure: SwiftGenericClosurePlan? {
        switch self {
        case .closure(let codec): codec.nativePlan
        case .runtimeValue(let plan): plan.nativeClosure
        default: nil
        }
    }

    var tuple: SwiftTupleValuePlan? {
        switch self {
        case .tuple(let plan): plan
        case .runtimeValue(let plan): plan.nativeTuple
        default: nil
        }
    }

    var type: CValueType? {
        switch self {
        case .concrete: nil
        case .value(let type): type
        case .closure(let codec): codec.type
        case .runtimeValue(let plan): plan.type
        case .tuple(let plan): plan.type
        }
    }
}

final class SwiftCallbackArguments {
    let addresses: [UnsafeMutableRawPointer?]
    private let storage: [NativeValueStorage]
    private let borrows: [SwiftValueBorrow]

    init(addresses: [UnsafeMutableRawPointer?], storage: [NativeValueStorage], borrows: [SwiftValueBorrow]) {
        self.addresses = addresses
        self.storage = storage
        self.borrows = borrows
    }

    deinit {
        for borrow in borrows { borrow.expire() }
        withExtendedLifetime(storage) {}
    }
}

struct SwiftCallbackRuntimeArgument: Sendable {
    let plan: SwiftRuntimeValuePlan
    let borrowed: Bool
    let asynchronous: Bool
    let convention: SwiftArgumentConvention
}

final class SwiftGenericClosurePlan: Sendable {
    enum Transport: Sendable {
        case synchronous(SwiftCallInterface)
        case asynchronous(SwiftAsyncCallInterface, inheritsCallerIsolation: Bool)
    }
    let transport: Transport
    let parameters: SwiftGenericParameters
    let discriminator: UInt16
    let authentication: String
    let isEscaping: Bool
    let resultConstants: SwiftValueConstants
    let errorPlan: SwiftErrorPlan?
    let runtimeArguments: [SwiftCallbackRuntimeArgument?]
    let result: SwiftGenericResult
    let nativeResult: Any.Type
    let nativeParameters: [Any.Type]
    let nativeParameterTypes: [ObjectIdentifier]
    let nativeArgumentClosures: [SwiftGenericClosurePlan?]
    let nativeResultClosure: SwiftGenericClosurePlan?

    init(transport: Transport, parameters: SwiftGenericParameters, discriminator: UInt16,
         authentication: String, isEscaping: Bool, resultConstants: SwiftValueConstants,
         errorPlan: SwiftErrorPlan?, runtimeArguments: [SwiftCallbackRuntimeArgument?],
         result: SwiftGenericResult, nativeResult: Any.Type, hostParameters: [Any.Type],
         nativeParameters: [Any.Type]? = nil,
         nativeArgumentClosures: [SwiftGenericClosurePlan?]? = nil,
         nativeResultClosure: SwiftGenericClosurePlan? = nil) {
        self.transport = transport; self.parameters = parameters; self.discriminator = discriminator
        self.authentication = authentication; self.isEscaping = isEscaping; self.resultConstants = resultConstants
        self.errorPlan = errorPlan; self.runtimeArguments = runtimeArguments; self.result = result; self.nativeResult = nativeResult
        self.nativeParameters = nativeParameters ?? zip(hostParameters, parameters.arguments).map { host, argument in
            argument.tuple?.nativeMetadata ?? argument.runtimeValue?.valueType.metadata
                ?? (host as? any SwiftConventionArgument.Type)?.wrappedType ?? host
        }
        nativeParameterTypes = self.nativeParameters.map(ObjectIdentifier.init)
        self.nativeArgumentClosures = nativeArgumentClosures ?? parameters.arguments.map(\.closure)
        self.nativeResultClosure = nativeResultClosure ?? result.closure
    }

    var hasNestedClosures: Bool {
        if nativeResultClosure != nil || result.tuple?.hasNestedClosures == true { return true }
        return nativeArgumentClosures.contains { $0 != nil }
            || parameters.arguments.contains { $0.tuple?.hasNestedClosures == true }
    }

    var hasTuples: Bool {
        if result.tuple != nil { return true }
        return parameters.arguments.contains { $0.tuple != nil }
    }

    static func concrete(_ type: Any.Type) throws -> SwiftGenericClosurePlan {
        let signature = try SwiftFunctionSignature(type)
        func argument(_ type: Any.Type) throws -> SwiftGenericArgument {
            if let convention = type as? any SwiftConventionArgument.Type {
                return .convention(try convention.makeArgumentCodec(generic: argument(convention.wrappedType)))
            }
            if let tuple = try SwiftGenericCallPlan.concreteTuple(type) {
                return .tuple(tuple, asynchronous: signature.isAsync)
            }
            if let closure = type as? any SwiftClosureValue.Type {
                return .closure(try concrete(closure.swiftFunctionType), asynchronous: signature.isAsync)
            }
            return .concrete
        }
        let arguments = try signature.parameters.map(argument)
        let parameterPlan = SwiftGenericParameters(actual: signature.parameters, arguments: arguments)
        let logicalTypes = try zip(signature.parameters, arguments).map { type, argument in
            func layout<Value>(_ type: Value.Type) throws -> CValueType {
                try SwiftArgumentCodec<Value>(defaultConsuming: false, generic: argument).type
            }
            return try _openExistential(type, do: layout)
        }
        let result: SwiftGenericResult
        if let tuple = try SwiftGenericCallPlan.concreteTuple(signature.result) {
            result = .tuple(tuple)
        } else if let closure = signature.result as? any SwiftClosureValue.Type {
            result = .closure(try closure.makeGenericClosureCodec(plan: concrete(closure.swiftFunctionType)))
        } else {
            func layout<Value>(_ type: Value.Type) throws -> CValueType { try SwiftValueCodec<Value>().type }
            result = .value(try _openExistential(signature.result, do: layout))
        }
        let nativeResult = try SwiftGenericCallPlan.concreteNativeMetadata(signature.result)
        let nativeParameters = try signature.parameters.map {
            try SwiftGenericCallPlan.concreteNativeMetadata(($0 as? any SwiftConventionArgument.Type)?.wrappedType ?? $0)
        }
        let resultType = result.type!
        let types = parameterPlan.types(from: logicalTypes)
        let errorPlan = try signature.makeErrorPlan()
        let transport: Transport = signature.isAsync
            ? .asynchronous(try SwiftAsyncCallInterface(result: resultType, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: signature.inheritsCallerIsolation),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            : .synchronous(try SwiftCallInterface.cached(result: resultType, parameters: types, errorPlan: errorPlan))
        return SwiftGenericClosurePlan(transport: transport, parameters: parameterPlan,
            discriminator: try signature.closureDiscriminator(), authentication: try signature.closureAuthDescription(),
            isEscaping: false, resultConstants: SwiftValueConstants(nativeResult), errorPlan: errorPlan,
            runtimeArguments: Array(repeating: nil, count: arguments.count), result: result,
            nativeResult: nativeResult, hostParameters: signature.parameters, nativeParameters: nativeParameters)
    }

    // Copying opaque generic data does not require the bridge to invoke it.
    // A callable plan is optional until a function boundary needs reabstraction.
    static func closureInStoredValue(_ type: Any.Type) -> SwiftGenericClosurePlan? {
        guard unsafeBitCast(type, to: UnsafeRawPointer.self).load(as: UInt.self) == 0x302 else { return nil }
        return try? nativeValue(type)
    }

    // A function stored inside an erased native value has the maximally
    // abstracted Swift convention: each value, including a tuple or Void
    // result, occupies one indirect slot. Nested functions retain that same
    // storage convention until a formal function boundary reabstracts them.
    static func nativeValue(_ type: Any.Type) throws -> SwiftGenericClosurePlan {
        let signature = try SwiftFunctionSignature(type, nativeConventions: true)
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let escaping = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: UInt.self) & 0x04000000 != 0
        var arguments: [SwiftGenericArgument] = [], types: [CValueType] = []
        var nativeClosures: [SwiftGenericClosurePlan?] = []
        for (type, convention) in zip(signature.parameters, signature.parameterConventions) {
            let layout = try SwiftGenericParameters.storageType(type)
            let argument: SwiftGenericArgument
            if convention == .inoutValue {
                func prepare<Value>(_ type: Value.Type) throws -> SwiftConventionCodec {
                    try NativeSwiftInout<Value>.makeArgumentCodec(generic: .value(layout, consuming: false))
                }
                let codec = try _openExistential(type, do: prepare)
                argument = .convention(codec)
                types.append(codec.type)
            } else {
                argument = .value(layout, consuming: convention == .consuming)
                types.append(layout)
            }
            arguments.append(argument)
            nativeClosures.append(closureInStoredValue(type))
        }
        let resultType = try SwiftGenericParameters.storageType(signature.result)
        let resultClosure = closureInStoredValue(signature.result)
        let errorType = try signature.failure == Never.self || signature.failure == (any Error).self
            ? nil : SwiftGenericParameters.storageType(signature.failure)
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: Transport = signature.isAsync
            ? .asynchronous(try SwiftAsyncCallInterface(result: resultType, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: signature.inheritsCallerIsolation),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            : .synchronous(try SwiftCallInterface.cached(result: resultType, parameters: types, errorPlan: errorPlan))
        let authentication = (signature.isAsync && signature.inheritsCallerIsolation ? ["-class"] : [])
            + Array(repeating: "-indirect", count: types.count)
        return SwiftGenericClosurePlan(transport: transport,
            parameters: SwiftGenericParameters(actual: signature.parameters, arguments: arguments),
            discriminator: swiftClosureDiscriminator(parameters: authentication, results: ["-indirect"]),
            authentication: swiftClosureAuthDescription(parameters: authentication, results: ["-indirect"]),
            isEscaping: escaping, resultConstants: SwiftValueConstants(Void.self), errorPlan: errorPlan,
            runtimeArguments: Array(repeating: nil, count: arguments.count), result: .value(resultType),
            nativeResult: signature.result, hostParameters: signature.parameters,
            nativeParameters: signature.parameters, nativeArgumentClosures: nativeClosures,
            nativeResultClosure: resultClosure)
    }

    var convertsArguments: Bool {
        runtimeArguments.contains { $0 != nil } || parameters.arguments.contains {
            switch $0 { case .closure, .convention: true; case .tuple(let plan, _, _): plan.needsConversion; default: false }
        }
    }
    var convertsValues: Bool {
        if case .runtimeValue = result { return true }
        if case .closure = result { return true }
        if case .tuple(let plan) = result, plan.needsConversion { return true }
        return convertsArguments
    }

    func validateCallbackConversion() throws {
        for conversion in runtimeArguments.compactMap({ $0 }) where !conversion.borrowed {
            try conversion.plan.requireOwnedValue()
            guard SwiftCopyability.accepts(conversion.plan.valueType.metadata) else {
                throw NativeSwiftValueError.noncopyableType
            }
        }
        let convertsResult: Bool
        switch result {
        case .runtimeValue, .closure: convertsResult = true
        case .tuple(let plan):
            try plan.validateOwnedResult()
            convertsResult = plan.needsConversion
        default: convertsResult = false
        }
        if convertsResult {
            guard errorPlan?.identity == ObjectIdentifier((any Error).self) else {
                throw ABIResolutionError.unsupportedDeclaration("A host callback returning a runtime value requires throws(any Error) to report type and ownership failures.")
            }
        }
    }

    func makeCallbackResultStorage() -> NativeValueStorage? {
        guard case .runtimeValue = result else { return nil }
        return NativeValueStorage(size: MemoryLayout<NativeSwiftValue>.stride,
            alignment: MemoryLayout<NativeSwiftValue>.alignment)
    }

    // Conversion runs only after a successful host return. Native failure leaves
    // result storage uninitialized; an invalid handle keeps its native value.
    func encodeCallbackResult(_ storage: NativeValueStorage?, to output: UnsafeMutableRawPointer,
                              errorOutput: UnsafeMutableRawPointer?) -> Bool {
        guard let storage, case .runtimeValue(let plan) = result else {
            resultConstants.initialize(at: output)
            return false
        }
        let value = storage.take(as: NativeSwiftValue.self)
        do {
            let source = try plan.encode(value, convention: .consuming, asynchronous: false)
            SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current, source.codeLifetime].compactMap { $0 }, retaining: [])
            ABISwiftTakeValue(unsafeBitCast(plan.valueType.metadata, to: UnsafeRawPointer.self), output, source.address)
            source.relinquishValue()
            return false
        } catch {
            // Publication validated the native any Error result channel.
            errorOutput!.initializeMemory(as: (any Error).self, repeating: error, count: 1)
            return true
        }
    }

    // Compare the native calling convention, including nested functions and
    // formal error storage. Escape permission is checked separately from ABI.
    func hasSameNativeABI(as other: SwiftGenericClosurePlan) -> Bool {
        guard authentication == other.authentication, parameters.groups.count == other.parameters.groups.count else { return false }
        switch (transport, other.transport) {
        case (.synchronous, .synchronous): break
        case (.asynchronous(_, let first), .asynchronous(_, let second)) where first == second: break
        default: return false
        }
        switch (errorPlan, other.errorPlan) {
        case (.none, .none): break
        case (.some(let first), .some(let second)):
            guard first.identity == second.identity, first.isTyped == second.isTyped,
                  ABIValueTypesEqual(first.type.handle, second.type.handle) else { return false }
        default: return false
        }
        for (first, second) in zip(parameters.groups, other.parameters.groups) {
            switch (first, second) {
            case (.value(let a), .value(let b)) where a == b: break
            case (.pack(let a, _), .pack(let b, _)) where a == b: break
            default: return false
            }
        }
        for index in parameters.arguments.indices {
            let first = parameters.arguments[index], second = other.parameters.arguments[index]
            switch (nativeArgumentClosures[index], other.nativeArgumentClosures[index]) {
            case (.some(let first), .some(let second)):
                if !first.hasSameNativeABI(as: second) { return false }
            case (.none, .none): break
            default: return false
            }
            switch (first.tuple, second.tuple) {
            case (.some(let first), .some(let second)):
                if !Self.sameTupleABI(first, second) { return false }
            case (.none, .none): break
            default: return false
            }
        }
        switch (result.tuple, other.result.tuple) {
        case (.some(let first), .some(let second)):
            return Self.sameTupleABI(first, second)
        case (.none, .none): break
        default: return false
        }
        switch (nativeResultClosure, other.nativeResultClosure) {
        case (.some(let first), .some(let second)): return first.hasSameNativeABI(as: second)
        case (.none, .none): return true
        default: return false
        }
    }

    private static func sameTupleABI(_ first: SwiftTupleValuePlan, _ second: SwiftTupleValuePlan) -> Bool {
        guard first.leaves.count == second.leaves.count else { return false }
        for (first, second) in zip(first.leaves, second.leaves) {
            guard first.nativeOffset == second.nativeOffset,
                  ABIValueTypesEqual(first.type.handle, second.type.handle) else { return false }
            switch (first.nativeClosure ?? first.argument.closure, second.nativeClosure ?? second.argument.closure) {
            case (.some(let first), .some(let second)):
                if !first.hasSameNativeABI(as: second) { return false }
            case (.none, .none): break
            default: return false
            }
            switch (first.result, second.result) {
            case (.closure(let first), .closure(let second)):
                if !first.nativePlan!.hasSameNativeABI(as: second.nativePlan!) { return false }
            case (.closure, _), (_, .closure): return false
            default: break
            }
        }
        return true
    }

    func validateNativeValues(for other: SwiftGenericClosurePlan) throws {
        // Function values compare their prepared signature and escape permission
        // below; their metadata also encodes those differing escape permissions.
        let sameParameters = nativeParameterTypes.count == other.nativeParameterTypes.count
            && nativeParameterTypes.indices.allSatisfy { index in
                (nativeArgumentClosures[index] != nil && other.nativeArgumentClosures[index] != nil)
                    || nativeParameterTypes[index] == other.nativeParameterTypes[index]
            }
        let sameResult = (nativeResultClosure != nil && other.nativeResultClosure != nil) || nativeResult == other.nativeResult
        guard sameParameters, sameResult else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "The closure's native argument and result types", found: []))
        }
        guard parameters.arguments.map(\.convention) == other.parameters.arguments.map(\.convention) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "The closure's native argument ownership", found: []))
        }
        for index in parameters.arguments.indices {
            if parameters.arguments[index].tuple != nil || other.parameters.arguments[index].tuple != nil { continue }
            switch (nativeArgumentClosures[index], other.nativeArgumentClosures[index]) {
            case (.some(let expected), .some(let incoming)):
                guard !expected.isEscaping || incoming.isEscaping else {
                    throw ABIResolutionError.signatureMismatch(.init(
                        expected: "An escaping nested closure accepted by the original native caller", found: ["A nonescaping input"]))
                }
                try incoming.validateNativeValues(for: expected)
            case (.none, .none): break
            default:
                throw ABIResolutionError.signatureMismatch(.init(expected: "A native closure at the same argument position", found: []))
            }
        }
        if result.tuple != nil || other.result.tuple != nil { return }
        switch (nativeResultClosure, other.nativeResultClosure) {
        case (.some(let produced), .some(let expected)):
            try produced.validateNativeValues(for: expected)
        case (.none, .none): break
        default:
            throw ABIResolutionError.signatureMismatch(.init(expected: "The closure's native result representation", found: []))
        }
    }

    func decodeArguments(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> SwiftCallbackArguments? {
        guard parameters.needsEncoding || convertsArguments else { return nil }
        let unpacked = parameters.unpack(native)
        var addresses = unpacked.addresses
        var storage = unpacked.storage
        var borrows: [SwiftValueBorrow] = []
        for (index, conversion) in runtimeArguments.enumerated() {
            guard let conversion else { continue }
            let plan = conversion.plan
            if conversion.convention == .inoutValue {
                addresses[index] = addresses[index]!.load(as: UnsafeMutableRawPointer.self)
            } else if let restored = plan.restoredCallbackArgument(from: addresses[index]!) {
                storage.append(restored)
                addresses[index] = restored.address
            }
            let lifetime = SwiftValueCodeLifetime.current ?? plan.valueType.codeLifetime
            SwiftValueCodeLifetime.connect([lifetime, plan.valueType.codeLifetime], retaining: [])
            let type = plan.valueType.retainingCode(lifetime)
            let value: NativeValueStorage
            if conversion.borrowed {
                let borrow = SwiftValueBorrow(UnsafeRawPointer(addresses[index]!), allowsSuspension: conversion.asynchronous,
                    allowsMutation: conversion.convention == .inoutValue)
                borrows.append(borrow)
                value = NativeValueStorage(size: MemoryLayout<NativeSwiftBorrowedValue>.stride,
                    alignment: MemoryLayout<NativeSwiftBorrowedValue>.alignment, codeLifetime: lifetime)
                value.initialize(NativeSwiftBorrowedValue(type: type, borrow: borrow))
            } else {
                value = NativeValueStorage(size: MemoryLayout<NativeSwiftValue>.stride,
                    alignment: MemoryLayout<NativeSwiftValue>.alignment, codeLifetime: lifetime)
                value.initialize(plan.copyCallbackArgument(from: addresses[index]!, type: type))
            }
            addresses[index] = value.address
            storage.append(value)
        }
        return SwiftCallbackArguments(addresses: addresses, storage: storage, borrows: borrows)
    }
}

struct SwiftGenericCallPlan: Sendable {
    let binding: SwiftGenericBinding
    private(set) var metadata: SwiftGenericArgumentBuffer
    private let context: SwiftGenericTypeContext?
    private let enclosingMetadata: Any.Type?
    private var receiver: SwiftReceiverMode?
    let parameters: SwiftGenericParameters
    var arguments: [SwiftGenericArgument] { parameters.arguments }
    let result: SwiftGenericResult
    var resultType: CValueType? { result.type }
    let errorType: CValueType?

    init(symbol: ResolvedSymbol, genericArguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver,
         enclosing: SwiftGenericTypeMetadata? = nil, receiver: SwiftReceiverMode? = nil,
         declaredSignature: String? = nil, valueABIs: [NativeSwiftType: NativeType] = [:]) throws {
        let context = try enclosing.flatMap { $0.arguments.isEmpty ? nil : try SwiftGenericTypeContext(metadata: $0.value) }
        let declared = try declaredSignature.map(SwiftDeclaredSignature.init)
        let declaration = try SwiftGenericDeclaration(linkageName: symbol.linkageName, enclosing: context,
                                                       declaredSignature: declared, caller: signature)
        var binding = try SwiftGenericBinding(declaration: declaration,
            arguments: (enclosing?.arguments ?? []) + genericArguments,
            signature: signature, resolver: resolver, enclosing: context, image: symbol.image,
            valueABIs: valueABIs)
        if !declaration.result.opaqueIndices.isEmpty {
            binding.opaqueResults = try SwiftOpaqueResultPlan.resolve(symbol: symbol,
                resolver: resolver, indices: declaration.result.opaqueIndices, binding: binding)
        }
        let opaque = declaration.result.opaqueIndex.flatMap { binding.opaqueResults[$0] }
        if case .function(let arguments, let result, let failure, let attributes) = declared?.function {
            _ = try SwiftGenericParameters(formal: arguments, actual: signature.parameters, binding: binding,
                defaultConsuming: declaration.consumesArguments)
            guard attributes.isAsync == declaration.isAsync else {
                throw ABIResolutionError.signatureMismatch(.init(expected: "The declaration's async effect", found: [declared!.function.spelling]))
            }
            if let failure { try binding.validate(signature.failure, for: failure) }
            else if signature.failure != Never.self {
                throw ABIResolutionError.signatureMismatch(.init(expected: "A nonthrowing declaredAs: signature", found: [String(reflecting: signature.failure)]))
            }
            if binding.dependsOnParameters(result) { _ = try binding.resultType(signature.result, for: result) }
        }
        guard declaration.isAsync == signature.isAsync,
              declaration.failure != nil || signature.failure == Never.self else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "The declaration's async and error effects", found: []))
        }
        self.binding = binding
        if let failure = declaration.failure { try binding.validate(signature.failure, for: failure) }
        self.context = context
        self.receiver = receiver
        enclosingMetadata = enclosing?.value
        if let context, let receiver, receiver != .value {
            let prefix: [UInt] = receiver == .address ? [unsafeBitCast(enclosing!.value, to: UInt.self)] : []
            metadata = try SwiftGenericArgumentBuffer(prefix + binding.metadataArguments(fulfilledBy: context))
        } else {
            metadata = SwiftGenericArgumentBuffer(binding.metadataArguments)
        }
        parameters = try SwiftGenericParameters(formal: declaration.arguments, actual: signature.parameters, binding: binding,
            defaultConsuming: declaration.consumesArguments)
        if let opaque, signature.result != NativeSwiftValue.self && signature.result != NativeSwiftBorrowedValue.self {
            _ = try binding.resultType(signature.result, for: declaration.result)
            result = .value(opaque.type)
        } else {
            result = try Self.result(declaration.result, actual: signature.result, binding: binding)
        }
        if let failure = declaration.failure, binding.dependsOnParameters(failure) {
            errorType = try Self.layout(failure, actual: signature.failure, binding: binding)
        } else {
            errorType = nil
        }
    }

    func includingReceiver(_ receiver: SwiftReceiverMode) throws -> Self {
        var result = self
        result.receiver = receiver
        if let context, let enclosingMetadata, receiver != .value {
            let prefix: [UInt] = receiver == .address ? [unsafeBitCast(enclosingMetadata, to: UInt.self)] : []
            result.metadata = try SwiftGenericArgumentBuffer(prefix + binding.metadataArguments(fulfilledBy: context))
        }
        return result
    }

    func validateMetadataArguments() throws {
        try binding.validateMetadataArguments(fulfilledBy: receiver == .object || receiver == .address ? context : nil)
    }

    var hookEnclosingClass: AnyClass? {
        context != nil && receiver == .object ? enclosingMetadata as? AnyClass : nil
    }

    func hookMetadataArguments() throws -> [SwiftGenericBinding.HookMetadataArgument] {
        let fulfilled = receiver == .object || receiver == .address ? context : nil
        let prefix: [SwiftGenericBinding.HookMetadataArgument] = context != nil && receiver == .address
            ? [.value(unsafeBitCast(enclosingMetadata!, to: UInt.self))] : []
        return try prefix + binding.hookMetadataArguments(fulfilledBy: fulfilled)
    }

    struct HookClassArgument: Sendable {
        let index: Int
        let expected: AnyClass
        let isMetatype: Bool
    }

    func hookClassArguments() throws -> [HookClassArgument] {
        var sources: [HookClassArgument] = []
        var nativeIndex = 0
        func add(_ type: Any.Type, layout: CValueType, at index: Int) {
            guard !ABISwiftValueIsIndirect(layout.handle) else { return }
            if let instance = SwiftMetatypeMetadata(type)?.instance as? AnyClass {
                sources.append(.init(index: index, expected: instance, isMetatype: true))
            } else if let expected = type as? AnyClass {
                sources.append(.init(index: index, expected: expected, isMetatype: false))
            }
        }
        func add(_ tuple: SwiftTupleValuePlan, at start: Int) {
            var index = start
            for group in tuple.parameters.groups {
                switch group {
                case .pack: index += 1
                case .value(let logical):
                    let field = tuple.fields[logical]
                    if let nested = SwiftGenericParameters.expandedTuple(field.argument) {
                        add(nested, at: index)
                        index += nested.argumentTypes.count
                    } else {
                        switch field.argument {
                        case .concrete: break
                        default: add(field.nativeType, layout: field.type, at: index)
                        }
                        index += 1
                    }
                }
            }
        }
        for (formal, group) in zip(binding.declaration.arguments, parameters.groups) {
            switch group {
            case .pack: nativeIndex += 1
            case .value(let logical):
                let argument = parameters.arguments[logical]
                let tuple = SwiftGenericParameters.expandedTuple(argument)
                defer { nativeIndex += tuple?.argumentTypes.count ?? 1 }
                guard argument.convention != .inoutValue, binding.dependsOnParameters(formal) else { continue }
                if let tuple {
                    add(tuple, at: nativeIndex)
                } else {
                    let value = formal.argumentConvention?.value ?? formal
                    let native = try binding.types(value)[0]
                    add(native, layout: try Self.layout(value, actual: native, binding: binding), at: nativeIndex)
                }
            }
        }
        return sources
    }

    func receiverType() throws -> CValueType? {
        guard let context, let enclosingMetadata, !(enclosingMetadata is AnyClass) else { return nil }
        let arguments = context.parameters.map { SwiftFormalType.named($0.name, []) }
        return try SwiftGenericValueLayout.isIndirect(enclosingMetadata, arguments: arguments, binding: binding)
            ? SwiftGenericParameters.storageType(enclosingMetadata) : nil
    }

    func matches(_ signature: SwiftFunctionSignature) throws -> Bool {
        func validate(_ actual: Any.Type, for formal: SwiftFormalType, using binding: SwiftGenericBinding) throws {
            if let argument = try binding.conventionArgument(actual, for: formal,
                defaultConsuming: binding.declaration.consumesArguments) {
                try binding.validateArgument(argument.wrapper.wrappedType, for: argument.value)
            } else {
                try binding.validateArgument(actual, for: formal)
            }
        }
        do {
            for (formal, group) in zip(binding.declaration.arguments, parameters.groups) {
                switch group {
                case .value(let index):
                    try validate(signature.parameters[index], for: formal, using: binding)
                case .pack(let range, _):
                    guard case .pack(let pattern, _) = formal else { preconditionFailure("A pack group has a pack formal type.") }
                    for (packIndex, index) in range.enumerated() {
                        try validate(signature.parameters[index], for: pattern, using: binding.selectingPackElement(at: packIndex))
                    }
                }
            }
            _ = try binding.resultType(signature.result, for: binding.declaration.result)
            return true
        } catch ABIResolutionError.signatureMismatch { return false }
    }

    static func argument(_ formal: SwiftFormalType, actual: Any.Type,
                         binding: SwiftGenericBinding, defaultConsuming: Bool = false, asynchronous: Bool? = nil,
                         callback: Bool = false) throws -> SwiftGenericArgument {
        if callback, case .inoutValue(let pointee) = formal, actual == NativeSwiftBorrowedValue.self {
            let metadata = try binding.types(pointee)[0]
            return .runtimeValue(try runtimeValue(pointee, metadata: metadata, binding: binding,
                asynchronous: asynchronous ?? binding.declaration.isAsync),
                convention: .inoutValue, asynchronous: asynchronous ?? binding.declaration.isAsync)
        }
        if let argument = try binding.conventionArgument(actual, for: formal, defaultConsuming: defaultConsuming) {
            let value = try Self.argument(argument.value, actual: argument.wrapper.wrappedType, binding: binding,
                                          defaultConsuming: argument.wrapper.convention == .consuming, asynchronous: asynchronous)
            return .convention(try argument.wrapper.makeArgumentCodec(generic: value))
        }
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            let metadata = try binding.types(formal)[0]
            if metadata != actual {
                guard actual != NativeSwiftBorrowedValue.self || !defaultConsuming else {
                    throw ABIResolutionError.unsupportedDeclaration("A borrowed runtime value cannot be consumed.")
                }
                return .runtimeValue(try runtimeValue(formal, metadata: metadata, binding: binding,
                    asynchronous: asynchronous ?? binding.declaration.isAsync),
                    convention: defaultConsuming ? .consuming : .borrowing,
                    asynchronous: asynchronous ?? binding.declaration.isAsync)
            }
        }
        if case .function = formal, let closure = actual as? any SwiftClosureValue.Type {
            return .closure(try Self.closure(formal, signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding),
                asynchronous: asynchronous ?? binding.declaration.isAsync)
        }
        let canonical = try binding.canonicalType(of: formal)
        if case .tuple = canonical {
            return .tuple(try tuple(canonical, actual: actual, binding: binding,
                asynchronous: asynchronous ?? binding.declaration.isAsync), consuming: defaultConsuming,
                asynchronous: asynchronous ?? binding.declaration.isAsync)
        }
        guard binding.dependsOnParameters(formal) || !formal.opaqueIndices.isEmpty else { return .concrete }
        try binding.validate(actual, for: formal)
        return .value(try Self.layout(formal, actual: actual, binding: binding), consuming: false)
    }

    static func result(_ formal: SwiftFormalType, actual: Any.Type, binding: SwiftGenericBinding) throws -> SwiftGenericResult {
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            let metadata = try binding.types(formal)[0]
            if metadata != actual {
                return .runtimeValue(try runtimeValue(formal, metadata: metadata, binding: binding))
            }
        }
        let canonical = try binding.canonicalType(of: formal)
        if case .tuple = canonical { return .tuple(try tuple(canonical, actual: actual, binding: binding)) }
        if case .function = canonical, let closure = actual as? any SwiftClosureValue.Type {
            let plan = try Self.closure(canonical, signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding)
            return .closure(try closure.makeGenericClosureCodec(plan: plan))
        }
        if binding.dependsOnParameters(formal) || !formal.opaqueIndices.isEmpty {
            let native = try binding.resultType(actual, for: formal)
            return .value(try layout(formal, actual: native, binding: binding))
        }
        return .concrete
    }

    private static func runtimeValue(_ formal: SwiftFormalType, metadata: Any.Type,
                                     binding: SwiftGenericBinding, asynchronous: Bool = false) throws -> SwiftRuntimeValuePlan {
        let canonical = try binding.canonicalType(of: formal)
        let nativeTuple: SwiftTupleValuePlan?
        if case .tuple = canonical {
            nativeTuple = try tuple(canonical, actual: metadata, binding: binding,
                asynchronous: asynchronous, nativeStorage: true)
        } else { nativeTuple = nil }
        let nativeClosure: SwiftGenericClosurePlan?
        if case .function = canonical {
            nativeClosure = try Self.closure(canonical,
                signature: SwiftFunctionSignature(nativeClosureSignature(canonical, binding: binding)), binding: binding)
        } else if nativeTuple == nil {
            nativeClosure = SwiftGenericClosurePlan.closureInStoredValue(metadata)
        } else { nativeClosure = nil }
        return try binding.runtimeValuePlan(metadata: metadata,
            type: layout(formal, actual: metadata, binding: binding),
            nativeTuple: nativeTuple, nativeClosure: nativeClosure)
    }

    static func tuple(_ formal: SwiftFormalType, actual: Any.Type, binding: SwiftGenericBinding,
                      asynchronous: Bool = false, nativeStorage: Bool = false) throws -> SwiftTupleValuePlan {
        guard case .tuple(let fields, let labels) = formal else {
            preconditionFailure("A tuple plan requires its formal tuple declaration.")
        }
        let hostElements = try tupleElements(fields, actual: actual, binding: binding)
        let native = try binding.types(formal)[0]
        let nativeElements = try tupleElements(fields, actual: native, binding: binding)
        let expectedLabels = try fields.enumerated().flatMap { index, field -> [String] in
            let count: Int
            if case .pack(let pattern, let shape) = field { count = try binding.packCount(in: shape ?? pattern) }
            else { count = 1 }
            return Array(repeating: labels?[index] ?? "", count: count)
        }
        if hostElements.count != 1, let host = SwiftTupleMetadata(actual), host.labels != expectedLabels {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling,
                found: [String(reflecting: actual)]))
        }
        var prepared: [SwiftTupleValuePlan.Field] = []
        var groups: [SwiftGenericParameters.Group] = []
        var index = 0
        func append(_ field: SwiftFormalType, using binding: SwiftGenericBinding) throws {
            let host = hostElements[index], native = nativeElements[index]
            let canonical = try binding.canonicalType(of: field)
            let nested: SwiftTupleValuePlan?
            let argument: SwiftGenericArgument
            let result: SwiftGenericResult
            if case .tuple = canonical {
                let value = try tuple(canonical, actual: host.type, binding: binding,
                    asynchronous: asynchronous, nativeStorage: nativeStorage)
                nested = value; argument = .tuple(value, asynchronous: asynchronous); result = .tuple(value)
            } else if nativeStorage {
                nested = nil
                let type = try layout(field, actual: native.type, binding: binding)
                argument = .value(type, consuming: false)
                result = .value(type)
            } else {
                nested = nil
                try binding.validateArgument(host.type, for: field)
                argument = try Self.argument(field, actual: host.type, binding: binding, asynchronous: asynchronous)
                result = try Self.result(field, actual: host.type, binding: binding)
            }
            let nativeClosure: SwiftGenericClosurePlan?
            if nativeStorage, case .function = canonical {
                nativeClosure = try Self.closure(canonical,
                    signature: SwiftFunctionSignature(nativeClosureSignature(canonical, binding: binding)), binding: binding)
            } else { nativeClosure = nil }
            prepared.append(try .init(hostType: host.type, nativeType: native.type,
                hostOffset: host.offset, nativeOffset: native.offset, argument: argument, result: result,
                tuple: nested, nativeClosure: nativeClosure))
            index += 1
        }
        for field in fields {
            if case .pack(let pattern, let shape) = field {
                let start = index
                for index in 0..<(try binding.packCount(in: shape ?? pattern)) {
                    try append(pattern, using: binding.selectingPackElement(at: index))
                }
                groups.append(.pack(start..<index, try CValueType(indirectSwiftSize: (index - start) * MemoryLayout<UInt>.size,
                                                                 alignment: MemoryLayout<UInt>.alignment)))
            } else {
                groups.append(.value(index))
                try append(field, using: binding)
            }
        }
        return try SwiftTupleValuePlan(hostMetadata: actual, nativeMetadata: native,
            type: tupleLayout(fields, actual: native, binding: binding), fields: prepared, groups: groups)
    }

    // Native tuple storage retains its Swift representation. This signature
    // uses the existing bridge markers only to prepare each formal function's
    // recursive ABI, including ownership, generic indirection, and packs.
    private static func nativeClosureSignature(_ formal: SwiftFormalType,
                                                binding: SwiftGenericBinding) throws -> Any.Type {
        guard case .function(let parameters, let result, let failure, var attributes) = formal else {
            preconditionFailure("A native closure signature requires a formal function.")
        }
        var inputs: [Any.Type] = [], parameterFlags: [UInt32] = []
        for (index, parameter) in parameters.enumerated() {
            let flags = attributes.parameterFlags.isEmpty ? 0 : attributes.parameterFlags[index]
            if case .pack(let pattern, let shape) = parameter {
                for element in 0..<(try binding.packCount(in: shape ?? pattern)) {
                    inputs.append(try nativeClosureValueType(pattern, owned: false,
                        binding: binding.selectingPackElement(at: element)))
                    parameterFlags.append(flags)
                }
            } else {
                inputs.append(try nativeClosureValueType(parameter, owned: false, binding: binding))
                parameterFlags.append(flags)
            }
        }
        let output = try nativeClosureValueType(result, owned: true, binding: binding)
        let error = try failure.map { type in
            type.spelling == "Swift.Error" || type.spelling == "Error" ? (any Error).self : try binding.types(type)[0]
        }
        let actor = try attributes.globalActor.map { try binding.types($0)[0] }
        attributes.isEscaping = true
        return try SwiftGenericBinding.functionType(parameters: inputs, parameterFlags: parameterFlags,
            result: output, failure: error, attributes: attributes, globalActor: actor)
    }

    private static func nativeClosureValueType(_ formal: SwiftFormalType, owned: Bool,
                                                binding: SwiftGenericBinding) throws -> Any.Type {
        let canonical = try binding.canonicalType(of: formal)
        if let convention = canonical.argumentConvention {
            let wrapped = try nativeClosureValueType(convention.value,
                owned: convention.convention != .borrowing, binding: binding)
            if convention.convention == .inoutValue,
               wrapped == NativeSwiftValue.self { return NativeSwiftBorrowedValue.self }
            func marker<Value>(_ type: Value.Type) -> Any.Type {
                switch convention.convention {
                case .borrowing: NativeSwiftBorrowing<Value>.self
                case .consuming: NativeSwiftConsuming<Value>.self
                case .inoutValue: NativeSwiftInout<Value>.self
                }
            }
            return _openExistential(wrapped, do: marker)
        }
        if case .function = canonical {
            let signature = try nativeClosureSignature(canonical, binding: binding)
            func marker<Signature>(_ type: Signature.Type) -> Any.Type { NativeSwiftClosure<Signature>.self }
            return _openExistential(signature, do: marker)
        }
        if case .tuple(let fields, let labels) = canonical {
            var elements: [Any.Type] = [], names: [String] = []
            for (index, field) in fields.enumerated() {
                if case .pack(let pattern, let shape) = field {
                    for element in 0..<(try binding.packCount(in: shape ?? pattern)) {
                        elements.append(try nativeClosureValueType(pattern, owned: owned,
                            binding: binding.selectingPackElement(at: element)))
                        names.append(labels?[index] ?? "")
                    }
                } else {
                    elements.append(try nativeClosureValueType(field, owned: owned, binding: binding))
                    names.append(labels?[index] ?? "")
                }
            }
            let pointers = elements.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
            let metadata = pointers.withUnsafeBufferPointer { pointers in
                if names.allSatisfy(\.isEmpty) { return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil) }
                return (names.joined(separator: " ") + " ").withCString {
                    ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
                }
            }
            guard let metadata else {
                throw ABIResolutionError.metadataUnavailable("The tuple exceeds Swift's metadata element count.")
            }
            return unsafeBitCast(metadata, to: Any.Type.self)
        }
        return owned ? NativeSwiftValue.self : NativeSwiftBorrowedValue.self
    }

    static func concreteTuple(_ actual: Any.Type) throws -> SwiftTupleValuePlan? {
        guard let host = SwiftTupleMetadata(actual) else { return nil }
        let nativeType = try concreteNativeMetadata(actual)
        let native = SwiftTupleMetadata(nativeType)!
        var fields: [SwiftTupleValuePlan.Field] = []
        for (host, native) in zip(host.elements, native.elements) {
            let argument: SwiftGenericArgument
            let result: SwiftGenericResult
            let tuple = try concreteTuple(host.type)
            if let tuple { argument = .tuple(tuple); result = .tuple(tuple) }
            else if let closure = host.type as? any SwiftClosureValue.Type {
                let plan = try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType)
                argument = .closure(plan)
                result = .closure(try closure.makeGenericClosureCodec(plan: plan))
            } else {
                argument = .concrete; result = .concrete
            }
            fields.append(try .init(hostType: host.type, nativeType: native.type,
                hostOffset: host.offset, nativeOffset: native.offset, argument: argument, result: result, tuple: tuple))
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(nativeType, to: UnsafeRawPointer.self))
        return try SwiftTupleValuePlan(hostMetadata: actual, nativeMetadata: nativeType,
            type: CValueType(swiftTuple: fields.map(\.type), offsets: fields.map(\.nativeOffset),
                size: layout.size, alignment: layout.alignment), fields: fields)
    }

    static func concreteNativeMetadata(_ actual: Any.Type) throws -> Any.Type {
        if let closure = actual as? any SwiftClosureValue.Type {
            let function = closure.swiftFunctionType
            let signature = try SwiftFunctionSignature(function)
            var parameterFlags = Array(repeating: UInt32(0), count: signature.parameters.count)
            let parameters = try signature.parameters.enumerated().map { index, type -> Any.Type in
                if let convention = type as? any SwiftConventionArgument.Type {
                    parameterFlags[index] = switch convention.convention {
                    case .inoutValue: 1
                    case .borrowing: 2
                    case .consuming: 3
                    }
                    return try concreteNativeMetadata(convention.wrappedType)
                }
                return try concreteNativeMetadata(type)
            }
            let result = try concreteNativeMetadata(signature.result)
            let metadata = unsafeBitCast(function, to: UnsafeRawPointer.self)
            let word = MemoryLayout<UInt>.size
            var flags = metadata.load(fromByteOffset: word, as: UInt.self)
            var offset = (3 + signature.parameters.count) * word
            if flags & 0x02000000 != 0 { offset += signature.parameters.count * 4 }
            offset = (offset + word - 1) & ~(word - 1)
            let extended = flags & 0x80000000 != 0 ? metadata.load(fromByteOffset: offset, as: UInt32.self) : 0
            let hasParameterFlags = parameterFlags.contains { $0 != 0 }
            flags = (flags & ~UInt(0x02000000)) | (hasParameterFlags ? 0x02000000 : 0)
            let pointers = parameters.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
            let value = pointers.withUnsafeBufferPointer { pointers in
                parameterFlags.withUnsafeBufferPointer { parameters in
                    ABISwiftFunctionTypeMetadata(flags, pointers.baseAddress,
                        hasParameterFlags ? parameters.baseAddress : nil,
                        unsafeBitCast(result, to: UnsafeRawPointer.self), extended,
                        extended & 1 == 0 ? nil : unsafeBitCast(signature.failure, to: UnsafeRawPointer.self), 0, nil)
                }
            }
            guard let value else { throw ABIResolutionError.metadataUnavailable("The Swift runtime could not construct the function type.") }
            return unsafeBitCast(value, to: Any.Type.self)
        }
        guard let tuple = SwiftTupleMetadata(actual) else { return actual }
        let elements = try tuple.elements.map { try concreteNativeMetadata($0.type) }
        if zip(elements, tuple.elements).allSatisfy({ $0.0 == $0.1.type }) { return actual }
        let pointers = elements.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
        let value = pointers.withUnsafeBufferPointer { pointers in
            if tuple.labels.allSatisfy(\.isEmpty) { return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil) }
            return (tuple.labels.joined(separator: " ") + " ").withCString {
                ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
            }
        }
        guard let value else { throw ABIResolutionError.metadataUnavailable("The tuple exceeds Swift's metadata element count.") }
        return unsafeBitCast(value, to: Any.Type.self)
    }

    static func closure(_ formal: SwiftFormalType, signature: SwiftFunctionSignature,
                                binding: SwiftGenericBinding) throws -> SwiftGenericClosurePlan {
        guard case .function(let parameters, let result, let failure, let attributes) = formal else {
            preconditionFailure("A closure plan requires a function type.")
        }
        guard attributes.isAsync == signature.isAsync,
              failure != nil || signature.failure == Never.self else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        // An opaque-bearing returned function is erased to the ordinary Swift
        // function-value storage convention before it crosses the factory ABI.
        let usesStorageConvention = !formal.opaqueIndices.isEmpty
        var parameterPlan = try SwiftGenericParameters(formal: parameters, actual: signature.parameters, binding: binding,
            asynchronous: attributes.isAsync, callback: true)
        if usesStorageConvention { parameterPlan = parameterPlan.usingStorageConvention() }
        if let failure { try binding.validate(signature.failure, for: failure) }
        let runtimeArguments: [SwiftCallbackRuntimeArgument?] = parameterPlan.arguments.enumerated().map { index, argument in
            guard case .runtimeValue(let plan, let convention, _) = argument else { return nil }
            let borrowed = signature.parameters[index] == NativeSwiftBorrowedValue.self
            return SwiftCallbackRuntimeArgument(plan: plan, borrowed: borrowed, asynchronous: attributes.isAsync, convention: convention)
        }
        var logicalTypes: [CValueType] = []
        var nativeParameters: [Any.Type] = []
        var authentication = attributes.isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
        for (formal, group) in zip(parameters, parameterPlan.groups) {
            switch group {
            case .pack(let range, _):
                guard case .pack(let pattern, _) = formal else {
                    preconditionFailure("A pack group has a pack formal type.")
                }
                for (packIndex, index) in range.enumerated() {
                    let selected = binding.selectingPackElement(at: packIndex)
                    nativeParameters.append(try selected.types(pattern.argumentConvention?.value ?? pattern)[0])
                    if let conversion = runtimeArguments[index] {
                        logicalTypes.append(try SwiftGenericParameters.storageType(conversion.plan.valueType.metadata))
                    } else {
                        try binding.selectingPackElement(at: packIndex).validateArgument(signature.parameters[index], for: pattern)
                        logicalTypes.append(try SwiftGenericParameters.storageType(signature.parameters[index]))
                    }
                }
                // SIL pack values have an opaque type hash, distinct from an
                // ordinary formally indirect scalar (GenPointerAuth.cpp).
                authentication.append("-")
            case .value(let index):
                nativeParameters.append(try binding.types(formal.argumentConvention?.value ?? formal)[0])
                let argument = parameterPlan.arguments[index]
                let actual = argument.runtimeValue?.valueType.metadata ?? signature.parameters[index]
                if case .convention(let codec) = argument {
                    logicalTypes.append(codec.type)
                    let underlying = formal.argumentConvention?.value ?? formal
                    let wrapper = signature.parameters[index] as! any SwiftConventionArgument.Type
                    authentication.append(contentsOf: wrapper.convention == .inoutValue ? ["-indirect"] : try authTypes(underlying,
                        actual: argument.runtimeValue?.valueType.metadata ?? wrapper.wrappedType, binding: binding))
                    continue
                }
                if runtimeArguments[index]?.convention == .inoutValue {
                    logicalTypes.append(try CValueType(scalar: ABIValuePointer))
                    authentication.append("-indirect")
                    continue
                }
                if runtimeArguments[index] == nil { try binding.validateArgument(actual, for: formal) }
                logicalTypes.append(try layout(formal, actual: actual, binding: binding))
                authentication.append(contentsOf: try authTypes(formal, actual: actual, binding: binding))
            }
        }
        if usesStorageConvention {
            logicalTypes = try zip(nativeParameters, parameterPlan.arguments).map { metadata, argument in
                argument.convention == .inoutValue ? try CValueType(scalar: ABIValuePointer)
                    : try SwiftGenericParameters.storageType(metadata)
            }
            authentication = attributes.isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
            authentication += parameterPlan.groups.map {
                if case .pack = $0 { return "-" }
                return "-indirect"
            }
        }
        let types = parameterPlan.types(from: logicalTypes)
        let nativeResult = try binding.resultType(signature.result, for: result)
        let resultType = try usesStorageConvention ? SwiftGenericParameters.storageType(nativeResult)
            : layout(result, actual: nativeResult, binding: binding)
        let resultPlan = try Self.result(result, actual: signature.result, binding: binding)
        let errorType = try failure.flatMap {
            if usesStorageConvention && signature.failure != (any Error).self {
                return try SwiftGenericParameters.storageType(signature.failure)
            }
            return binding.dependsOnParameters($0) ? try layout($0, actual: signature.failure, binding: binding) : nil
        }
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: SwiftGenericClosurePlan.Transport = attributes.isAsync
            ? .asynchronous(try SwiftAsyncCallInterface(result: resultType, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: signature.inheritsCallerIsolation),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            : .synchronous(try SwiftCallInterface.cached(result: resultType, parameters: types, errorPlan: errorPlan))
        let resultAuthentication = try usesStorageConvention ? ["-indirect"]
            : authTypes(result, actual: nativeResult, binding: binding, isResult: true)
        let nativeArgumentClosures = zip(parameterPlan.arguments, nativeParameters).map { argument, metadata -> SwiftGenericClosurePlan? in
            if let closure = argument.closure { return closure }
            return argument.tuple == nil ? SwiftGenericClosurePlan.closureInStoredValue(metadata) : nil
        }
        let nativeResultClosure = resultPlan.closure
            ?? (resultPlan.tuple == nil ? SwiftGenericClosurePlan.closureInStoredValue(nativeResult) : nil)
        return SwiftGenericClosurePlan(transport: transport, parameters: parameterPlan,
            discriminator: swiftClosureDiscriminator(parameters: authentication, results: resultAuthentication),
            authentication: swiftClosureAuthDescription(parameters: authentication, results: resultAuthentication), isEscaping: attributes.isEscaping,
            resultConstants: SwiftValueConstants(usesStorageConvention ? Void.self : nativeResult), errorPlan: errorPlan,
            runtimeArguments: runtimeArguments, result: resultPlan, nativeResult: nativeResult,
            hostParameters: signature.parameters, nativeParameters: nativeParameters,
            nativeArgumentClosures: nativeArgumentClosures, nativeResultClosure: nativeResultClosure)
    }

    private static func authTypes(_ formal: SwiftFormalType, actual: Any.Type,
                                  binding: SwiftGenericBinding, isResult: Bool = false) throws -> [String] {
        let canonical = try binding.canonicalType(of: formal)
        if canonical != formal { return try authTypes(canonical, actual: actual, binding: binding, isResult: isResult) }
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            let native = try binding.types(formal)[0]
            if native != actual { return try authTypes(formal, actual: native, binding: binding, isResult: isResult) }
        }
        if case .tuple(let fields, _) = formal {
            let elements = try tupleElements(fields, actual: actual, binding: binding)
            var index = 0
            return try fields.flatMap { field -> [String] in
                if case .pack(let pattern, let shape) = field {
                    index += try binding.packCount(in: shape ?? pattern)
                    return [isResult ? "-indirect" : "-"]
                }
                defer { index += 1 }
                return try authTypes(field, actual: elements[index].type, binding: binding, isResult: isResult)
            }
        }
        if case .function(let parameters, let result, _, let attributes) = formal {
            if let closure = actual as? any SwiftClosureValue.Type {
                let plan = try Self.closure(formal, signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding)
                return ["(" + plan.authentication + ")"]
            }
            var inputs = attributes.isAsync && attributes.isolation == .caller ? ["-class"] : []
            for parameter in parameters {
                if case .pack = parameter { inputs.append("-"); continue }
                if case .inoutValue = parameter { inputs.append("-indirect"); continue }
                let value = parameter.argumentConvention?.value ?? parameter
                inputs.append(contentsOf: try authTypes(value, actual: binding.types(value)[0], binding: binding))
            }
            let outputs = try authTypes(result, actual: binding.types(result)[0], binding: binding, isResult: true)
            return ["(" + swiftClosureAuthDescription(parameters: inputs, results: outputs) + ")"]
        }
        if !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty {
            let explicit = formal.nominalDeclaration == nil ? nil : try binding.explicitValueType(actual)
            if explicit == nil {
                // Concrete class existentials and metatypes keep their formal
                // identity even when their physical storage is indirect.
                return [try swiftClosureAuthType(actual)]
            }
        }
        let layout = try layout(formal, actual: actual, binding: binding)
        if ABISwiftValueIsIndirect(layout.handle) { return ["-indirect"] }
        return [try swiftClosureAuthType(actual)]
    }

    private static func tupleElements(_ fields: [SwiftFormalType], actual: Any.Type,
                                      binding: SwiftGenericBinding) throws -> [SwiftTupleMetadata.Element] {
        let count = try fields.reduce(0) { count, field in
            if case .pack(let pattern, let shape) = field { return count + (try binding.packCount(in: shape ?? pattern)) }
            return count + 1
        }
        // A substituted singleton pack is its element type, even when that
        // element is itself a tuple. Swift does not have one-element tuples.
        if count == 1 { return [.init(type: actual, offset: 0)] }
        guard let tuple = SwiftTupleMetadata(actual), tuple.elements.count == count else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "\(count) tuple elements", found: [String(reflecting: actual)]))
        }
        return tuple.elements
    }

    private static func layout(_ formal: SwiftFormalType, actual: Any.Type,
                               binding: SwiftGenericBinding) throws -> CValueType {
        let canonical = try binding.canonicalType(of: formal)
        if canonical != formal { return try layout(canonical, actual: actual, binding: binding) }
        if binding.isArchetype(formal) {
            return try binding.isClassBound(formal) ? CValueType(scalar: ABIValuePointer)
                : SwiftGenericParameters.storageType(actual)
        }
        if case .tuple(let fields, _) = formal { return try tupleLayout(fields, actual: actual, binding: binding) }
        if case .function = formal {
            let pointer = try CValueType(scalar: ABIValuePointer)
            return try CValueType(fields: [pointer, pointer])
        }
        if let index = formal.opaqueIndex {
            guard let opaque = binding.opaqueResults[index] else {
                throw ABIResolutionError.metadataUnavailable("The opaque result ABI has not been resolved.")
            }
            return opaque.type
        }
        if formal.nominalDeclaration != nil, !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty,
           let explicit = try binding.explicitValueType(actual) { return explicit }
        func prepare<Value>(_ type: Value.Type) throws -> CValueType {
            if !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty { return try SwiftValueCodec<Value>().type }
            if try binding.isClassBound(formal) { return try CValueType(scalar: ABIValuePointer) }
            switch formal {
            case .associated:
                return try SwiftGenericParameters.storageType(actual)
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if !arguments.isEmpty && actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
                if ["Swift.Array", "Swift.Dictionary", "Swift.Set"].contains(name) {
                    return try CValueType(scalar: ABIValuePointer)
                }
                if name == "Swift.Optional", let wrapped = arguments.first {
                    if try binding.isClassBound(wrapped) { return try CValueType(scalar: ABIValuePointer) }
                    let wrappedType = try binding.types(wrapped)[0]
                    if case .metatype(let instance) = wrapped, let metatype = SwiftMetatypeMetadata(wrappedType) {
                        return try !metatype.isExistential && singletonMetatype(instance, binding: binding)
                            ? CValueType(swiftOptionalSingleton: ()) : metatype.valueType(for: Value.self, thin: false)
                    }
                    let wrappedLayout = try Self.layout(wrapped, actual: wrappedType, binding: binding)
                    if withExtendedLifetime(wrappedLayout, { ABISwiftValueIsIndirect(wrappedLayout.handle) }) {
                        return try SwiftGenericParameters.storageType(actual)
                    }
                    return try SwiftValueCodec<Value>().type
                }
                let isArchetype: Bool
                if case .named = formal {
                    isArchetype = arguments.isEmpty && binding.arguments[String(name.prefix { $0 != "." })] != nil
                } else { isArchetype = false }
                if try isArchetype || SwiftGenericValueLayout.isIndirect(actual, arguments: arguments, binding: binding) {
                    return try SwiftGenericParameters.storageType(actual)
                }
                return try SwiftValueCodec<Value>().type
            case .reference(_, let arguments):
                if actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
                if try SwiftGenericValueLayout.isIndirect(actual, arguments: arguments, binding: binding) {
                    return try SwiftGenericParameters.storageType(actual)
                }
                return try SwiftValueCodec<Value>().type
            case .nested:
                if actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
                if try SwiftGenericValueLayout.isIndirect(actual, arguments: formal.nominalDeclaration!.arguments, binding: binding) {
                    return try SwiftGenericParameters.storageType(actual)
                }
                return try SwiftValueCodec<Value>().type
            case .metatype(let instance):
                guard let metatype = SwiftMetatypeMetadata(actual) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: [String(reflecting: actual)]))
                }
                return try metatype.valueType(for: Value.self, thin: !metatype.isExistential && singletonMetatype(instance, binding: binding))
            case .existentialMetatype, .constrainedExistential:
                return try SwiftValueCodec<Value>().type
            case .tuple(let fields, _): return try tupleLayout(fields, actual: actual, binding: binding)
            case .opaqueResult:
                throw ABIResolutionError.metadataUnavailable("The opaque result ABI has not been resolved.")
            case .pack, .packValue:
                preconditionFailure("A pack expands within the containing parameter list or tuple.")
            case .function:
                let pointer = try CValueType(scalar: ABIValuePointer)
                return try CValueType(fields: [pointer, pointer])
            case .foreignFunction, .objectiveCClass:
                return try CValueType(scalar: ABIValuePointer)
            case .borrowing, .consuming, .inoutValue:
                throw ABIResolutionError.unsupportedDeclaration("Generic ownership arguments require their underlying value convention.")
            }
        }
        return try _openExistential(actual, do: prepare)
    }

    private static func tupleLayout(_ fields: [SwiftFormalType], actual: Any.Type,
                                    binding: SwiftGenericBinding) throws -> CValueType {
        let elements = try tupleElements(fields, actual: actual, binding: binding)
        let native = ABISwiftGetValueLayout(unsafeBitCast(actual, to: UnsafeRawPointer.self))
        var types: [CValueType] = [], offsets: [Int] = []
        var index = 0
        for field in fields {
            let offset = index < elements.count ? elements[index].offset : native.size
            offsets.append(offset)
            if case .pack(let pattern, let shape) = field {
                let count = try binding.packCount(in: shape ?? pattern)
                let selected = elements[index..<(index + count)]
                let layouts = try selected.map { try SwiftGenericParameters.storageType($0.type) }
                let positions = selected.map { $0.offset - offset }
                let size = zip(positions, layouts).map { $0.0 + $0.1.size }.max() ?? 0
                types.append(try CValueType(swiftTuple: layouts, offsets: positions, size: size,
                    alignment: layouts.map(\.alignment).max() ?? 1, isPack: true))
                index += count
            } else {
                types.append(try layout(field, actual: elements[index].type, binding: binding))
                index += 1
            }
        }
        return try CValueType(swiftTuple: types, offsets: offsets, size: native.size, alignment: native.alignment)
    }

    private static func singletonMetatype(_ type: SwiftFormalType, binding: SwiftGenericBinding) throws -> Bool {
        let type = try binding.canonicalType(of: type)
        if case .metatype(let instance) = type { return try singletonMetatype(instance, binding: binding) }
        if binding.isArchetype(type) { return false }
        return try !(binding.types(type)[0] is AnyClass)
    }
}

extension SwiftFormalType {
    var argumentConvention: (value: Self, convention: SwiftArgumentConvention)? {
        switch self {
        case .borrowing(let value): (value, .borrowing)
        case .consuming(let value): (value, .consuming)
        case .inoutValue(let value): (value, .inoutValue)
        default: nil
        }
    }
}

extension SwiftGenericBinding {
    func conventionArgument(_ actual: Any.Type, for formal: SwiftFormalType, defaultConsuming: Bool) throws
        -> (wrapper: any SwiftConventionArgument.Type, value: SwiftFormalType)? {
        if let convention = formal.argumentConvention {
            guard let wrapper = actual as? any SwiftConventionArgument.Type, wrapper.convention == convention.convention else {
                throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling + " with its Swift argument wrapper",
                    found: [String(reflecting: actual)]))
            }
            if dependsOnParameters(convention.value) { try validateArgument(wrapper.wrappedType, for: convention.value) }
            return (wrapper, convention.value)
        }
        guard let wrapper = actual as? any SwiftConventionArgument.Type else { return nil }
        // A wrapper can itself be the explicitly bound T. In that case its
        // ordinary Swift value is passed, without applying an argument marker.
        do { try validate(actual, for: formal); return nil }
        catch ABIResolutionError.signatureMismatch {}
        guard wrapper.convention == (defaultConsuming ? .consuming : .borrowing) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "The declaration's default argument ownership", found: [String(reflecting: actual)]))
        }
        if dependsOnParameters(formal) { try validateArgument(wrapper.wrappedType, for: formal) }
        return (wrapper, formal)
    }

    func dependsOnParameters(_ type: SwiftFormalType) -> Bool {
        return switch type {
        case .objectiveCClass, .opaqueResult: false
        case .constrainedExistential(_, let superclass, let constraints, _):
            (superclass.map(dependsOnParameters) ?? false) || constraints.contains { dependsOnParameters($0.value) }
        case .named(let name, let parameters):
            (parameters.isEmpty && arguments[String(name.prefix { $0 != "." })] != nil) || parameters.contains(where: dependsOnParameters)
        case .nominal(_, let parameters), .reference(_, let parameters): parameters.contains(where: dependsOnParameters)
        case .nested(let parent, _, let parameters): dependsOnParameters(parent) || parameters.contains(where: dependsOnParameters)
        case .associated(let base, _, _): dependsOnParameters(base)
        case .tuple(let fields, _), .packValue(let fields): fields.contains(where: dependsOnParameters)
        case .function(let parameters, let result, let failure, _):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result) || (failure.map(dependsOnParameters) ?? false)
        case .foreignFunction(_, let parameters, let result):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result)
        case .pack(let type, let shape): dependsOnParameters(type) || (shape.map(dependsOnParameters) ?? false)
        case .borrowing(let type), .consuming(let type), .inoutValue(let type), .metatype(let type), .existentialMetatype(let type):
            dependsOnParameters(type)
        }
    }
}

extension ABIRuntime {
    func preparedGenericFunction<Signature>(
        symbol: ResolvedSymbol, signature: Signature.Type, genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String? = nil, valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftFunction<Signature> {
        let plan = try SwiftGenericCallPlan(symbol: symbol, genericArguments: genericArguments,
                                            signature: SwiftFunctionSignature(signature), resolver: resolver, declaredSignature: declaredSignature, valueABIs: valueABIs)
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver, generic: plan)
    }
}
