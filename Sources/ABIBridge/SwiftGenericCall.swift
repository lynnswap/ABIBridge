import ABIBridgeCore

enum SwiftGenericArgument: Sendable {
    case concrete
    case convention(SwiftConventionCodec)
    case value(CValueType, consuming: Bool)
    case closure(SwiftGenericClosurePlan)
    case runtimeValue(SwiftRuntimeValuePlan, convention: SwiftArgumentConvention, asynchronous: Bool)
}

protocol SwiftGenericClosureValue: SwiftClosureValue {
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec
    func encodeGenericClosure(plan: SwiftGenericClosurePlan, retainingCode owner: Any?) throws -> NativeValueStorage
}

enum SwiftGenericResult: Sendable {
    case concrete
    case value(CValueType)
    case closure(SwiftClosureCodec)
    case runtimeValue(SwiftRuntimeValuePlan)

    var type: CValueType? {
        switch self {
        case .concrete: nil
        case .value(let type): type
        case .closure(let codec): codec.type
        case .runtimeValue(let plan): plan.type
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
    let runtimeArguments: [SwiftCallbackRuntimeArgument?]
    let result: SwiftGenericResult
    let nativeResult: Any.Type

    var convertsArguments: Bool { runtimeArguments.contains { $0 != nil } }
    var convertsValues: Bool {
        if case .runtimeValue = result { return true }
        return convertsArguments
    }

    func validateCallbackConversion() throws {
        for conversion in runtimeArguments.compactMap({ $0 }) where !conversion.borrowed {
            try conversion.plan.requireOwnedValue()
            guard SwiftCopyability.accepts(conversion.plan.valueType.metadata) else {
                throw NativeSwiftValueError.noncopyableType
            }
        }
        if case .runtimeValue = result {
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

    func validateNativeValues(for other: Self) throws {
        for (lhs, rhs) in zip(runtimeArguments, other.runtimeArguments) {
            guard lhs?.plan.valueType.metadata == rhs?.plan.valueType.metadata else {
                throw ABIResolutionError.signatureMismatch(.init(expected: "The native callback argument type", found: []))
            }
        }
        guard nativeResult == other.nativeResult else {
            throw ABIResolutionError.signatureMismatch(.init(expected: String(reflecting: nativeResult),
                found: [String(reflecting: other.nativeResult)]))
        }
    }

    func decodeArguments(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> SwiftCallbackArguments? {
        guard parameters.hasPacks || convertsArguments else { return nil }
        var addresses = parameters.unpack(native)
        var storage: [NativeValueStorage] = []
        var borrows: [SwiftValueBorrow] = []
        for (index, conversion) in runtimeArguments.enumerated() {
            guard let conversion else { continue }
            let plan = conversion.plan
            if let restored = plan.restoredCallbackArgument(from: addresses[index]!) {
                storage.append(restored)
                addresses[index] = restored.address
            }
            let lifetime = SwiftValueCodeLifetime.current ?? plan.valueType.codeLifetime
            SwiftValueCodeLifetime.connect([lifetime, plan.valueType.codeLifetime], retaining: [])
            let type = plan.valueType.retainingCode(lifetime)
            let value: NativeValueStorage
            if conversion.borrowed {
                let borrow = SwiftValueBorrow(UnsafeRawPointer(addresses[index]!), allowsSuspension: conversion.asynchronous)
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

    init(declaration: String, linkageName: String, image: NativeImage, genericArguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver,
         enclosing: SwiftGenericTypeMetadata? = nil, receiver: SwiftReceiverMode? = nil,
         declaredSignature: String? = nil) throws {
        let context = try enclosing.flatMap { $0.arguments.isEmpty ? nil : try SwiftGenericTypeContext(metadata: $0.value) }
        let declared = try declaredSignature.map(SwiftDeclaredSignature.init)
        let declaration = try SwiftGenericDeclaration(linkageName: linkageName, enclosing: context,
                                                       declaredSignature: declared, caller: signature)
        let binding = try SwiftGenericBinding(declaration: declaration,
            arguments: (enclosing?.arguments ?? []) + genericArguments,
            signature: signature, resolver: resolver, enclosing: context, image: image)
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
        if signature.result == NativeSwiftValue.self,
           try binding.types(declaration.result)[0] != NativeSwiftValue.self {
            let metadata = try binding.types(declaration.result)[0]
            result = .runtimeValue(try binding.runtimeValuePlan(metadata: metadata,
                type: Self.layout(declaration.result, actual: metadata, binding: binding)))
        } else if case .function = declaration.result, let closure = signature.result as? any SwiftGenericClosureValue.Type {
            let plan = try Self.closure(declaration.result,
                signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding)
            result = .closure(try closure.makeGenericClosureCodec(plan: plan))
        } else if binding.dependsOnParameters(declaration.result) {
            let nativeResult = try binding.resultType(signature.result, for: declaration.result)
            result = .value(try Self.layout(declaration.result, actual: nativeResult, binding: binding))
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
                         binding: SwiftGenericBinding, defaultConsuming: Bool = false) throws -> SwiftGenericArgument {
        if let argument = try binding.conventionArgument(actual, for: formal, defaultConsuming: defaultConsuming) {
            let value = try Self.argument(argument.value, actual: argument.wrapper.wrappedType, binding: binding,
                                          defaultConsuming: argument.wrapper.convention == .consuming)
            return .convention(try argument.wrapper.makeArgumentCodec(generic: value))
        }
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            let metadata = try binding.types(formal)[0]
            if metadata != actual {
                guard actual != NativeSwiftBorrowedValue.self || !defaultConsuming else {
                    throw ABIResolutionError.unsupportedDeclaration("A borrowed runtime value cannot be consumed.")
                }
                return .runtimeValue(try binding.runtimeValuePlan(metadata: metadata,
                    type: Self.layout(formal, actual: metadata, binding: binding)),
                    convention: defaultConsuming ? .consuming : .borrowing,
                    asynchronous: binding.declaration.isAsync)
            }
        }
        if case .function = formal, let closure = actual as? any SwiftGenericClosureValue.Type {
            return .closure(try Self.closure(formal, signature: SwiftFunctionSignature(closure.swiftFunctionType), binding: binding))
        }
        guard binding.dependsOnParameters(formal) else { return .concrete }
        try binding.validate(actual, for: formal)
        return .value(try Self.layout(formal, actual: actual, binding: binding), consuming: false)
    }

    static func closure(_ formal: SwiftFormalType, signature: SwiftFunctionSignature,
                                binding: SwiftGenericBinding) throws -> SwiftGenericClosurePlan {
        guard case .function(let parameters, let result, let failure, let isAsync) = formal else {
            preconditionFailure("A closure plan requires a function type.")
        }
        guard isAsync == signature.isAsync,
              failure != nil || signature.failure == Never.self else {
            throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: []))
        }
        let parameterPlan = try SwiftGenericParameters(formal: parameters, actual: signature.parameters, binding: binding, asynchronous: isAsync)
        if let failure { try binding.validate(signature.failure, for: failure) }
        let runtimeArguments: [SwiftCallbackRuntimeArgument?] = parameterPlan.arguments.enumerated().map { index, argument in
            guard case .runtimeValue(let plan, _, _) = argument else { return nil }
            let borrowed = signature.parameters[index] == NativeSwiftBorrowedValue.self
            return SwiftCallbackRuntimeArgument(plan: plan, borrowed: borrowed, asynchronous: isAsync)
        }
        var logicalTypes: [CValueType] = []
        var authentication = isAsync && signature.inheritsCallerIsolation ? ["-class"] : []
        for (formal, group) in zip(parameters, parameterPlan.groups) {
            switch group {
            case .pack(let range, _):
                guard case .pack(let pattern, _) = formal else {
                    preconditionFailure("A pack group has a pack formal type.")
                }
                for (packIndex, index) in range.enumerated() {
                    if let conversion = runtimeArguments[index] {
                        logicalTypes.append(try SwiftGenericParameters.storageType(conversion.plan.valueType.metadata))
                    } else {
                        try binding.selectingPackElement(at: packIndex).validate(signature.parameters[index], for: pattern)
                        logicalTypes.append(try SwiftGenericParameters.storageType(signature.parameters[index]))
                    }
                }
                // SIL pack values have an opaque type hash, distinct from an
                // ordinary formally indirect scalar (GenPointerAuth.cpp).
                authentication.append("-")
            case .value(let index):
                let actual = runtimeArguments[index]?.plan.valueType.metadata ?? signature.parameters[index]
                if runtimeArguments[index] == nil { try binding.validate(actual, for: formal) }
                logicalTypes.append(try layout(formal, actual: actual, binding: binding))
                authentication.append(contentsOf: try authTypes(formal, actual: actual, binding: binding))
            }
        }
        let types = parameterPlan.types(from: logicalTypes)
        let nativeResult = try binding.resultType(signature.result, for: result)
        let resultType = try layout(result, actual: nativeResult, binding: binding)
        let resultPlan: SwiftGenericResult = signature.result == NativeSwiftValue.self && nativeResult != signature.result
            ? .runtimeValue(try binding.runtimeValuePlan(metadata: nativeResult, type: resultType)) : .value(resultType)
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
            resultConstants: SwiftValueConstants(nativeResult), errorPlan: errorPlan,
            runtimeArguments: runtimeArguments, result: resultPlan, nativeResult: nativeResult)
    }

    private static func authTypes(_ formal: SwiftFormalType, actual: Any.Type,
                                  binding: SwiftGenericBinding, isResult: Bool = false) throws -> [String] {
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
            case .tuple(let fields, _):
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
            case .foreignFunction, .objectiveCClass:
                return try CValueType(scalar: ABIValuePointer)
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
        case .objectiveCClass: false
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
        declaredSignature: String? = nil
    ) throws -> NativeSwiftFunction<Signature> {
        guard let declaration = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The Swift declaration cannot be demangled.")
        }
        let plan = try SwiftGenericCallPlan(declaration: declaration, linkageName: symbol.linkageName, image: symbol.image, genericArguments: genericArguments,
                                            signature: SwiftFunctionSignature(signature), resolver: resolver, declaredSignature: declaredSignature)
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver, generic: plan)
    }
}
