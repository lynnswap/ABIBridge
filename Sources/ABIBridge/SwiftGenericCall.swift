import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
    case value(CValueType, consuming: Bool)
    case closure(SwiftGenericClosurePlan)
}

protocol SwiftGenericClosureValue: SwiftClosureValue {
    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage
}

struct SwiftGenericClosurePlan: Sendable {
    enum Transport: Sendable {
        case synchronous(SwiftCallInterface)
        case asynchronous(SwiftAsyncCallInterface, inheritsCallerIsolation: Bool)
    }
    let transport: Transport
    let discriminator: UInt16
}

struct SwiftGenericCallPlan: Sendable {
    let binding: SwiftGenericBinding
    let metadata: SwiftGenericArgumentBuffer
    let arguments: [SwiftGenericArgument]
    let resultType: CValueType?
    let errorType: CValueType?

    init(declaration: String, genericArguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver) throws {
        let declaration = try SwiftGenericDeclaration(declaration)
        let binding = try SwiftGenericBinding(declaration: declaration, arguments: genericArguments,
                                              signature: signature, resolver: resolver)
        guard declaration.arguments.count == signature.parameters.count else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "\(declaration.arguments.count) arguments", found: ["\(signature.parameters.count) arguments"]))
        }
        guard declaration.isAsync == signature.isAsync,
              (declaration.failure == nil) == (signature.failure == Never.self) else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "The declaration's async and error effects", found: []))
        }
        self.binding = binding
        metadata = SwiftGenericArgumentBuffer(binding.metadataArguments)
        arguments = try zip(declaration.arguments, signature.parameters).map { formal, actual in
            if case .function = formal, binding.dependsOnParameters(formal) {
                guard let closure = actual as? any SwiftGenericClosureValue.Type else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "NativeSwiftClosure for " + formal.spelling, found: [String(reflecting: actual)]))
                }
                let signature = try SwiftFunctionSignature(closure.swiftFunctionType)
                return .closure(try Self.closure(formal, signature: signature, binding: binding))
            }
            guard binding.dependsOnParameters(formal) else { return .concrete }
            try binding.validate(actual, for: formal)
            return .value(try Self.layout(formal, actual: actual, binding: binding), consuming: false)
        }
        if binding.dependsOnParameters(declaration.result) {
            try binding.validate(signature.result, for: declaration.result)
            resultType = try Self.layout(declaration.result, actual: signature.result, binding: binding)
        } else {
            resultType = nil
        }
        if let failure = declaration.failure, binding.dependsOnParameters(failure) {
            try binding.validate(signature.failure, for: failure)
            errorType = try Self.layout(failure, actual: signature.failure, binding: binding)
        } else {
            errorType = nil
        }
    }

    private static func closure(_ formal: SwiftFormalType, signature: SwiftFunctionSignature,
                                binding: SwiftGenericBinding) throws -> SwiftGenericClosurePlan {
        guard case .function(let parameters, let result, let failure, let isAsync) = formal else {
            preconditionFailure("A closure plan requires a function type.")
        }
        guard parameters.count == signature.parameters.count, isAsync == signature.isAsync,
              (failure == nil) == (signature.failure == Never.self) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        var types: [CValueType] = []
        var authentication = isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
        for (formal, actual) in zip(parameters, signature.parameters) {
            try binding.validate(actual, for: formal)
            let type = try layout(formal, actual: actual, binding: binding)
            types.append(type)
            authentication.append(contentsOf: try authTypes(formal, actual: actual, binding: binding))
        }
        try binding.validate(signature.result, for: result)
        let resultType = try layout(result, actual: signature.result, binding: binding)
        let errorType = try failure.flatMap {
            binding.dependsOnParameters($0) ? try layout($0, actual: signature.failure, binding: binding) : nil
        }
        let errorPlan = try signature.makeErrorPlan(genericType: errorType)
        let transport: SwiftGenericClosurePlan.Transport = isAsync
            ? .asynchronous(try SwiftAsyncCallInterface(result: resultType, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: signature.inheritsCallerIsolation),
                inheritsCallerIsolation: signature.inheritsCallerIsolation)
            : .synchronous(try SwiftCallInterface.cached(result: resultType, parameters: types, errorPlan: errorPlan))
        return try SwiftGenericClosurePlan(transport: transport,
            discriminator: swiftClosureDiscriminator(parameters: authentication,
                results: authTypes(result, actual: signature.result, binding: binding)))
    }

    private static func authTypes(_ formal: SwiftFormalType, actual: Any.Type,
                                  binding: SwiftGenericBinding) throws -> [String] {
        if case .tuple(let fields) = formal, let tuple = SwiftTupleMetadata(actual) {
            return try zip(fields, tuple.elements).flatMap {
                try authTypes($0.0, actual: $0.1.type, binding: binding)
            }
        }
        let layout = try layout(formal, actual: actual, binding: binding)
        if ABISwiftValueIsIndirect(layout.handle) { return ["-indirect"] }
        return [try swiftClosureAuthType(actual)]
    }

    private static func layout(_ formal: SwiftFormalType, actual: Any.Type,
                               binding: SwiftGenericBinding) throws -> CValueType {
        func prepare<Value>(_ type: Value.Type) throws -> CValueType {
            if !binding.dependsOnParameters(formal) { return try SwiftValueCodec<Value>().type }
            if binding.isClassBound(formal) { return try CValueType(scalar: ABIValuePointer) }
            switch formal {
            case .named(let name, let arguments):
                if ["Swift.Array", "Swift.Dictionary", "Swift.Set"].contains(name) {
                    return try CValueType(scalar: ABIValuePointer)
                }
                if name == "Swift.Optional", let wrapped = arguments.first,
                   binding.isClassBound(wrapped) {
                    return try CValueType(scalar: ABIValuePointer)
                }
                return try CValueType(indirectSwiftSize: MemoryLayout<Value>.size,
                                      alignment: MemoryLayout<Value>.alignment)
            case .metatype:
                return try CValueType(scalar: ABIValuePointer)
            case .tuple(let fields):
                guard let tuple = SwiftTupleMetadata(actual), fields.count == tuple.elements.count else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: [String(reflecting: actual)]))
                }
                return try tuple.layout(for: type, fields: zip(fields, tuple.elements).map {
                    try layout($0.0, actual: $0.1.type, binding: binding)
                })
            case .pack:
                throw ABIResolutionError.unsupportedDeclaration("Generic pack values require their element buffers.")
            case .function:
                let pointer = try CValueType(scalar: ABIValuePointer)
                return try CValueType(fields: [pointer, pointer])
            case .borrowing, .consuming, .inoutValue:
                throw ABIResolutionError.unsupportedDeclaration("Generic ownership arguments require their underlying value convention.")
            }
        }
        return try _openExistential(actual, do: prepare)
    }
}

extension SwiftGenericBinding {
    func dependsOnParameters(_ type: SwiftFormalType) -> Bool {
        switch type {
        case .named(let name, let parameters):
            arguments[String(name.prefix { $0 != "." })] != nil || parameters.contains(where: dependsOnParameters)
        case .tuple(let fields): fields.contains(where: dependsOnParameters)
        case .function(let parameters, let result, let failure, _):
            parameters.contains(where: dependsOnParameters) || dependsOnParameters(result) || (failure.map(dependsOnParameters) ?? false)
        case .pack(let type), .borrowing(let type), .consuming(let type), .inoutValue(let type), .metatype(let type):
            dependsOnParameters(type)
        }
    }
}

extension ABIRuntime {
    func preparedGenericFunction<Signature>(
        symbol: ResolvedSymbol, signature: Signature.Type, genericArguments: [NativeSwiftGenericArgument]
    ) throws -> NativeSwiftFunction<Signature> {
        guard let declaration = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The Swift declaration cannot be demangled.")
        }
        let plan = try SwiftGenericCallPlan(declaration: declaration, genericArguments: genericArguments,
                                            signature: SwiftFunctionSignature(signature), resolver: resolver)
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver, generic: plan)
    }
}
