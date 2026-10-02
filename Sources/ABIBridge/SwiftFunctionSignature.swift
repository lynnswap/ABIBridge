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
        if failure == Never.self { return nil }
        if failure == (any Error).self { return try SwiftErrorPlan.make((any Error).self) }
        guard let error = failure as? any Error.Type else {
            throw ABIResolutionError.unsupportedDeclaration("The function's thrown type does not conform to Error.")
        }
        return try SwiftErrorPlan.make(error, genericType: genericType)
    }

    func closureDiscriminator() throws -> UInt16 {
        var parameters = isAsync && inheritsCallerIsolation ? ["-class"] : []
        for type in self.parameters where type != Void.self {
            parameters.append(try swiftClosureAuthType(type))
        }
        return swiftClosureDiscriminator(parameters: parameters,
            result: result == Void.self ? nil : try swiftClosureAuthType(result))
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
         opaqueResult: SwiftOpaqueResultPlan?, generic: SwiftGenericCallPlan? = nil) throws {
        arguments = try signature.parameters.enumerated().map { index, type in
            func prepare<Value>(_ type: Value.Type) throws -> Argument {
                let codec = try SwiftArgumentCodec<Value>(defaultConsuming: consumesArguments,
                    generic: generic?.arguments[index] ?? .concrete)
                return Argument(type: codec.type, consumes: codec.consumes,
                    encode: { try codec.encode($0.load(as: Value.self), retainingCode: $1) })
            }
            return try _openExistential(type, do: prepare)
        }
        func prepareResult<Value>(_ type: Value.Type) throws -> Result {
            let codec = try SwiftResultCodec<Value>(opaque: opaqueResult, genericType: generic?.resultType)
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
