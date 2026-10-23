import ABIBridgeRuntime

/// Function fields can use a different ABI from owned generic value storage.
struct SwiftRuntimeValueProjectionPlan: Sendable {
    private let conversions: SwiftRuntimeClosureConversions
    private let enumType: NativeSwiftType
    private let valueTypes: [NativeSwiftType]

    init(
        enumType: NativeSwiftType,
        caseIndex: Int,
        payload: Any.Type,
        valueABIs: [NativeSwiftType: NativeType]
    ) throws {
        self.enumType = enumType
        valueTypes = Array(valueABIs.keys)
        guard Self.containsFunction(payload) else {
            conversions = try SwiftRuntimeClosureConversions(functions: [])
            return
        }
        try Self.validateFunctionStorage(payload)
        let runtime = try withRuntimeErrors { try RuntimeEnumMetadata(enumType.metadata) }
        let syntax = try withRuntimeErrors { try runtime.copyPayloadSyntax(at: caseIndex) }
        let context = try SwiftGenericTypeContext(metadata: enumType.metadata)
        let formal = try SwiftFormalType(SwiftSyntax(adopting: syntax).root)
            .qualifyingAssociatedTypes(using: context.conformances)
        let declaration = SwiftGenericDeclaration(
            parameters: context.parameters,
            requirements: context.requirements,
            arguments: [],
            result: .tuple([], labels: nil),
            failure: nil,
            isAsync: false,
            consumesArguments: false
        )
        func signature<Value>(_ type: Value.Type) throws -> SwiftFunctionSignature {
            try SwiftFunctionSignature((() -> Value).self)
        }
        let metadata =
            try enumType.genericMetadata
            ?? SwiftGenericTypeMetadata(metadata: enumType.metadata, retaining: enumType.codeImages)
        let binding = try SwiftGenericBinding(
            declaration: declaration,
            arguments: metadata.arguments,
            signature: _openExistential(payload, do: signature),
            resolver: enumType.resolver,
            enclosing: context,
            image: enumType.image,
            valueABIs: valueABIs
        )
        var functions: [(Int, Any.Type, SwiftGenericClosurePlan)] = []
        func visit(
            _ formal: SwiftFormalType,
            metadata: Any.Type,
            offset: Int,
            binding: SwiftGenericBinding
        ) throws {
            let canonical = try binding.canonicalType(of: formal)
            if let function = try SwiftGenericCallPlan.storedFunction(canonical, binding: binding) {
                functions.append(
                    (
                        offset, metadata,
                        try SwiftGenericCallPlan.nativeClosurePlan(function, binding: binding)
                    )
                )
            } else if case .tuple(let fields, _) = canonical {
                guard let tuple = RuntimeTupleMetadata(metadata) else {
                    throw ABIResolutionError.metadataUnavailable(
                        "The enum payload's tuple metadata does not match its field declaration."
                    )
                }
                var index = 0
                func element(_ field: SwiftFormalType, binding: SwiftGenericBinding) throws {
                    guard tuple.elements.indices.contains(index) else {
                        throw ABIResolutionError.metadataUnavailable(
                            "The enum payload's tuple metadata does not match its field declaration."
                        )
                    }
                    let element = tuple.elements[index]
                    try visit(
                        field,
                        metadata: element.type,
                        offset: offset + element.offset,
                        binding: binding
                    )
                    index += 1
                }
                for field in fields {
                    if case .pack(let pattern, let shape) = field {
                        for packIndex in 0..<(try binding.packCount(in: shape ?? pattern)) {
                            try element(
                                pattern,
                                binding: binding.selectingPackElement(at: packIndex)
                            )
                        }
                    } else {
                        try element(field, binding: binding)
                    }
                }
                guard index == tuple.elements.count else {
                    throw ABIResolutionError.metadataUnavailable(
                        "The enum payload's tuple metadata does not match its field declaration."
                    )
                }
            }
        }
        try visit(formal, metadata: payload, offset: 0, binding: binding)
        conversions = try SwiftRuntimeClosureConversions(functions: functions)
    }

    func apply(to storage: NativeValueStorage, native: Bool = false) {
        conversions.apply(
            to: storage,
            native: native,
            retainingCode: (enumType, valueTypes),
            codeLifetime: storage.codeLifetime
        )
    }

    private static func containsFunction(_ metadata: Any.Type) -> Bool {
        if swiftStoredFunction(metadata) != nil { return true }
        return RuntimeTupleMetadata(metadata)?.elements.contains { containsFunction($0.type) }
            ?? false
    }

    private static func validateFunctionStorage(_ metadata: Any.Type) throws {
        if let function = swiftStoredFunction(metadata) {
            let signature = try SwiftFunctionSignature(function, nativeConventions: true)
            for parameter in signature.parameters {
                try validateSwiftRuntimeValueStorage(parameter)
                try validateFunctionStorage(parameter)
            }
            try validateSwiftRuntimeValueStorage(signature.result)
            try validateFunctionStorage(signature.result)
        } else if let tuple = RuntimeTupleMetadata(metadata) {
            for element in tuple.elements { try validateFunctionStorage(element.type) }
        }
    }
}
