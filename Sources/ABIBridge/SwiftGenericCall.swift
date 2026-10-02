import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
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
}

struct SwiftGenericCallPlan: Sendable {
    let binding: SwiftGenericBinding
    let metadata: SwiftGenericArgumentBuffer
    let parameters: SwiftGenericParameters
    var arguments: [SwiftGenericArgument] { parameters.arguments }
    let result: SwiftGenericResult
    var resultType: CValueType? { result.type }
    let errorType: CValueType?

    init(declaration: String, linkageName: String, genericArguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver,
         enclosing: SwiftGenericTypeMetadata? = nil, receiver: SwiftReceiverMode? = nil) throws {
        let context = try enclosing.flatMap { $0.arguments.isEmpty ? nil : try SwiftGenericTypeContext(metadata: $0.value) }
        var source = SymbolIndex.extensionMemberName(declaration) ?? declaration
        for (accessor, setter) in [(".getter : ", false), (".setter : ", true)] {
            if let range = source.range(of: accessor) {
                let value = String(source[range.upperBound...])
                source = String(source[..<range.lowerBound]) + (setter ? ".setter(" + value + ") -> ()" : ".getter() -> " + value)
                break
            }
        }
        let declaration = try SwiftGenericDeclaration(source, linkageName: linkageName, enclosing: context)
        let binding = try SwiftGenericBinding(declaration: declaration,
            arguments: (enclosing?.arguments ?? []) + genericArguments,
            signature: signature, resolver: resolver, enclosing: context)
        guard declaration.isAsync == signature.isAsync,
              (declaration.failure == nil) == (signature.failure == Never.self) else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "The declaration's async and error effects", found: []))
        }
        self.binding = binding
        if let context, let receiver {
            let prefix: [UInt] = receiver == .address ? [unsafeBitCast(enclosing!.value, to: UInt.self)] : []
            metadata = SwiftGenericArgumentBuffer(prefix + binding.metadataArguments(fulfilledBy: context))
        } else {
            metadata = SwiftGenericArgumentBuffer(binding.metadataArguments)
        }
        parameters = try SwiftGenericParameters(formal: declaration.arguments, actual: signature.parameters, binding: binding)
        if binding.dependsOnParameters(declaration.result) {
            try binding.validate(signature.result, for: declaration.result)
            if case .function = declaration.result {
                guard let closure = signature.result as? any SwiftGenericClosureValue.Type else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "NativeSwiftClosure for " + declaration.result.spelling,
                        found: [String(reflecting: signature.result)]))
                }
                let plan = try Self.closure(declaration.result,
                    signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding)
                result = .closure(try closure.makeGenericClosureCodec(plan: plan))
            } else {
                result = .value(try Self.layout(declaration.result, actual: signature.result, binding: binding))
            }
        } else {
            result = .concrete
        }
        if let failure = declaration.failure, binding.dependsOnParameters(failure) {
            try binding.validate(signature.failure, for: failure)
            errorType = try Self.layout(failure, actual: signature.failure, binding: binding)
        } else {
            errorType = nil
        }
    }

    func matches(_ signature: SwiftFunctionSignature) throws -> Bool {
        do {
            for (formal, group) in zip(binding.declaration.arguments, parameters.groups) {
                switch group {
                case .value(let index): try binding.validate(signature.parameters[index], for: formal)
                case .pack(let range, _):
                    guard case .pack(let pattern) = formal else { preconditionFailure("A pack group has a pack formal type.") }
                    for (packIndex, index) in range.enumerated() {
                        try binding.validate(signature.parameters[index], for: pattern, packIndex: packIndex)
                    }
                }
            }
            try binding.validate(signature.result, for: binding.declaration.result)
            return true
        } catch ABIResolutionError.signatureMismatch { return false }
    }

    static func argument(_ formal: SwiftFormalType, actual: Any.Type,
                         binding: SwiftGenericBinding) throws -> SwiftGenericArgument {
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
              (failure == nil) == (signature.failure == Never.self) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        let parameterPlan = try SwiftGenericParameters(formal: parameters, actual: signature.parameters, binding: binding)
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
        return try SwiftGenericClosurePlan(transport: transport, parameters: parameterPlan,
            discriminator: swiftClosureDiscriminator(parameters: authentication,
                results: authTypes(result, actual: signature.result, binding: binding, isResult: true)))
    }

    private static func authTypes(_ formal: SwiftFormalType, actual: Any.Type,
                                  binding: SwiftGenericBinding, isResult: Bool = false) throws -> [String] {
        if case .tuple(let fields) = formal {
            let elements = try tupleElements(fields, actual: actual, binding: binding)
            var index = 0
            return try fields.flatMap { field -> [String] in
                if case .pack(let pattern) = field {
                    index += try binding.packCount(in: pattern)
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
            if case .pack(let pattern) = field { return count + (try binding.packCount(in: pattern)) }
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
        func prepare<Value>(_ type: Value.Type) throws -> CValueType {
            if !binding.dependsOnParameters(formal) { return try SwiftValueCodec<Value>().type }
            if binding.isClassBound(formal) { return try CValueType(scalar: ABIValuePointer) }
            switch formal {
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if !arguments.isEmpty && actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
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
                let elements = try tupleElements(fields, actual: actual, binding: binding)
                var types: [CValueType] = [], offsets: [Int] = []
                var index = 0
                for field in fields {
                    let offset = index < elements.count ? elements[index].offset : MemoryLayout<Value>.size
                    offsets.append(offset)
                    if case .pack(let pattern) = field {
                        let count = try binding.packCount(in: pattern)
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
            case .pack:
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
}

extension SwiftGenericBinding {
    func dependsOnParameters(_ type: SwiftFormalType) -> Bool {
        return switch type {
        case .named(let name, let parameters):
            (parameters.isEmpty && arguments[String(name.prefix { $0 != "." })] != nil) || parameters.contains(where: dependsOnParameters)
        case .nominal(_, let parameters): parameters.contains(where: dependsOnParameters)
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
        let plan = try SwiftGenericCallPlan(declaration: declaration, linkageName: symbol.linkageName, genericArguments: genericArguments,
                                            signature: SwiftFunctionSignature(signature), resolver: resolver)
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver, generic: plan)
    }
}
