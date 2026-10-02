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
    let interface: SwiftCallInterface
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
        guard !isAsync else {
            throw ABIResolutionError.unsupportedDeclaration("Generic async callbacks require async reabstraction.")
        }
        var types: [CValueType] = []
        var authentication: [String] = []
        for (formal, actual) in zip(parameters, signature.parameters) {
            try binding.validate(actual, for: formal)
            let type = try layout(formal, actual: actual, binding: binding)
            types.append(type)
            authentication.append(try authType(actual, layout: type))
        }
        try binding.validate(signature.result, for: result)
        let resultType = try layout(result, actual: signature.result, binding: binding)
        let errorType = try failure.flatMap {
            binding.dependsOnParameters($0) ? try layout($0, actual: signature.failure, binding: binding) : nil
        }
        return try SwiftGenericClosurePlan(interface: SwiftCallInterface.cached(result: resultType,
            parameters: types, errorPlan: signature.makeErrorPlan(genericType: errorType)),
            discriminator: swiftClosureDiscriminator(parameters: authentication,
                result: result == .tuple([]) ? nil : authType(signature.result, layout: resultType)))
    }

    private static func authType(_ type: Any.Type, layout: CValueType) throws -> String {
        if ABISwiftValueIsIndirect(layout.handle) { return "-indirect" }
        return try swiftClosureAuthType(type)
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
            case .tuple:
                throw ABIResolutionError.unsupportedDeclaration("Generic tuple values require declaration-level element lowering.")
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
