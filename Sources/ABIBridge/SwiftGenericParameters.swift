import ABIBridgeCore

/// Maps source-level parameters to the original declaration's SIL parameters.
/// A variadic pack is one native address vector even after substitution makes
/// its elements separate parameters in the caller's function type.
struct SwiftGenericParameters: Sendable {
    enum Group: Sendable {
        case value(Int)
        case pack(Range<Int>, CValueType)
    }
    let arguments: [SwiftGenericArgument]
    let groups: [Group]
    let hasPacks: Bool
    private let constants: [SwiftValueConstants]
    var needsEncoding: Bool { hasPacks || arguments.contains { Self.expandedTuple($0) != nil } || constants.contains { !$0.isEmpty } }

    static func expandedTuple(_ argument: SwiftGenericArgument) -> SwiftTupleValuePlan? {
        argument.convention == .inoutValue ? nil : argument.tuple
    }

    private static func constants(for type: Any.Type, argument: SwiftGenericArgument) -> SwiftValueConstants {
        if expandedTuple(argument) != nil { return SwiftValueConstants(Void.self) }
        switch argument {
        case .value(let layout, _):
            return SwiftValueConstants(ABISwiftValueIsIndirect(layout.handle) ? Void.self : type)
        case .runtimeValue(let plan, let convention, _):
            return SwiftValueConstants(convention == .inoutValue || ABISwiftValueIsIndirect(plan.type.handle)
                ? Void.self : plan.valueType.metadata)
        case .convention(let codec):
            if codec.convention == .inoutValue { return SwiftValueConstants(Void.self) }
            return constants(for: (type as! any SwiftConventionArgument.Type).wrappedType, argument: codec.argument)
        default: return SwiftValueConstants(type)
        }
    }

