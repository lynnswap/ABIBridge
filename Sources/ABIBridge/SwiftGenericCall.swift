import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
    case convention(SwiftConventionCodec)
    case value(CValueType, consuming: Bool)
    case closure(SwiftGenericClosurePlan)
}

protocol SwiftGenericClosureValue: SwiftClosureValue {
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec
    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage
}

enum SwiftGenericResult: Sendable {
    case concrete
    case value(CValueType)
    case closure(SwiftClosureCodec)

    var type: CValueType? {
        switch self {
        case .concrete: nil
        case .value(let type): type
        case .closure(let codec): codec.type
        }
    }
}

struct SwiftGenericClosurePlan: Sendable {
    enum Transport: Sendable {
        case synchronous(SwiftCallInterface)
        case asynchronous(SwiftAsyncCallInterface, inheritsCallerIsolation: Bool)
    }
    let transport: Transport
    let parameters: SwiftGenericParameters
    let discriminator: UInt16
    let resultConstants: SwiftValueConstants
    let errorPlan: SwiftErrorPlan?
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

    init(declaration: String, linkageName: String, genericArguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver,
         enclosing: SwiftGenericTypeMetadata? = nil, receiver: SwiftReceiverMode? = nil,
         declaredSignature: String? = nil) throws {
        let context = try enclosing.flatMap { $0.arguments.isEmpty ? nil : try SwiftGenericTypeContext(metadata: $0.value) }
        let declared = try declaredSignature.map(SwiftDeclaredSignature.init)
        let declaration = try SwiftGenericDeclaration(linkageName: linkageName, enclosing: context,
                                                       declaredSignature: declared, caller: signature)
        let binding = try SwiftGenericBinding(declaration: declaration,
            arguments: (enclosing?.arguments ?? []) + genericArguments,
            signature: signature, resolver: resolver, enclosing: context)
        if case .function(let arguments, let result, let failure, let isAsync) = declared?.function {
            _ = try SwiftGenericParameters(formal: arguments, actual: signature.parameters, binding: binding,
                defaultConsuming: declaration.consumesArguments)
            guard isAsync == declaration.isAsync else {
                throw ABIResolutionError.signatureMismatch(.init(expected: "The declaration's async effect", found: [declared!.function.spelling]))
            }
            if let failure { try binding.validate(signature.failure, for: failure) }
            else if signature.failure != Never.self {
                throw ABIResolutionError.signatureMismatch(.init(expected: "A nonthrowing declaredAs: signature", found: [String(reflecting: signature.failure)]))
            }
            _ = try binding.resultType(signature.result, for: result)
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
        if binding.dependsOnParameters(declaration.result) {
            let nativeResult = try binding.resultType(signature.result, for: declaration.result)
            if case .function = declaration.result {
                guard let closure = signature.result as? any SwiftGenericClosureValue.Type else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "NativeSwiftClosure for " + declaration.result.spelling,
                        found: [String(reflecting: signature.result)]))
                }
                let plan = try Self.closure(declaration.result,
                    signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding)
                result = .closure(try closure.makeGenericClosureCodec(plan: plan))
            } else {
                result = .value(try Self.layout(declaration.result, actual: nativeResult, binding: binding))
            }
        } else {
            result = .concrete
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

    func receiverType() throws -> CValueType? {
        guard let context, let enclosingMetadata, !(enclosingMetadata is AnyClass) else { return nil }
        let arguments = context.parameters.map { SwiftFormalType.named($0.name, []) }
        return try SwiftGenericValueLayout.isIndirect(enclosingMetadata, arguments: arguments, binding: binding)
            ? SwiftGenericParameters.storageType(enclosingMetadata) : nil
    }

    func matches(_ signature: SwiftFunctionSignature) throws -> Bool {
        do {
            for (formal, group) in zip(binding.declaration.arguments, parameters.groups) {
                switch group {
                case .value(let index):
                    if try binding.conventionArgument(signature.parameters[index], for: formal,
                        defaultConsuming: binding.declaration.consumesArguments) == nil {
                        try binding.validate(signature.parameters[index], for: formal)
                    }
                case .pack(let range, _):
                    guard case .pack(let pattern, _) = formal else { preconditionFailure("A pack group has a pack formal type.") }
                    for (packIndex, index) in range.enumerated() {
                        try binding.validate(signature.parameters[index], for: pattern, packIndex: packIndex)
                    }
                }
            }
            _ = try binding.resultType(signature.result, for: binding.declaration.result)
            return true
        } catch ABIResolutionError.signatureMismatch { return false }
    }

    static func argument(_ formal: SwiftFormalType, actual: Any.Type,
                         binding: SwiftGenericBinding, defaultConsuming: Bool = false) throws -> SwiftGenericArgument {
        if let argument = try binding.conventionArgument(actual, for: formal, defaultConsuming: defaultConsuming) {
            let value = try Self.argument(argument.value, actual: argument.wrapper.wrappedType, binding: binding,
                                          defaultConsuming: argument.wrapper.convention == .consuming)
            return .convention(try argument.wrapper.makeArgumentCodec(generic: value))
        }
        if case .function = formal, binding.dependsOnParameters(formal) {
            guard let closure = actual as? any SwiftGenericClosureValue.Type else {
                throw ABIResolutionError.signatureMismatch(.init(expected: "NativeSwiftClosure for " + formal.spelling, found: [String(reflecting: actual)]))
            }
            return .closure(try Self.closure(formal, signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding))
        }
        guard binding.dependsOnParameters(formal) else { return .concrete }
        try binding.validate(actual, for: formal)
        return .value(try Self.layout(formal, actual: actual, binding: binding), consuming: false)
    }

    private static func closure(_ formal: SwiftFormalType, signature: SwiftFunctionSignature,
                                binding: SwiftGenericBinding) throws -> SwiftGenericClosurePlan {
        guard case .function(let parameters, let result, let failure, let isAsync) = formal else {
            preconditionFailure("A closure plan requires a function type.")
        }
        guard isAsync == signature.isAsync,
              failure != nil || signature.failure == Never.self else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        let parameterPlan = try SwiftGenericParameters(formal: parameters, actual: signature.parameters, binding: binding)
        if let failure { try binding.validate(signature.failure, for: failure) }
        var logicalTypes: [CValueType] = []
        var authentication = isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
        for (formal, group) in zip(parameters, parameterPlan.groups) {
            switch group {
            case .pack(let range, _):
                logicalTypes.append(contentsOf: try range.map { try SwiftGenericParameters.storageType(signature.parameters[$0]) })
                // SIL pack values have an opaque type hash, distinct from an
                // ordinary formally indirect scalar (GenPointerAuth.cpp).
                authentication.append("-")
            case .value(let index):
                let actual = signature.parameters[index]
                try binding.validate(actual, for: formal)
                logicalTypes.append(try layout(formal, actual: actual, binding: binding))
                authentication.append(contentsOf: try authTypes(formal, actual: actual, binding: binding))
            }
        }
        let types = parameterPlan.types(from: logicalTypes)
        let nativeResult = try binding.resultType(signature.result, for: result)
        let resultType = try layout(result, actual: nativeResult, binding: binding)
        let errorType = try failure.flatMap {
            binding.dependsOnParameters($0) ? try layout($0, actual: signature.failure, binding: binding) : nil
        }
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: SwiftGenericClosurePlan.Transport = isAsync
            ? .asynchronous(try SwiftAsyncCallInterface(result: resultType, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: signature.inheritsCallerIsolation),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            : .synchronous(try SwiftCallInterface.cached(result: resultType, parameters: types, errorPlan: errorPlan))
        return try SwiftGenericClosurePlan(transport: transport, parameters: parameterPlan,
            discriminator: swiftClosureDiscriminator(parameters: authentication,
                results: authTypes(result, actual: nativeResult, binding: binding, isResult: true)),
            resultConstants: SwiftValueConstants(signature.result), errorPlan: errorPlan)
    }

    private static func authTypes(_ formal: SwiftFormalType, actual: Any.Type,
                                  binding: SwiftGenericBinding, isResult: Bool = false) throws -> [String] {
        if case .tuple(let fields) = formal {
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
        func prepare<Value>(_ type: Value.Type) throws -> CValueType {
            if !binding.dependsOnParameters(formal) { return try SwiftValueCodec<Value>().type }
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
            case .existentialMetatype:
                return try SwiftValueCodec<Value>().type
            case .tuple(let fields):
                let elements = try tupleElements(fields, actual: actual, binding: binding)
                var types: [CValueType] = [], offsets: [Int] = []
                var index = 0
                for field in fields {
                    let offset = index < elements.count ? elements[index].offset : MemoryLayout<Value>.size
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
                return try CValueType(swiftTuple: types, offsets: offsets, size: MemoryLayout<Value>.size,
                    alignment: MemoryLayout<Value>.alignment)
            case .pack, .packValue:
                preconditionFailure("A pack expands within the containing parameter list or tuple.")
            case .function:
                let pointer = try CValueType(scalar: ABIValuePointer)
                return try CValueType(fields: [pointer, pointer])
            case .borrowing, .consuming, .inoutValue:
                throw ABIResolutionError.unsupportedDeclaration("Generic ownership arguments require their underlying value convention.")
            }
        }
        return try _openExistential(actual, do: prepare)
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
            try validate(actual, for: formal)
            return (actual as! any SwiftConventionArgument.Type, convention.value)
        }
        guard let wrapper = actual as? any SwiftConventionArgument.Type else { return nil }
        // A wrapper can itself be the explicitly bound T. In that case its
        // ordinary Swift value is passed, without applying an argument marker.
        do { try validate(actual, for: formal); return nil }
        catch ABIResolutionError.signatureMismatch {}
        guard wrapper.convention == (defaultConsuming ? .consuming : .borrowing) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "The declaration's default argument ownership", found: [String(reflecting: actual)]))
        }
        try validate(wrapper.wrappedType, for: formal)
        return (wrapper, formal)
    }

    func dependsOnParameters(_ type: SwiftFormalType) -> Bool {
        return switch type {
        case .named(let name, let parameters):
            (parameters.isEmpty && arguments[String(name.prefix { $0 != "." })] != nil) || parameters.contains(where: dependsOnParameters)
        case .nominal(_, let parameters), .reference(_, let parameters): parameters.contains(where: dependsOnParameters)
        case .nested(let parent, _, let parameters): dependsOnParameters(parent) || parameters.contains(where: dependsOnParameters)
        case .associated(let base, _, _): dependsOnParameters(base)
        case .tuple(let fields), .packValue(let fields): fields.contains(where: dependsOnParameters)
        case .function(let parameters, let result, let failure, _):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result) || (failure.map(dependsOnParameters) ?? false)
        case .pack(let type, let shape): dependsOnParameters(type) || (shape.map(dependsOnParameters) ?? false)
        case .borrowing(let type), .consuming(let type), .inoutValue(let type), .metatype(let type), .existentialMetatype(let type):
            dependsOnParameters(type)
        }
    }
}

extension ABIRuntime {
    func preparedGenericFunction<Signature>(
        symbol: ResolvedSymbol, signature: Signature.Type, genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String? = nil
    ) throws -> NativeSwiftFunction<Signature> {
        guard let declaration = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The Swift declaration cannot be demangled.")
        }
        let plan = try SwiftGenericCallPlan(declaration: declaration, linkageName: symbol.linkageName, genericArguments: genericArguments,
                                            signature: SwiftFunctionSignature(signature), resolver: resolver, declaredSignature: declaredSignature)
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver, generic: plan)
    }
}
