import ABIBridgeRuntime
import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
    indirect case convention(SwiftConventionCodec)
    case value(CValueType, consuming: Bool)
    case closure(SwiftGenericClosurePlan, asynchronous: Bool = false)
    case runtimeValue(
        SwiftRuntimeValuePlan,
        convention: SwiftArgumentConvention,
        asynchronous: Bool
    )
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

    init(
        addresses: [UnsafeMutableRawPointer?],
        storage: [NativeValueStorage],
        borrows: [SwiftValueBorrow]
    ) {
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

    init(
        transport: Transport,
        parameters: SwiftGenericParameters,
        discriminator: UInt16,
        authentication: String,
        isEscaping: Bool,
        resultConstants: SwiftValueConstants,
        errorPlan: SwiftErrorPlan?,
        runtimeArguments: [SwiftCallbackRuntimeArgument?],
        result: SwiftGenericResult,
        nativeResult: Any.Type,
        hostParameters: [Any.Type],
        nativeParameters: [Any.Type]? = nil,
        nativeArgumentClosures: [SwiftGenericClosurePlan?]? = nil,
        nativeResultClosure: SwiftGenericClosurePlan? = nil
    ) {
        self.transport = transport; self.parameters = parameters; self.discriminator = discriminator
        self.authentication = authentication; self.isEscaping = isEscaping;
        self.resultConstants = resultConstants
        self.errorPlan = errorPlan; self.runtimeArguments = runtimeArguments; self.result = result;
        self.nativeResult = nativeResult
        self.nativeParameters =
            nativeParameters
            ?? zip(hostParameters, parameters.arguments).map { host, argument in
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
                return .convention(
                    try convention.makeArgumentCodec(generic: argument(convention.wrappedType))
                )
            }
            if let tuple = try SwiftGenericCallPlan.concreteTuple(type, position: .parameter) {
                return .tuple(tuple, asynchronous: signature.isAsync)
            }
            if let closure = type as? any SwiftClosureValue.Type {
                return .closure(
                    try concrete(closure.swiftFunctionType),
                    asynchronous: signature.isAsync
                )
            }
            return .concrete
        }
        let arguments = try signature.parameters.map(argument)
        let parameterPlan = SwiftGenericParameters(
            actual: signature.parameters,
            arguments: arguments
        )
        let logicalTypes = try zip(signature.parameters, arguments).map { type, argument in
            func layout<Value>(_ type: Value.Type) throws -> CValueType {
                try SwiftArgumentCodec<Value>(defaultConsuming: false, generic: argument).type
            }
            return try _openExistential(type, do: layout)
        }
        let result: SwiftGenericResult
        if let tuple = try SwiftGenericCallPlan.concreteTuple(signature.result, position: .result) {
            result = .tuple(tuple)
        } else if let closure = signature.result as? any SwiftClosureValue.Type {
            result = .closure(
                try closure.makeGenericClosureCodec(plan: concrete(closure.swiftFunctionType))
            )
        } else {
            func layout<Value>(_ type: Value.Type) throws -> CValueType {
                try SwiftValueCodec<Value>(position: .result).type
            }
            result = .value(try _openExistential(signature.result, do: layout))
        }
        let nativeResult = try SwiftGenericCallPlan.concreteNativeMetadata(signature.result)
        let nativeParameters = try signature.parameters.map {
            try SwiftGenericCallPlan.concreteNativeMetadata(
                ($0 as? any SwiftConventionArgument.Type)?.wrappedType ?? $0
            )
        }
        let resultType = result.type!
        let types = parameterPlan.types(from: logicalTypes)
        let errorPlan = try signature.makeErrorPlan()
        let transport: Transport =
            signature.isAsync
            ? .asynchronous(
                try SwiftAsyncCallInterface(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan,
                    inheritsCallerIsolation: signature.inheritsCallerIsolation
                ),
                inheritsCallerIsolation: signature.inheritsCallerIsolation
            )
            : .synchronous(
                try SwiftCallInterface.cached(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan
                )
            )
        return SwiftGenericClosurePlan(
            transport: transport,
            parameters: parameterPlan,
            discriminator: try signature.closureDiscriminator(),
            authentication: try signature.closureAuthDescription(),
            isEscaping: false,
            resultConstants: SwiftValueConstants(nativeResult),
            errorPlan: errorPlan,
            runtimeArguments: Array(repeating: nil, count: arguments.count),
            result: result,
            nativeResult: nativeResult,
            hostParameters: signature.parameters,
            nativeParameters: nativeParameters
        )
    }

    // Copying opaque generic data does not require the bridge to invoke it.
    // A callable plan is optional until a function boundary needs reabstraction.
    static func closureInStoredValue(_ type: Any.Type) -> SwiftGenericClosurePlan? {
        guard runtimeMetadataKind(type) == .function else { return nil }
        return try? nativeValue(type)
    }

    // A function stored inside an erased native value has the maximally
    // abstracted Swift convention: each value, including a tuple or Void
    // result, occupies one indirect slot. Nested functions retain that same
    // storage convention until a formal function boundary reabstracts them.
    static func nativeValue(_ type: Any.Type) throws -> SwiftGenericClosurePlan {
        let signature = try SwiftFunctionSignature(type, nativeConventions: true)
        let escaping = try withRuntimeErrors { try RuntimeFunctionMetadata(type).isEscaping }
        var arguments: [SwiftGenericArgument] = [], types: [CValueType] = []
        var nativeClosures: [SwiftGenericClosurePlan?] = []
        for (type, convention) in zip(signature.parameters, signature.parameterConventions) {
            let layout = try SwiftValueSchema.storage(of: type)
            let argument: SwiftGenericArgument
            if convention == .inoutValue {
                func prepare<Value>(_ type: Value.Type) throws -> SwiftConventionCodec {
                    try NativeSwiftInout<Value>.makeArgumentCodec(
                        generic: .value(layout, consuming: false)
                    )
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
        let resultType = try SwiftValueSchema.storage(of: signature.result)
        let resultClosure = closureInStoredValue(signature.result)
        let errorType =
            try signature.failure == Never.self || signature.failure == (any Error).self
            ? nil : SwiftValueSchema.storage(of: signature.failure)
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: Transport =
            signature.isAsync
            ? .asynchronous(
                try SwiftAsyncCallInterface(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan,
                    inheritsCallerIsolation: signature.inheritsCallerIsolation
                ),
                inheritsCallerIsolation: signature.inheritsCallerIsolation
            )
            : .synchronous(
                try SwiftCallInterface.cached(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan
                )
            )
        let authentication =
            (signature.isAsync && signature.inheritsCallerIsolation ? ["-class"] : [])
            + Array(repeating: "-indirect", count: types.count)
        return SwiftGenericClosurePlan(
            transport: transport,
            parameters: SwiftGenericParameters(actual: signature.parameters, arguments: arguments),
            discriminator: swiftClosureDiscriminator(
                parameters: authentication,
                results: ["-indirect"]
            ),
            authentication: swiftClosureAuthDescription(
                parameters: authentication,
                results: ["-indirect"]
            ),
            isEscaping: escaping,
            resultConstants: SwiftValueConstants(Void.self),
            errorPlan: errorPlan,
            runtimeArguments: Array(repeating: nil, count: arguments.count),
            result: .value(resultType),
            nativeResult: signature.result,
            hostParameters: signature.parameters,
            nativeParameters: signature.parameters,
            nativeArgumentClosures: nativeClosures,
            nativeResultClosure: resultClosure
        )
    }

    var convertsArguments: Bool {
        runtimeArguments.contains { $0 != nil }
            || parameters.arguments.contains {
                switch $0 {
                case .closure, .convention: true;
                case .tuple(let plan, _, _): plan.needsConversion;
                default: false
                }
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
                throw ABIResolutionError.unsupportedDeclaration(
                    "A host callback returning a runtime value requires throws(any Error) to report type and ownership failures."
                )
            }
        }
    }

    func makeCallbackResultStorage() -> NativeValueStorage? {
        guard case .runtimeValue = result else { return nil }
        return NativeValueStorage(
            size: MemoryLayout<NativeSwiftValue>.stride,
            alignment: MemoryLayout<NativeSwiftValue>.alignment
        )
    }

    // Conversion runs only after a successful host return. Native failure leaves
    // result storage uninitialized; an invalid handle keeps its native value.
    func encodeCallbackResult(
        _ storage: NativeValueStorage?,
        to output: UnsafeMutableRawPointer,
        errorOutput: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let storage, case .runtimeValue(let plan) = result else {
            resultConstants.initialize(at: output)
            return false
        }
        let value = plan.takeHostValue(from: storage)
        do {
            let source = try plan.encode(value, convention: .consuming, asynchronous: false)
            SwiftValueCodeLifetime.connect(
                [SwiftValueCodeLifetime.current, source.codeLifetime].compactMap { $0 },
                retaining: []
            )
            ABISwiftTakeValue(
                unsafeBitCast(plan.valueType.metadata, to: UnsafeRawPointer.self),
                output,
                source.address
            )
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
        guard authentication == other.authentication,
            parameters.groups.count == other.parameters.groups.count
        else { return false }
        switch (transport, other.transport) {
        case (.synchronous, .synchronous): break
        case (.asynchronous(_, let first), .asynchronous(_, let second)) where first == second:
            break
        default: return false
        }
        switch (errorPlan, other.errorPlan) {
        case (.none, .none): break
        case (.some(let first), .some(let second)):
            guard first.identity == second.identity, first.isTyped == second.isTyped,
                ABIValueTypesEqual(first.type.handle, second.type.handle)
            else { return false }
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

    private static func sameTupleABI(
        _ first: SwiftTupleValuePlan,
        _ second: SwiftTupleValuePlan
    ) -> Bool {
        guard first.leaves.count == second.leaves.count else { return false }
        for (first, second) in zip(first.leaves, second.leaves) {
            guard first.nativeOffset == second.nativeOffset,
                ABIValueTypesEqual(first.type.handle, second.type.handle)
            else { return false }
            switch (
                first.nativeClosure ?? first.argument.closure,
                second.nativeClosure ?? second.argument.closure
            ) {
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
        let sameParameters =
            nativeParameterTypes.count == other.nativeParameterTypes.count
            && nativeParameterTypes.indices.allSatisfy { index in
                (nativeArgumentClosures[index] != nil && other.nativeArgumentClosures[index] != nil)
                    || nativeParameterTypes[index] == other.nativeParameterTypes[index]
            }
        let sameResult =
            (nativeResultClosure != nil && other.nativeResultClosure != nil)
            || nativeResult == other.nativeResult
        guard sameParameters, sameResult else {
            throw ABIResolutionError.signatureMismatch(
                .init(expected: "The closure's native argument and result types", found: [])
            )
        }
        guard parameters.arguments.map(\.convention) == other.parameters.arguments.map(\.convention)
        else {
            throw ABIResolutionError.signatureMismatch(
                .init(expected: "The closure's native argument ownership", found: [])
            )
        }
        for index in parameters.arguments.indices {
            if parameters.arguments[index].tuple != nil
                || other.parameters.arguments[index].tuple != nil
            {
                continue
            }
            switch (nativeArgumentClosures[index], other.nativeArgumentClosures[index]) {
            case (.some(let expected), .some(let incoming)):
                guard !expected.isEscaping || incoming.isEscaping else {
                    throw ABIResolutionError.signatureMismatch(
                        .init(
                            expected:
                                "An escaping nested closure accepted by the original native caller",
                            found: ["A nonescaping input"]
                        )
                    )
                }
                try incoming.validateNativeValues(for: expected)
            case (.none, .none): break
            default:
                throw ABIResolutionError.signatureMismatch(
                    .init(expected: "A native closure at the same argument position", found: [])
                )
            }
        }
        if result.tuple != nil || other.result.tuple != nil { return }
        switch (nativeResultClosure, other.nativeResultClosure) {
        case (.some(let produced), .some(let expected)):
            try produced.validateNativeValues(for: expected)
        case (.none, .none): break
        default:
            throw ABIResolutionError.signatureMismatch(
                .init(expected: "The closure's native result representation", found: [])
            )
        }
    }

    func decodeArguments(
        _ native: UnsafePointer<UnsafeMutableRawPointer?>?
    ) -> SwiftCallbackArguments? {
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
                let borrow = SwiftValueBorrow(
                    UnsafeRawPointer(addresses[index]!),
                    allowsSuspension: conversion.asynchronous,
                    allowsMutation: conversion.convention == .inoutValue
                )
                borrows.append(borrow)
                value = NativeValueStorage(
                    size: MemoryLayout<NativeSwiftBorrowedValue>.stride,
                    alignment: MemoryLayout<NativeSwiftBorrowedValue>.alignment,
                    codeLifetime: lifetime
                )
                if plan.optionalPayload == nil {
                    value.initialize(NativeSwiftBorrowedValue(type: type, borrow: borrow))
                } else {
                    value.initialize(plan.borrowOptional(at: addresses[index]!, borrow: borrow, lifetime: lifetime))
                }
            } else if plan.projection == nil {
                value = NativeValueStorage(
                    size: MemoryLayout<NativeSwiftValue>.stride,
                    alignment: MemoryLayout<NativeSwiftValue>.alignment,
                    codeLifetime: lifetime
                )
                value.initialize(plan.copyCallbackArgument(from: addresses[index]!, type: type))
            } else {
                value = plan.hostStorage(plan.project(plan.copyCallbackStorage(from: addresses[index]!, type: type)),
                                         codeLifetime: lifetime)
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

    init(
        entry: SwiftEntry,
        genericArguments: [NativeSwiftGenericArgument],
        signature: SwiftFunctionSignature,
        resolver: SymbolResolver,
        enclosing: SwiftGenericTypeMetadata? = nil,
        implicitSelf: NativeSwiftType? = nil,
        receiver: SwiftReceiverMode? = nil,
        declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws {
        let context = try (implicitSelf == nil ? enclosing : nil).flatMap {
            $0.arguments.isEmpty ? nil : try SwiftGenericTypeContext(metadata: $0.value)
        }
        let declared = try declaredSignature.map(SwiftDeclaredSignature.init)
        let declaration = try SwiftGenericDeclaration(
            linkageName: entry.linkageName,
            enclosing: context,
            declaredSignature: declared,
            caller: signature
        )
        let implicitArguments = implicitSelf.map { [.type($0)] } ?? enclosing?.arguments ?? []
        // Callers supply only the parameters the declaration itself introduces.
        let introduced = declaration.parameters.count - implicitArguments.count
        guard genericArguments.count == introduced else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "\(introduced) generic arguments",
                    found: ["\(genericArguments.count) generic arguments"]
                )
            )
        }
        var binding = try SwiftGenericBinding(
            declaration: declaration,
            arguments: implicitArguments + genericArguments,
            signature: signature,
            resolver: resolver,
            enclosing: context,
            image: entry.provenance,
            valueABIs: valueABIs
        )
        if !declaration.result.opaqueIndices.isEmpty {
            binding.opaqueResults = try SwiftOpaqueResultPlan.resolve(
                entry: entry,
                resolver: resolver,
                indices: declaration.result.opaqueIndices,
                binding: binding
            )
        }
        let opaque = declaration.result.opaqueIndex.flatMap { binding.opaqueResults[$0] }
        if case .function(let arguments, let result, let failure, let attributes) = declared?
            .function
        {
            _ = try SwiftGenericParameters(
                formal: attributes.loweredParameters(arguments),
                actual: signature.parameters,
                binding: binding,
                defaultConsuming: declaration.consumesArguments
            )
            guard attributes.isAsync == declaration.isAsync else {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        expected: "The declaration's async effect",
                        found: [declared!.function.spelling]
                    )
                )
            }
            if let failure {
                try binding.validate(signature.failure, for: failure)
            } else if signature.failure != Never.self {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        expected: "A nonthrowing declaredAs: signature",
                        found: [String(reflecting: signature.failure)]
                    )
                )
            }
            if binding.dependsOnParameters(result) {
                _ = try binding.resultType(signature.result, for: result)
            }
        }
        guard declaration.isAsync == signature.isAsync,
            declaration.failure != nil || signature.failure == Never.self
        else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "The declaration's async and error effects",
                    found: []
                )
            )
        }
        self.binding = binding
        if let failure = declaration.failure {
            try binding.validate(signature.failure, for: failure)
        }
        self.context = context
        self.receiver = receiver
        enclosingMetadata = enclosing?.value
        metadata = SwiftGenericArgumentBuffer(binding.metadataArguments)
        parameters = try SwiftGenericParameters(
            formal: declaration.arguments,
            actual: signature.parameters,
            binding: binding,
            defaultConsuming: declaration.consumesArguments
        )
        // A runtime value handle, Optional or not, takes the opaque result's
        // underlying type from the declaration.
        if let opaque, Self.runtimeHandle(signature.result) == nil {
            _ = try binding.resultType(signature.result, for: declaration.result)
            result = .value(opaque.type)
        } else {
            result = try Self.result(declaration.result, actual: signature.result, binding: binding)
        }
        if let failure = declaration.failure, binding.dependsOnParameters(failure) {
            errorType = try SwiftValueSchema.layout(failure, actual: signature.failure, binding: binding)
        } else {
            errorType = nil
        }
        if let receiver { metadata = try includingReceiver(receiver).metadata }
    }

    func includingReceiver(_ receiver: SwiftReceiverMode) throws -> Self {
        var result = self
        result.receiver = receiver
        let source = try result.receiverMetadata()
        result.metadata = try SwiftGenericArgumentBuffer(
            source.prefix
                + binding.metadataArguments(
                    fulfilledBy: result.receiverContext,
                    additionallyFulfilledBy: source.fulfilled
            )
        )
        return result
    }

    private var receiverContext: SwiftGenericTypeContext? {
        receiver == .object || receiver == .address ? context : nil
    }

    private func receiverMetadata() throws -> (
        prefix: [UInt], fulfilled: SwiftGenericBinding.Fulfillments
    ) {
        if binding.declaration.dispatchProtocol != nil { return ([], .init()) }
        if let formalSelf = binding.declaration.protocolSelf {
            if receiver == .object {
                return ([], try binding.argumentFulfillments([formalSelf]))
            }
            if receiver == .address {
                let canonical = try binding.canonicalType(of: formalSelf)
                if canonical.nominalDeclaration != nil {
                    let fulfilled = try binding.argumentFulfillments([], typeMetadata: [canonical])
                    // An indirect nominal self supplies its metadata before explicit
                    // arguments are considered, even when they fulfill the same types.
                    if !fulfilled.isEmpty {
                        let metadata = try binding.types(canonical)[0]
                        return ([unsafeBitCast(metadata, to: UInt.self)], fulfilled)
                    }
                }
            }
        } else if let context = receiverContext {
            let fulfilled = try binding.argumentFulfillments(
                [],
                typeMetadata: context.parameters.filter {
                    context.keyParameters.contains($0.name)
                }.map { .named($0.name, []) }
            )
            if receiver == .address, let enclosingMetadata {
                return ([unsafeBitCast(enclosingMetadata, to: UInt.self)], fulfilled)
            }
            return ([], fulfilled)
        }
        return ([], .init())
    }

    func validateMetadataArguments() throws {
        let source = try receiverMetadata()
        try binding.validateMetadataArguments(
            fulfilledBy: receiverContext,
            additionallyFulfilledBy: source.fulfilled
        )
    }

    var hookEnclosingClass: AnyClass? {
        get throws {
            guard receiver == .object else { return nil }
            if context != nil { return enclosingMetadata as? AnyClass }
            if let formalSelf = binding.declaration.protocolSelf,
                !binding.isArchetype(try binding.canonicalType(of: formalSelf))
            {
                return try binding.types(formalSelf)[0] as? AnyClass
            }
            return nil
        }
    }

    func hookMetadataArguments() throws -> [SwiftGenericBinding.HookMetadataArgument] {
        let source = try receiverMetadata()
        return try source.prefix.map { .value($0) }
            + binding.hookMetadataArguments(
                fulfilledBy: receiverContext,
                additionallyFulfilledBy: source.fulfilled
            )
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
                guard argument.convention != .inoutValue, binding.dependsOnParameters(formal) else {
                    continue
                }
                if let tuple {
                    add(tuple, at: nativeIndex)
                } else {
                    let value = formal.argumentConvention?.value ?? formal
                    let native = try binding.types(value)[0]
                    add(
                        native,
                        layout: try SwiftValueSchema.layout(
                            value,
                            actual: native,
                            binding: binding,
                            position: .parameter
                        ),
                        at: nativeIndex
                    )
                }
            }
        }
        return sources
    }

    func receiverType() throws -> CValueType? {
        if let formalSelf = binding.declaration.protocolSelf {
            return try SwiftValueSchema.layout(
                formalSelf,
                actual: binding.types(formalSelf)[0],
                binding: binding,
                position: .parameter
            )
        }
        guard let context, let enclosingMetadata, !(enclosingMetadata is AnyClass) else {
            return nil
        }
        let arguments = context.parameters.map { SwiftFormalType.named($0.name, []) }
        return try SwiftValueSchema.isIndirect(
            enclosingMetadata,
            arguments: arguments,
            binding: binding
        )
            ? SwiftValueSchema.storage(of: enclosingMetadata) : nil
    }

    /// Checks that a call with the requested signature can use this
    /// declaration, reporting the first incompatible argument or the result.
    ///
    /// Only the call's own arguments and result convert class references.
    /// Values reached through `inout` and other conventions, tuples, and
    /// closures stay exact, because their values can flow the other way.
    ///
    /// - Parameter representations: Host types that stand for native types,
    ///   such as the representation a member's owner was resolved with. A
    ///   representation applies only where the requested type itself does not.
    func check(
        _ signature: SwiftFunctionSignature,
        representations: [ObjectIdentifier: Any.Type] = [:]
    ) throws {
        func represented(_ type: Any.Type) -> Any.Type? {
            if let native = representations[ObjectIdentifier(type)] { return native }
            guard let optional = type as? any NativeOptionalValue.Type,
                let native = representations[ObjectIdentifier(optional.wrappedType)]
            else { return nil }
            func optionalType<Wrapped>(_: Wrapped.Type) -> Any.Type { Wrapped?.self }
            return optionalType(native)
        }
        func accepting(_ requested: Any.Type, _ accepts: (Any.Type) throws -> Void) throws {
            do {
                try accepts(requested)
            } catch let error as ABIResolutionError {
                guard case .signatureMismatch = error, let native = represented(requested) else {
                    throw error
                }
                do { try accepts(native) } catch ABIResolutionError.signatureMismatch { throw error }
            }
        }
        func validate(
            _ actual: Any.Type,
            for formal: SwiftFormalType,
            using binding: SwiftGenericBinding,
            at index: Int
        ) throws {
            do {
                if formal.argumentConvention == nil,
                    !(actual is any SwiftConventionArgument.Type),
                    binding.convertsReference(actual, for: formal, isResult: false)
                {
                    return
                }
                if let argument = try binding.conventionArgument(
                    actual,
                    for: formal,
                    defaultConsuming: binding.declaration.consumesArguments
                ) {
                    try accepting(argument.wrapper.wrappedType) {
                        try binding.validateArgument($0, for: argument.value)
                    }
                } else {
                    try accepting(actual) { try binding.validateArgument($0, for: formal) }
                }
            } catch let ABIResolutionError.signatureMismatch(mismatch) {
                throw ABIResolutionError.signatureMismatch(mismatch.at(.argument(index)))
            }
        }
        for (formal, group) in zip(binding.declaration.arguments, parameters.groups) {
            switch group {
            case .value(let index):
                try validate(signature.parameters[index], for: formal, using: binding, at: index)
            case .pack(let range, _):
                guard case .pack(let pattern, _) = formal else {
                    preconditionFailure("A pack group has a pack formal type.")
                }
                for (packIndex, index) in range.enumerated() {
                    try validate(
                        signature.parameters[index],
                        for: pattern,
                        using: binding.selectingPackElement(at: packIndex),
                        at: index
                    )
                }
            }
        }
        do {
            try accepting(signature.result) { result in
                guard !binding.convertsReference(result, for: binding.declaration.result, isResult: true)
                else { return }
                _ = try binding.resultType(result, for: binding.declaration.result)
            }
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            throw ABIResolutionError.signatureMismatch(mismatch.at(.result))
        }
    }

    /// Whether a call converts a class reference at some position, which a
    /// hook cannot do in the opposite direction.
    func convertsReferences(_ signature: SwiftFunctionSignature) -> Bool {
        zip(binding.declaration.arguments, parameters.groups).contains { formal, group in
            guard case .value(let index) = group else { return false }
            return binding.convertsReference(signature.parameters[index], for: formal, isResult: false)
        } || binding.convertsReference(signature.result, for: binding.declaration.result, isResult: true)
    }

    /// - Parameter position: `.parameter` for a whole parameter, or the
    ///   position of a tuple element.
    static func argument(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding,
        defaultConsuming: Bool = false,
        asynchronous: Bool? = nil,
        callback: Bool = false,
        position: SwiftValuePosition = .parameter
    ) throws -> SwiftGenericArgument {
        if callback, case .inoutValue(let pointee) = formal, actual == NativeSwiftBorrowedValue.self
        {
            let metadata = try binding.types(pointee)[0]
            return .runtimeValue(
                try runtimeValue(
                    pointee,
                    metadata: metadata,
                    binding: binding,
                    asynchronous: asynchronous ?? binding.declaration.isAsync,
                    handle: SwiftRuntimeHandle(type: NativeSwiftBorrowedValue.self, projection: .none),
                    position: position
                ),
                convention: .inoutValue,
                asynchronous: asynchronous ?? binding.declaration.isAsync
            )
        }
        if let argument = try binding.conventionArgument(
            actual,
            for: formal,
            defaultConsuming: defaultConsuming
        ) {
            let value = try Self.argument(
                argument.value,
                actual: argument.wrapper.wrappedType,
                binding: binding,
                defaultConsuming: argument.wrapper.convention == .consuming,
                asynchronous: asynchronous,
                position: position
            )
            return .convention(try argument.wrapper.makeArgumentCodec(generic: value))
        }
        if let handle = runtimeHandle(actual) {
            let metadata = try binding.types(formal)[0]
            // A generic parameter can bind the handle type itself.
            if metadata != actual {
                guard handle.type != NativeSwiftBorrowedValue.self || !defaultConsuming else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A borrowed runtime value cannot be consumed."
                    )
                }
                return .runtimeValue(
                    try runtimeValue(
                        formal,
                        metadata: metadata,
                        binding: binding,
                        asynchronous: asynchronous ?? binding.declaration.isAsync,
                        handle: handle,
                        position: position
                    ),
                    convention: defaultConsuming ? .consuming : .borrowing,
                    asynchronous: asynchronous ?? binding.declaration.isAsync
                )
            }
        }
        if let (function, closure) = try binding.closureFunction(formal, for: actual) {
            return .closure(
                try Self.closure(
                    function,
                    signature: SwiftFunctionSignature(closure.swiftFunctionType),
                    binding: binding
                ),
                asynchronous: asynchronous ?? binding.declaration.isAsync
            )
        }
        if representsClosedValue(formal, actual: actual, binding: binding) {
            if let explicit = try binding.explicitHostValueType(actual) {
                return .value(explicit, consuming: false)
            }
            try binding.validateInferredHostValue(actual, for: formal)
            guard
                let tuple = try concreteTuple(
                    actual,
                    explicitLayout: binding.explicitHostValueType,
                    position: position
                )
            else { return .concrete }
            return .tuple(
                tuple,
                consuming: defaultConsuming,
                asynchronous: asynchronous ?? binding.declaration.isAsync
            )
        }
        let canonical = try binding.canonicalType(of: formal)
        if case .tuple = canonical {
            return .tuple(
                try tuple(
                    canonical,
                    actual: actual,
                    binding: binding,
                    asynchronous: asynchronous ?? binding.declaration.isAsync,
                    position: position
                ),
                consuming: defaultConsuming,
                asynchronous: asynchronous ?? binding.declaration.isAsync
            )
        }
        guard binding.dependsOnParameters(formal) || !formal.opaqueIndices.isEmpty else {
            return .concrete
        }
        try binding.validate(actual, for: formal)
        return .value(
            try SwiftValueSchema.layout(formal, actual: actual, binding: binding, position: position),
            consuming: false
        )
    }

    /// Whether the host type alone lowers a value whose native type has no
    /// generic or opaque part. Such a host type can be an adapter with a
    /// different Swift name, so its codec takes precedence over the formal
    /// type; closures and runtime values still need the declaration.
    private static func representsClosedValue(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding
    ) -> Bool {
        func needsDeclaration(_ type: Any.Type) -> Bool {
            if type is any SwiftClosureValue.Type || runtimeHandle(type) != nil {
                return true
            }
            if let convention = type as? any SwiftConventionArgument.Type {
                return needsDeclaration(convention.wrappedType)
            }
            if let tuple = SwiftTupleMetadata(type) {
                return tuple.elements.contains { needsDeclaration($0.type) }
            }
            return false
        }
        return !binding.dependsOnParameters(formal) && formal.opaqueIndices.isEmpty
            && !needsDeclaration(actual)
    }

    /// - Parameter position: `.result` for a whole result, or the position of
    ///   a tuple element.
    static func result(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding,
        position: SwiftValuePosition = .result
    ) throws -> SwiftGenericResult {
        if let handle = runtimeHandle(actual) {
            let metadata = try binding.types(formal)[0]
            if metadata != actual {
                return .runtimeValue(
                    try runtimeValue(
                        formal,
                        metadata: metadata,
                        binding: binding,
                        handle: handle,
                        position: position
                    )
                )
            }
        }
        if representsClosedValue(formal, actual: actual, binding: binding) {
            if let explicit = try binding.explicitHostValueType(actual) { return .value(explicit) }
            try binding.validateInferredHostValue(actual, for: formal)
            if try binding.hasExplicitHostField(actual),
                let tuple = try concreteTuple(
                    actual,
                    explicitLayout: binding.explicitHostValueType,
                    position: position
                )
            {
                return .tuple(tuple)
            }
            return .concrete
        }
        let canonical = try binding.canonicalType(of: formal)
        if case .tuple = canonical {
            return .tuple(try tuple(canonical, actual: actual, binding: binding, position: position))
        }
        if let (function, closure) = try binding.closureFunction(canonical, for: actual) {
            let plan = try Self.closure(
                function,
                signature: SwiftFunctionSignature(closure.swiftFunctionType),
                binding: binding
            )
            return .closure(try closure.makeGenericClosureCodec(plan: plan))
        }
        if binding.dependsOnParameters(formal) || !formal.opaqueIndices.isEmpty {
            let native = try binding.resultType(actual, for: formal)
            return .value(
                try SwiftValueSchema.layout(formal, actual: native, binding: binding, position: position)
            )
        }
        return .concrete
    }

    /// The runtime value handle a host type stands for. `NativeSwiftValue?`
    /// and `NativeSwiftBorrowedValue?` stand for a native Optional, with nil
    /// as its empty case, and a host collection of `NativeSwiftValue` for a
    /// native Array, Set, or Dictionary.
    static func runtimeHandle(_ actual: Any.Type) -> SwiftRuntimeHandle? {
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            return SwiftRuntimeHandle(type: actual, projection: .none)
        }
        if actual == NativeSwiftValue?.self { return SwiftRuntimeHandle(type: NativeSwiftValue.self, projection: .optional) }
        if actual == NativeSwiftBorrowedValue?.self {
            return SwiftRuntimeHandle(type: NativeSwiftBorrowedValue.self, projection: .optional)
        }
        if let collection = SwiftHostCollection(actual) {
            return SwiftRuntimeHandle(type: NativeSwiftValue.self, projection: .collection(collection))
        }
        return nil
    }

    private static func runtimeValue(
        _ formal: SwiftFormalType,
        metadata: Any.Type,
        binding: SwiftGenericBinding,
        asynchronous: Bool = false,
        handle: SwiftRuntimeHandle,
        position: SwiftValuePosition
    ) throws -> SwiftRuntimeValuePlan {
        let canonical = try binding.canonicalType(of: formal)
        // A stored closure needs its closure plan, which runtime values do not
        // yet derive through an Optional (#427).
        if let wrapped = canonical.optionalWrapped, case .function = try binding.canonicalType(of: wrapped) {
            throw ABIResolutionError.unsupportedDeclaration(
                "A runtime value of an Optional closure is unsupported: \(canonical.spelling)."
            )
        }
        let nativeTuple: SwiftTupleValuePlan?
        if case .tuple = canonical {
            nativeTuple = try tuple(
                canonical,
                actual: metadata,
                binding: binding,
                asynchronous: asynchronous,
                nativeStorage: true,
                position: position
            )
        } else {
            nativeTuple = nil
        }
        let nativeClosure: SwiftGenericClosurePlan?
        if case .function = canonical {
            nativeClosure = try nativeClosurePlan(canonical, binding: binding)
        } else if nativeTuple == nil {
            nativeClosure = SwiftGenericClosurePlan.closureInStoredValue(metadata)
        } else {
            nativeClosure = nil
        }
        let plan = try binding.runtimeValuePlan(
            metadata: metadata,
            type: SwiftValueSchema.layout(formal, actual: metadata, binding: binding, position: position),
            nativeTuple: nativeTuple,
            nativeClosure: nativeClosure
        )
        return try handle.apply(to: plan)
    }

    static func nativeClosurePlan(
        _ formal: SwiftFormalType,
        binding: SwiftGenericBinding
    ) throws -> SwiftGenericClosurePlan {
        try closure(
            formal,
            signature: SwiftFunctionSignature(nativeClosureSignature(formal, binding: binding)),
            binding: binding
        )
    }

    /// - Parameter position: The tuple's own position. Elements of a
    ///   parameter are whole parameters; elements of a result are nested.
    static func tuple(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding,
        asynchronous: Bool = false,
        nativeStorage: Bool = false,
        position: SwiftValuePosition = .nested
    ) throws -> SwiftTupleValuePlan {
        guard case .tuple(let fields, let labels) = formal else {
            preconditionFailure("A tuple plan requires its formal tuple declaration.")
        }
        let hostElements = try tupleElements(fields, actual: actual, binding: binding)
        let native = try binding.types(formal)[0]
        let nativeElements = try tupleElements(fields, actual: native, binding: binding)
        let expectedLabels = try fields.enumerated().flatMap { index, field -> [String] in
            let count: Int
            if case .pack(let pattern, let shape) = field {
                count = try binding.packCount(in: shape ?? pattern)
            } else {
                count = 1
            }
            return Array(repeating: labels?[index] ?? "", count: count)
        }
        if hostElements.count != 1, let host = SwiftTupleMetadata(actual),
            host.labels != expectedLabels
        {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: formal.spelling,
                    found: [String(reflecting: actual)]
                )
            )
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
                let value = try tuple(
                    canonical,
                    actual: host.type,
                    binding: binding,
                    asynchronous: asynchronous,
                    nativeStorage: nativeStorage,
                    position: position.tupleElement
                )
                nested = value; argument = .tuple(value, asynchronous: asynchronous);
                result = .tuple(value)
            } else if nativeStorage {
                nested = nil
                let type = try SwiftValueSchema.layout(
                    field,
                    actual: native.type,
                    binding: binding,
                    position: position.tupleElement
                )
                argument = .value(type, consuming: false)
                result = .value(type)
            } else {
                nested = nil
                try binding.validateArgument(host.type, for: field, position: position.tupleElement)
                argument = try Self.argument(
                    field,
                    actual: host.type,
                    binding: binding,
                    asynchronous: asynchronous,
                    position: position.tupleElement
                )
                result = try Self.result(
                    field,
                    actual: host.type,
                    binding: binding,
                    position: position.tupleElement
                )
            }
            let nativeClosure: SwiftGenericClosurePlan?
            if nativeStorage, case .function = canonical {
                nativeClosure = try Self.closure(
                    canonical,
                    signature: SwiftFunctionSignature(
                        nativeClosureSignature(canonical, binding: binding)
                    ),
                    binding: binding
                )
            } else {
                nativeClosure = nil
            }
            prepared.append(
                try .init(
                    hostType: host.type,
                    nativeType: native.type,
                    hostOffset: host.offset,
                    nativeOffset: native.offset,
                    argument: argument,
                    result: result,
                    tuple: nested,
                    nativeClosure: nativeClosure,
                    position: position.tupleElement
                )
            )
            index += 1
        }
        for field in fields {
            if case .pack(let pattern, let shape) = field {
                let start = index
                for index in 0..<(try binding.packCount(in: shape ?? pattern)) {
                    try append(pattern, using: binding.selectingPackElement(at: index))
                }
                groups.append(
                    .pack(
                        start..<index,
                        try CValueType(
                            indirectSwiftSize: (index - start) * MemoryLayout<UInt>.size,
                            alignment: MemoryLayout<UInt>.alignment
                        )
                    )
                )
            } else {
                groups.append(.value(index))
                try append(field, using: binding)
            }
        }
        return try SwiftTupleValuePlan(
            hostMetadata: actual,
            nativeMetadata: native,
            type: SwiftValueSchema.tupleLayout(
                fields,
                actual: native,
                binding: binding,
                position: position
            ),
            fields: prepared,
            groups: groups
        )
    }

    // Native tuple storage retains its Swift representation. This signature
    // uses the existing bridge markers only to prepare each formal function's
    // recursive ABI, including ownership, generic indirection, and packs.
    private static func nativeClosureSignature(
        _ formal: SwiftFormalType,
        binding: SwiftGenericBinding
    ) throws -> Any.Type {
        guard case .function(let parameters, let result, let failure, var attributes) = formal
        else {
            preconditionFailure("A native closure signature requires a formal function.")
        }
        var inputs: [Any.Type] = [], parameterFlags: [UInt32] = []
        for (index, parameter) in parameters.enumerated() {
            let flags = attributes.parameterFlags.isEmpty ? 0 : attributes.parameterFlags[index]
            if case .pack(let pattern, let shape) = parameter {
                for element in 0..<(try binding.packCount(in: shape ?? pattern)) {
                    inputs.append(
                        try nativeClosureValueType(
                            pattern,
                            owned: false,
                            binding: binding.selectingPackElement(at: element)
                        )
                    )
                    parameterFlags.append(flags)
                }
            } else {
                inputs.append(try nativeClosureValueType(parameter, owned: false, binding: binding))
                parameterFlags.append(flags)
            }
        }
        let output = try nativeClosureValueType(result, owned: true, binding: binding)
        let error = try failure.map { type in
            type.spelling == "Swift.Error" || type.spelling == "Error"
                ? (any Error).self : try binding.types(type)[0]
        }
        let actor = try attributes.globalActor.map { try binding.types($0)[0] }
        attributes.isEscaping = true
        return try SwiftGenericBinding.functionType(
            parameters: inputs,
            parameterFlags: parameterFlags,
            result: output,
            failure: error,
            attributes: attributes,
            globalActor: actor
        )
    }

    private static func nativeClosureValueType(
        _ formal: SwiftFormalType,
        owned: Bool,
        binding: SwiftGenericBinding
    ) throws -> Any.Type {
        let canonical = try binding.canonicalType(of: formal)
        if let convention = canonical.argumentConvention {
            let wrapped = try nativeClosureValueType(
                convention.value,
                owned: convention.convention != .borrowing,
                binding: binding
            )
            if convention.convention == .inoutValue,
                wrapped == NativeSwiftValue.self
            {
                return NativeSwiftBorrowedValue.self
            }
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
            func marker<Signature>(_ type: Signature.Type) -> Any.Type {
                NativeSwiftClosure<Signature>.self
            }
            return _openExistential(signature, do: marker)
        }
        if case .tuple(let fields, let labels) = canonical {
            var elements: [Any.Type] = [], names: [String] = []
            for (index, field) in fields.enumerated() {
                if case .pack(let pattern, let shape) = field {
                    for element in 0..<(try binding.packCount(in: shape ?? pattern)) {
                        elements.append(
                            try nativeClosureValueType(
                                pattern,
                                owned: owned,
                                binding: binding.selectingPackElement(at: element)
                            )
                        )
                        names.append(labels?[index] ?? "")
                    }
                } else {
                    elements.append(
                        try nativeClosureValueType(field, owned: owned, binding: binding)
                    )
                    names.append(labels?[index] ?? "")
                }
            }
            let pointers = elements.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
            let metadata = pointers.withUnsafeBufferPointer { pointers in
                if names.allSatisfy(\.isEmpty) {
                    return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil)
                }
                return (names.joined(separator: " ") + " ").withCString {
                    ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
                }
            }
            guard let metadata else {
                throw ABIResolutionError.metadataUnavailable(
                    "The tuple exceeds Swift's metadata element count."
                )
            }
            return unsafeBitCast(metadata, to: Any.Type.self)
        }
        return owned ? NativeSwiftValue.self : NativeSwiftBorrowedValue.self
    }

    /// - Parameter explicitLayout: The `valueABIs` layout of a field's host type, if any.
    /// - Parameter position: The tuple's own position. Elements of a
    ///   parameter are whole parameters; elements of a result are nested.
    static func concreteTuple(
        _ actual: Any.Type,
        explicitLayout: (Any.Type) throws -> CValueType? = { _ in nil },
        position: SwiftValuePosition = .nested
    ) throws -> SwiftTupleValuePlan? {
        guard let host = SwiftTupleMetadata(actual) else { return nil }
        let nativeType = try concreteNativeMetadata(actual)
        let native = SwiftTupleMetadata(nativeType)!
        var fields: [SwiftTupleValuePlan.Field] = []
        for (host, native) in zip(host.elements, native.elements) {
            let argument: SwiftGenericArgument
            let result: SwiftGenericResult
            let tuple = try concreteTuple(
                host.type,
                explicitLayout: explicitLayout,
                position: position.tupleElement
            )
            if let tuple {
                argument = .tuple(tuple); result = .tuple(tuple)
            } else if let closure = host.type as? any SwiftClosureValue.Type {
                let plan = try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType)
                argument = .closure(plan)
                result = .closure(try closure.makeGenericClosureCodec(plan: plan))
            } else if let explicit = try explicitLayout(host.type) {
                argument = .value(explicit, consuming: false); result = .value(explicit)
            } else {
                argument = .concrete; result = .concrete
            }
            fields.append(
                try .init(
                    hostType: host.type,
                    nativeType: native.type,
                    hostOffset: host.offset,
                    nativeOffset: native.offset,
                    argument: argument,
                    result: result,
                    tuple: tuple,
                    position: position.tupleElement
                )
            )
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(nativeType, to: UnsafeRawPointer.self))
        return try SwiftTupleValuePlan(
            hostMetadata: actual,
            nativeMetadata: nativeType,
            type: CValueType(
                swiftTuple: fields.map(\.type),
                offsets: fields.map(\.nativeOffset),
                size: layout.size,
                alignment: layout.alignment
            ),
            fields: fields
        )
    }

    static func concreteNativeMetadata(_ actual: Any.Type) throws -> Any.Type {
        if let closure = actual as? any SwiftClosureValue.Type, closure.isOptional {
            func optional<Wrapped>(_: Wrapped.Type) -> Any.Type { Wrapped?.self }
            return try _openExistential(
                concreteNativeMetadata((actual as! any NativeOptionalValue.Type).wrappedType),
                do: optional
            )
        }
        if let closure = actual as? any SwiftClosureValue.Type {
            let function = closure.swiftFunctionType
            let signature = try SwiftFunctionSignature(function)
            var parameterFlags = Array(repeating: UInt32(0), count: signature.parameters.count)
            let parameters = try signature.parameters.enumerated().map { index, type -> Any.Type in
                if let convention = type as? any SwiftConventionArgument.Type {
                    parameterFlags[index] =
                        switch convention.convention {
                        case .inoutValue: 1
                        case .borrowing: 2
                        case .consuming: 3
                        }
                    return try concreteNativeMetadata(convention.wrappedType)
                }
                return try concreteNativeMetadata(type)
            }
            let result = try concreteNativeMetadata(signature.result)
            return try withRuntimeErrors {
                try RuntimeFunctionMetadata(function).replacing(
                    parameters: parameters,
                    result: result,
                    parameterFlags: parameterFlags
                )
            }
        }
        guard let tuple = SwiftTupleMetadata(actual) else { return actual }
        let elements = try tuple.elements.map { try concreteNativeMetadata($0.type) }
        if zip(elements, tuple.elements).allSatisfy({ $0.0 == $0.1.type }) { return actual }
        let pointers = elements.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
        let value = pointers.withUnsafeBufferPointer { pointers in
            if tuple.labels.allSatisfy(\.isEmpty) {
                return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil)
            }
            return (tuple.labels.joined(separator: " ") + " ").withCString {
                ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
            }
        }
        guard let value else {
            throw ABIResolutionError.metadataUnavailable(
                "The tuple exceeds Swift's metadata element count."
            )
        }
        return unsafeBitCast(value, to: Any.Type.self)
    }

    static func closure(
        _ formal: SwiftFormalType,
        signature: SwiftFunctionSignature,
        binding: SwiftGenericBinding
    ) throws -> SwiftGenericClosurePlan {
        guard case .function(let parameters, let result, let failure, let attributes) = formal
        else {
            preconditionFailure("A closure plan requires a function type.")
        }
        let nativeActor = try attributes.globalActor.map { try binding.types($0)[0] }
        guard attributes.isAsync == signature.isAsync,
            nativeActor == signature.globalActor,
            failure != nil || signature.failure == Never.self
        else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        // An opaque-bearing returned function is erased to the ordinary Swift
        // function-value storage convention before it crosses the factory ABI.
        let usesStorageConvention = !formal.opaqueIndices.isEmpty
        var parameterPlan = try SwiftGenericParameters(
            formal: parameters,
            actual: signature.parameters,
            binding: binding,
            asynchronous: attributes.isAsync,
            callback: true
        )
        if usesStorageConvention { parameterPlan = parameterPlan.usingStorageConvention() }
        if let failure { try binding.validate(signature.failure, for: failure) }
        let runtimeArguments: [SwiftCallbackRuntimeArgument?] = parameterPlan.arguments.enumerated()
            .map { index, argument in
                guard case .runtimeValue(let plan, let convention, _) = argument else { return nil }
                let borrowed = Self.runtimeHandle(signature.parameters[index])?.type == NativeSwiftBorrowedValue.self
                return SwiftCallbackRuntimeArgument(
                    plan: plan,
                    borrowed: borrowed,
                    asynchronous: attributes.isAsync,
                    convention: convention
                )
            }
        var logicalTypes: [CValueType] = []
        var nativeParameters: [Any.Type] = []
        var authentication =
            attributes.isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
        for (formal, group) in zip(parameters, parameterPlan.groups) {
            switch group {
            case .pack(let range, _):
                guard case .pack(let pattern, _) = formal else {
                    preconditionFailure("A pack group has a pack formal type.")
                }
                for (packIndex, index) in range.enumerated() {
                    let selected = binding.selectingPackElement(at: packIndex)
                    nativeParameters.append(
                        try selected.types(pattern.argumentConvention?.value ?? pattern)[0]
                    )
                    if let conversion = runtimeArguments[index] {
                        logicalTypes.append(
                            try SwiftValueSchema.storage(
                                of: conversion.plan.valueType.metadata
                            )
                        )
                    } else {
                        try binding.selectingPackElement(at: packIndex).validateArgument(
                            signature.parameters[index],
                            for: pattern
                        )
                        logicalTypes.append(
                            try SwiftValueSchema.storage(of: signature.parameters[index])
                        )
                    }
                }
                // SIL pack values have an opaque type hash, distinct from an
                // ordinary formally indirect scalar (GenPointerAuth.cpp).
                authentication.append("-")
            case .value(let index):
                nativeParameters.append(
                    try binding.types(formal.argumentConvention?.value ?? formal)[0]
                )
                let argument = parameterPlan.arguments[index]
                let actual =
                    argument.runtimeValue?.valueType.metadata ?? signature.parameters[index]
                if case .convention(let codec) = argument {
                    logicalTypes.append(codec.type)
                    let underlying = formal.argumentConvention?.value ?? formal
                    let wrapper = signature.parameters[index] as! any SwiftConventionArgument.Type
                    authentication.append(
                        contentsOf: wrapper.convention == .inoutValue
                            ? ["-indirect"]
                            : try authTypes(
                                underlying,
                                actual: argument.runtimeValue?.valueType.metadata
                                    ?? wrapper.wrappedType,
                                binding: binding
                            )
                    )
                    continue
                }
                if runtimeArguments[index]?.convention == .inoutValue {
                    logicalTypes.append(try CValueType(scalar: ABIValuePointer))
                    authentication.append("-indirect")
                    continue
                }
                if runtimeArguments[index] == nil {
                    try binding.validateArgument(actual, for: formal)
                }
                logicalTypes.append(
                    try SwiftValueSchema.layout(
                        formal,
                        actual: actual,
                        binding: binding,
                        position: .parameter
                    )
                )
                authentication.append(
                    contentsOf: try authTypes(formal, actual: actual, binding: binding)
                )
            }
        }
        if usesStorageConvention {
            logicalTypes = try zip(nativeParameters, parameterPlan.arguments).map {
                metadata,
                argument in
                argument.convention == .inoutValue
                    ? try CValueType(scalar: ABIValuePointer)
                    : try SwiftValueSchema.storage(of: metadata)
            }
            authentication =
                attributes.isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
            authentication += parameterPlan.groups.map {
                if case .pack = $0 { return "-" }
                return "-indirect"
            }
        }
        let types = parameterPlan.types(from: logicalTypes)
        let nativeResult = try binding.resultType(signature.result, for: result)
        let resultType =
            try usesStorageConvention
            ? SwiftValueSchema.storage(of: nativeResult)
            : SwiftValueSchema.layout(
                result,
                actual: nativeResult,
                binding: binding,
                position: .result
            )
        let resultPlan = try Self.result(result, actual: signature.result, binding: binding)
        let errorType = try failure.flatMap {
            if usesStorageConvention && signature.failure != (any Error).self {
                return try SwiftValueSchema.storage(of: signature.failure)
            }
            return binding.dependsOnParameters($0)
                ? try SwiftValueSchema.layout($0, actual: signature.failure, binding: binding) : nil
        }
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: SwiftGenericClosurePlan.Transport =
            attributes.isAsync
            ? .asynchronous(
                try SwiftAsyncCallInterface(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan,
                    inheritsCallerIsolation: signature.inheritsCallerIsolation
                ),
                inheritsCallerIsolation: signature.inheritsCallerIsolation
            )
            : .synchronous(
                try SwiftCallInterface.cached(
                    result: resultType,
                    parameters: types,
                    errorPlan: errorPlan
                )
            )
        let resultAuthentication =
            try usesStorageConvention
            ? ["-indirect"]
            : authTypes(result, actual: nativeResult, binding: binding, position: .result)
        let nativeArgumentClosures = zip(parameterPlan.arguments, nativeParameters).map {
            argument,
            metadata -> SwiftGenericClosurePlan? in
            if let closure = argument.closure { return closure }
            return argument.tuple == nil
                ? SwiftGenericClosurePlan.closureInStoredValue(metadata) : nil
        }
        let nativeResultClosure =
            resultPlan.closure
            ?? (resultPlan.tuple == nil
                ? SwiftGenericClosurePlan.closureInStoredValue(nativeResult) : nil)
        return SwiftGenericClosurePlan(
            transport: transport,
            parameters: parameterPlan,
            discriminator: swiftClosureDiscriminator(
                parameters: authentication,
                results: resultAuthentication
            ),
            authentication: swiftClosureAuthDescription(
                parameters: authentication,
                results: resultAuthentication
            ),
            isEscaping: attributes.isEscaping,
            resultConstants: SwiftValueConstants(usesStorageConvention ? Void.self : nativeResult),
            errorPlan: errorPlan,
            runtimeArguments: runtimeArguments,
            result: resultPlan,
            nativeResult: nativeResult,
            hostParameters: signature.parameters,
            nativeParameters: nativeParameters,
            nativeArgumentClosures: nativeArgumentClosures,
            nativeResultClosure: nativeResultClosure
        )
    }

    private static func authTypes(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding,
        position: SwiftValuePosition = .parameter
    ) throws -> [String] {
        let canonical = try binding.canonicalType(of: formal)
        if canonical != formal {
            return try authTypes(canonical, actual: actual, binding: binding, position: position)
        }
        if runtimeHandle(actual) != nil {
            let native = try binding.types(formal)[0]
            if native != actual {
                return try authTypes(formal, actual: native, binding: binding, position: position)
            }
        }
        if case .tuple(let fields, _) = formal {
            let elements = try tupleElements(fields, actual: actual, binding: binding)
            var index = 0
            return try fields.flatMap { field -> [String] in
                if case .pack(let pattern, let shape) = field {
                    index += try binding.packCount(in: shape ?? pattern)
                    return [position == .parameter ? "-" : "-indirect"]
                }
                defer { index += 1 }
                return try authTypes(
                    field,
                    actual: elements[index].type,
                    binding: binding,
                    position: position.tupleElement
                )
            }
        }
        if case .function(let parameters, let result, _, let attributes) = formal {
            if let closure = actual as? any SwiftClosureValue.Type {
                let plan = try Self.closure(
                    formal,
                    signature: SwiftFunctionSignature(closure.swiftFunctionType),
                    binding: binding
                )
                return ["(" + plan.authentication + ")"]
            }
            var inputs = attributes.isAsync && attributes.isolation == .caller ? ["-class"] : []
            for parameter in parameters {
                if case .pack = parameter { inputs.append("-"); continue }
                if case .inoutValue = parameter { inputs.append("-indirect"); continue }
                let value = parameter.argumentConvention?.value ?? parameter
                inputs.append(
                    contentsOf: try authTypes(
                        value,
                        actual: binding.types(value)[0],
                        binding: binding
                    )
                )
            }
            let outputs = try authTypes(
                result,
                actual: binding.types(result)[0],
                binding: binding,
                position: .result
            )
            return ["(" + swiftClosureAuthDescription(parameters: inputs, results: outputs) + ")"]
        }
        // An Optional's payload can have a declared ABI, and an inferred
        // value's passing convention depends on its inferred layout.
        if !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty,
            formal.optionalWrapped == nil, !SwiftInferredValue.lowersByInference(actual)
        {
            let explicit =
                formal.nominalDeclaration == nil ? nil : try binding.explicitValueType(actual)
            if explicit == nil {
                // Concrete class existentials and metatypes keep their formal
                // identity even when their physical storage is indirect.
                return [try swiftClosureAuthType(actual, position: position)]
            }
        }
        let layout = try SwiftValueSchema.layout(
            formal,
            actual: actual,
            binding: binding,
            position: position
        )
        if ABISwiftValueIsIndirect(layout.handle) { return ["-indirect"] }
        return [try swiftClosureTypeHash(actual)]
    }

    static func tupleElements(
        _ fields: [SwiftFormalType],
        actual: Any.Type,
        binding: SwiftGenericBinding
    ) throws -> [SwiftTupleMetadata.Element] {
        let count = try fields.reduce(0) { count, field in
            if case .pack(let pattern, let shape) = field {
                return count + (try binding.packCount(in: shape ?? pattern))
            }
            return count + 1
        }
        // A substituted singleton pack is its element type, even when that
        // element is itself a tuple. Swift does not have one-element tuples.
        if count == 1 { return [.init(type: actual, offset: 0)] }
        guard let tuple = SwiftTupleMetadata(actual), tuple.elements.count == count else {
            throw ABIResolutionError.signatureMismatch(
                .init(expected: "\(count) tuple elements", found: [String(reflecting: actual)])
            )
        }
        return tuple.elements
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
    func conventionArgument(
        _ actual: Any.Type,
        for formal: SwiftFormalType,
        defaultConsuming: Bool
    ) throws
        -> (wrapper: any SwiftConventionArgument.Type, value: SwiftFormalType)?
    {
        if let convention = formal.argumentConvention {
            guard let wrapper = actual as? any SwiftConventionArgument.Type,
                wrapper.convention == convention.convention
            else {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        expected: formal.spelling + " with its Swift argument wrapper",
                        found: [String(reflecting: actual)]
                    )
                )
            }
            if dependsOnParameters(convention.value) {
                try validateArgument(wrapper.wrappedType, for: convention.value)
            }
            return (wrapper, convention.value)
        }
        guard let wrapper = actual as? any SwiftConventionArgument.Type else { return nil }
        // A wrapper can itself be the explicitly bound T. In that case its
        // ordinary Swift value is passed, without applying an argument marker.
        do { try validate(actual, for: formal); return nil } catch ABIResolutionError
            .signatureMismatch
        {}
        guard wrapper.convention == (defaultConsuming ? .consuming : .borrowing) else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "The declaration's default argument ownership",
                    found: [String(reflecting: actual)]
                )
            )
        }
        if dependsOnParameters(formal) { try validateArgument(wrapper.wrappedType, for: formal) }
        return (wrapper, formal)
    }

    func dependsOnParameters(_ type: SwiftFormalType) -> Bool {
        return switch type {
        case .objectiveCClass, .opaqueResult: false
        case .constrainedExistential(_, let superclass, let constraints, _):
            (superclass.map(dependsOnParameters) ?? false)
                || constraints.contains { dependsOnParameters($0.value) }
        case .named(let name, let parameters):
            (parameters.isEmpty && arguments[String(name.prefix { $0 != "." })] != nil)
                || parameters.contains(where: dependsOnParameters)
        case .nominal(_, let parameters), .reference(_, let parameters):
            parameters.contains(where: dependsOnParameters)
        case .nested(let parent, _, let parameters):
            dependsOnParameters(parent) || parameters.contains(where: dependsOnParameters)
        case .associated(let base, _, _): dependsOnParameters(base)
        case .tuple(let fields, _), .packValue(let fields):
            fields.contains(where: dependsOnParameters)
        case .function(let parameters, let result, let failure, _):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result)
                || (failure.map(dependsOnParameters) ?? false)
        case .foreignFunction(_, let parameters, let result):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result)
        case .pack(let type, let shape):
            dependsOnParameters(type) || (shape.map(dependsOnParameters) ?? false)
        case .borrowing(let type), .consuming(let type), .inoutValue(let type), .metatype(let type),
            .existentialMetatype(let type):
            dependsOnParameters(type)
        }
    }
}