    static func concreteArguments(signature: SwiftFunctionSignature, defaultConsuming: Bool = false) throws -> [SwiftGenericArgument] {
        try signature.parameters.map { type in
            if let convention = type as? any SwiftConventionArgument.Type {
                let nested: SwiftGenericArgument
                if let tuple = try SwiftGenericCallPlan.concreteTuple(convention.wrappedType) {
                    nested = .tuple(tuple, consuming: convention.convention == .consuming, asynchronous: signature.isAsync)
                } else if signature.isAsync, let closure = convention.wrappedType as? any SwiftClosureValue.Type {
                    nested = .closure(try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType), asynchronous: true)
                } else { nested = .concrete }
                return .convention(try convention.makeArgumentCodec(generic: nested))
            }
            if let tuple = try SwiftGenericCallPlan.concreteTuple(type) {
                return .tuple(tuple, consuming: defaultConsuming, asynchronous: signature.isAsync)
            }
            return .concrete
        }
    }

    init(formal: [SwiftFormalType], actual: [Any.Type], binding: SwiftGenericBinding, defaultConsuming: Bool = false,
         asynchronous: Bool? = nil, callback: Bool = false) throws {
        var arguments: [SwiftGenericArgument] = []
        var groups: [Group] = []
        var index = 0
        var hasPacks = false
        for parameter in formal {
            if case .pack(let pattern, let shape) = parameter {
                let count = try binding.packCount(in: shape ?? pattern)
                guard index + count <= actual.count else { throw Self.mismatch(actual.count) }
                let range = index..<(index + count)
                for (packIndex, position) in range.enumerated() {
                    let element = binding.selectingPackElement(at: packIndex)
                    arguments.append(try SwiftGenericCallPlan.argument(pattern, actual: actual[position], binding: element,
                        defaultConsuming: defaultConsuming, asynchronous: asynchronous, callback: callback))
                }
                groups.append(.pack(range, try CValueType(indirectSwiftSize: count * MemoryLayout<UInt>.size,
                                                           alignment: MemoryLayout<UInt>.alignment)))
                hasPacks = true
                index += count
            } else {
                guard index < actual.count else { throw Self.mismatch(actual.count) }
                groups.append(.value(index))
                arguments.append(try SwiftGenericCallPlan.argument(parameter, actual: actual[index], binding: binding,
                    defaultConsuming: defaultConsuming, asynchronous: asynchronous, callback: callback))
                index += 1
            }
        }
        guard index == actual.count else { throw Self.mismatch(actual.count) }
        self.arguments = arguments
        self.groups = groups
        self.hasPacks = hasPacks
        constants = zip(actual, arguments).map { Self.constants(for: $0, argument: $1) }
    }

    init(actual: [Any.Type], arguments: [SwiftGenericArgument], groups: [Group]? = nil) {
        self.arguments = arguments
        self.groups = groups ?? actual.indices.map { .value($0) }
        hasPacks = self.groups.contains { if case .pack = $0 { true } else { false } }
        constants = zip(actual, arguments).map { Self.constants(for: $0, argument: $1) }
    }

    static func storageType(_ type: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    private static func mismatch(_ count: Int) -> ABIResolutionError {
        .signatureMismatch(.init(expected: "The instantiated declaration's argument count", found: ["\(count) arguments"]))
    }

    func types(from logical: [CValueType]) -> [CValueType] {
        groups.flatMap {
            switch $0 {
            case .value(let index): Self.expandedTuple(arguments[index])?.argumentTypes ?? [logical[index]]
            case .pack(_, let type): [type]
            }
        }
    }

    struct Encoded {
        let addresses: [UnsafeMutableRawPointer?]
        let storage: [NativeValueStorage]
        var consumed: [NativeValueStorage] = []

        func finishInvocation() {
            for value in consumed { value.relinquishValue() }
        }
    }

    func encode(_ logical: [UnsafeMutableRawPointer?], retaining owners: [NativeValueStorage] = [], consuming: Bool = false) -> Encoded {
        guard needsEncoding else { return Encoded(addresses: logical, storage: []) }
        var packs: [NativeValueStorage] = []
        var consumed: [NativeValueStorage] = []
        let addresses = groups.flatMap { group -> [UnsafeMutableRawPointer?] in
            switch group {
            case .value(let index):
                if let tuple = Self.expandedTuple(arguments[index]) {
                    let encoded = tuple.encodeArguments(from: logical[index]!, retaining: owners.isEmpty ? nil : owners[index],
                        consuming: consuming || arguments[index].convention == .consuming)
                    packs += encoded.storage
                    consumed += encoded.consumed
                    return encoded.addresses
                }
                return [logical[index]]
            case .pack(let range, let type):
                let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
                for (element, index) in range.enumerated() {
                    let address: UnsafeMutableRawPointer?
                    if let tuple = Self.expandedTuple(arguments[index]) {
                        let consuming = consuming || arguments[index].convention == .consuming
                        let value = tuple.materializeArgument(from: logical[index]!, consuming: consuming,
                            retaining: owners.isEmpty ? nil : owners[index])
                        packs.append(value)
                        if consuming { consumed.append(value) }
                        address = value.address
                    } else { address = logical[index] }
                    storage.address.storeBytes(of: address,
                        toByteOffset: element * MemoryLayout<UInt>.size, as: UnsafeMutableRawPointer?.self)
                }
                packs.append(storage)
                return [storage.address]
            }
        }
        return Encoded(addresses: addresses, storage: packs, consumed: consumed)
    }

    func encode(_ logical: Encoded) -> Encoded {
        let encoded = encode(logical.addresses)
        return Encoded(addresses: encoded.addresses, storage: logical.storage + encoded.storage,
                       consumed: logical.consumed + encoded.consumed)
    }

    func unpack(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> Encoded {
        var addresses: [UnsafeMutableRawPointer?] = []
        var storage: [NativeValueStorage] = []
        var index = 0
        for group in groups {
            switch group {
            case .value(let logical):
                if let tuple = Self.expandedTuple(arguments[logical]) {
                    let unpacked = tuple.unpackArguments(native?.advanced(by: index))
                    storage += unpacked.storage
                    let vector = NativeValueStorage(size: tuple.leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment)
                    for element in tuple.leaves.indices {
                        vector.address.storeBytes(of: unpacked.addresses[element],
                            toByteOffset: element * MemoryLayout<UnsafeMutableRawPointer?>.stride, as: UnsafeMutableRawPointer?.self)
                    }
                    storage.append(vector)
                    addresses.append(vector.address)
                    index += tuple.argumentTypes.count
                } else {
                    let address = native![index]
                    if let address, !constants[logical].isEmpty {
                        let restored = constants[logical].copyStorage(from: address)
                        storage.append(restored)
                        addresses.append(restored.address)
                    } else { addresses.append(address) }
                    index += 1
                }
            case .pack(let range, _):
                for element in 0..<range.count {
                    let value = native![index]!.load(fromByteOffset: element * MemoryLayout<UInt>.size,
                                                    as: UnsafeMutableRawPointer?.self)
                    if let tuple = Self.expandedTuple(arguments[range.lowerBound + element]) {
                        let leaves = tuple.nativeArgumentAddresses(value!)
                        let vector = NativeValueStorage(size: leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                            alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment)
                        for (position, address) in leaves.enumerated() {
                            vector.address.storeBytes(of: address,
                                toByteOffset: position * MemoryLayout<UnsafeMutableRawPointer?>.stride, as: UnsafeMutableRawPointer?.self)
                        }
                        storage.append(vector)
                        addresses.append(vector.address)
                    } else { addresses.append(value) }
                }
                index += 1
            }
        }
        return Encoded(addresses: addresses, storage: storage)
    }
}
