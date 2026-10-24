import ABIBridgeCore

/// Maps source-level parameters to the original declaration's SIL parameters. A variadic pack is one native address vector even after substitution makes its elements separate parameters in the caller's function type.
struct SwiftGenericParameters: Sendable {
    enum Group: Sendable {
        case value(Int)
        case pack(Range<Int>, CValueType)
    }
    let arguments: [SwiftGenericArgument]
    let groups: [Group]
    let hasPacks: Bool
    private let expandsTuples: Bool
    var usesStorageConvention: Bool { !expandsTuples }
    private var addressed: [Int: CValueType] = [:]
    private let constants: [SwiftValueConstants]
    var needsEncoding: Bool { hasPacks || arguments.contains { Self.expandedTuple($0) != nil } || constants.contains { !$0.isEmpty } }

    private func expandedTuple(_ argument: SwiftGenericArgument) -> SwiftTupleValuePlan? {
        expandsTuples ? Self.expandedTuple(argument) : nil
    }

    func passesByAddress(_ index: Int) -> Bool { addressed[index] != nil }

    var hasAddressedClosureFields: Bool {
        addressed.keys.contains { arguments[$0].tuple?.hasNestedClosures == true }
    }

    func passingByAddress(_ types: [Int: CValueType], binding: SwiftGenericBinding? = nil) throws -> Self {
        var arguments = arguments
        if let binding {
            func storage(_ argument: SwiftGenericArgument) throws -> SwiftGenericArgument {
                switch argument {
                case .tuple(let tuple, let consuming, let asynchronous):
                    return .tuple(try tuple.usingStorageConvention(binding: binding),
                                  consuming: consuming, asynchronous: asynchronous)
                case .runtimeValue(let plan, let convention, let asynchronous):
                    return .runtimeValue(try plan.usingTupleStorageConvention(binding: binding),
                                         convention: convention, asynchronous: asynchronous)
                case .convention(let conversion):
                    guard let tuple = conversion.tuple,
                          let wrapper = conversion.host as? any SwiftConventionArgument.Type else { return argument }
                    return .convention(try wrapper.makeConversion(
                        generic: .tuple(try tuple.usingStorageConvention(binding: binding))))
                default: return argument
                }
            }
            for index in types.keys { arguments[index] = try storage(arguments[index]) }
        }
        var result = Self(arguments: arguments, groups: groups, hasPacks: hasPacks,
                          constants: constants, expandsTuples: expandsTuples)
        result.addressed = types
        return result
    }

    func usingStorageConvention() -> Self {
        Self(arguments: arguments, groups: groups, hasPacks: hasPacks, constants: constants, expandsTuples: false)
    }

    private init(arguments: [SwiftGenericArgument], groups: [Group], hasPacks: Bool,
                 constants: [SwiftValueConstants], expandsTuples: Bool) {
        self.arguments = arguments; self.groups = groups; self.hasPacks = hasPacks
        self.constants = constants; self.expandsTuples = expandsTuples
    }

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
        case .convention(let conversion):
            guard case .ownership(let convention, let value) = conversion.kind,
                convention != .inoutValue
            else { return SwiftValueConstants(Void.self) }
            return constants(of: value)
        default: return SwiftValueConstants(type)
        }
    }

    /// The constants to restore in a native value that `conversion`
    /// receives directly, which a borrowing or consuming wrapper passes.
    private static func constants(of conversion: SwiftHostConversion) -> SwiftValueConstants {
        // A tuple's elements arrive separately.
        if conversion.tuple != nil { return SwiftValueConstants(Void.self) }
        if case .ownership(let convention, let value) = conversion.kind {
            return convention == .inoutValue ? SwiftValueConstants(Void.self) : constants(of: value)
        }
        let metadata = conversion.runtimeValue?.valueType.metadata ?? conversion.host
        return SwiftValueConstants(
            ABISwiftValueIsIndirect(conversion.type.handle) ? Void.self : metadata
        )
    }

    static func concreteArguments(signature: SwiftFunctionSignature, defaultConsuming: Bool = false) throws -> [SwiftGenericArgument] {
        try signature.parameters.map { type in
            if let convention = type as? any SwiftConventionArgument.Type {
                let nested: SwiftGenericArgument
                if let tuple = try SwiftTupleValuePlan(
                    host: convention.wrappedType,
                    position: .parameter
                ) {
                    nested = .tuple(tuple, consuming: convention.convention == .consuming, asynchronous: signature.isAsync)
                } else if signature.isAsync, let closure = convention.wrappedType as? any SwiftClosureValue.Type {
                    nested = .closure(try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType), asynchronous: true)
                } else {
                    nested = .host(
                        try SwiftHostConversion(host: convention.wrappedType, position: .parameter)
                    )
                }
                return .convention(try convention.makeConversion(generic: nested))
            }
            if let tuple = try SwiftTupleValuePlan(host: type, position: .parameter) {
                return .tuple(tuple, consuming: defaultConsuming, asynchronous: signature.isAsync)
            }
            return .host(
                try SwiftHostConversion(
                    host: type,
                    asynchronous: signature.isAsync,
                    position: .parameter
                )
            )
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
                        defaultConsuming: defaultConsuming, asynchronous: asynchronous, callback: callback,
                        position: .parameter))
                }
                groups.append(.pack(range, try CValueType(indirectSwiftSize: count * MemoryLayout<UInt>.size,
                                                           alignment: MemoryLayout<UInt>.alignment)))
                hasPacks = true
                index += count
            } else {
                guard index < actual.count else { throw Self.mismatch(actual.count) }
                groups.append(.value(index))
                arguments.append(try SwiftGenericCallPlan.argument(parameter, actual: actual[index], binding: binding,
                    defaultConsuming: defaultConsuming, asynchronous: asynchronous, callback: callback,
                        position: .parameter))
                index += 1
            }
        }
        guard index == actual.count else { throw Self.mismatch(actual.count) }
        self.arguments = arguments
        self.groups = groups
        self.hasPacks = hasPacks
        expandsTuples = true
        constants = zip(actual, arguments).map { Self.constants(for: $0, argument: $1) }
    }

    init(actual: [Any.Type], arguments: [SwiftGenericArgument], groups: [Group]? = nil) {
        self.arguments = arguments
        self.groups = groups ?? actual.indices.map { .value($0) }
        expandsTuples = true
        hasPacks = self.groups.contains { if case .pack = $0 { true } else { false } }
        constants = zip(actual, arguments).map { Self.constants(for: $0, argument: $1) }
    }

    private static func mismatch(_ count: Int) -> ABIResolutionError {
        .signatureMismatch(.init(expected: "The instantiated declaration's argument count", found: ["\(count) arguments"]))
    }

    func types(from logical: [CValueType]) -> [CValueType] {
        groups.flatMap {
            switch $0 {
            case .value(let index):
                addressed[index].map { [$0] } ?? expandedTuple(arguments[index])?.argumentTypes ?? [
                    logical[index]
                ]
            case .pack(_, let type): [type]
            }
        }
    }

    struct Encoded {
        let addresses: [UnsafeMutableRawPointer?]
        let storage: [NativeValueStorage]
        var consumed: [NativeValueStorage] = []
        // An unpacked whole tuple also has a leaf-address vector for host
        // conversion. Forward its original storage across reabstraction.
        var nativeAddresses: [Int: UnsafeMutableRawPointer] = [:]

        func finishInvocation() {
            for value in consumed { value.relinquishValue() }
        }
    }

    func encode(_ logical: [UnsafeMutableRawPointer?], retaining owners: [NativeValueStorage] = [], consuming: Bool = false,
                nativeAddresses: [Int: UnsafeMutableRawPointer] = [:]) -> Encoded {
        guard needsEncoding else { return Encoded(addresses: logical, storage: []) }
        var packs: [NativeValueStorage] = []
        var consumed: [NativeValueStorage] = []
        let addresses = groups.flatMap { group -> [UnsafeMutableRawPointer?] in
            switch group {
            case .value(let index):
                if let tuple = Self.expandedTuple(arguments[index]) {
                    let consuming = consuming || arguments[index].convention == .consuming
                    let owner = owners.isEmpty ? nil : owners[index]
                    if expandsTuples && addressed[index] == nil {
                        let encoded = tuple.encodeArguments(from: logical[index]!, retaining: owner, consuming: consuming)
                        packs += encoded.storage
                        consumed += encoded.consumed
                        return encoded.addresses
                    }
                    if !consuming, let original = nativeAddresses[index] { return [original] }
                    let value = tuple.materializeArgument(from: logical[index]!, consuming: consuming, retaining: owner)
                    packs.append(value)
                    if consuming { consumed.append(value) }
                    return [value.address]
                }
                return [logical[index]]
            case .pack(let range, let type):
                let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
                for (element, index) in range.enumerated() {
                    let address: UnsafeMutableRawPointer?
                    if let tuple = Self.expandedTuple(arguments[index]) {
                        let consuming = consuming || arguments[index].convention == .consuming
                        if !consuming, let original = nativeAddresses[index] { address = original }
                        else {
                            let value = tuple.materializeArgument(from: logical[index]!, consuming: consuming,
                                retaining: owners.isEmpty ? nil : owners[index])
                            packs.append(value)
                            if consuming { consumed.append(value) }
                            address = value.address
                        }
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
        let encoded = encode(logical.addresses, nativeAddresses: logical.nativeAddresses)
        return Encoded(addresses: encoded.addresses, storage: logical.storage + encoded.storage,
                       consumed: logical.consumed + encoded.consumed)
    }

    func unpack(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> Encoded {
        var addresses: [UnsafeMutableRawPointer?] = []
        var storage: [NativeValueStorage] = []
        var nativeAddresses: [Int: UnsafeMutableRawPointer] = [:]
        var index = 0
        for group in groups {
            switch group {
            case .value(let logical):
                if let tuple = Self.expandedTuple(arguments[logical]) {
                    let unpacked: Encoded
                    let expanded = expandsTuples && addressed[logical] == nil
                    if expanded {
                        unpacked = tuple.unpackArguments(native?.advanced(by: index))
                    }
                    else {
                        let address = native![index]!
                        nativeAddresses[logical] = address
                        unpacked = Encoded(addresses: tuple.nativeArgumentAddresses(address), storage: [])
                    }
                    storage += unpacked.storage
                    let vector = NativeValueStorage(size: tuple.leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment)
                    for element in tuple.leaves.indices {
                        vector.address.storeBytes(of: unpacked.addresses[element],
                            toByteOffset: element * MemoryLayout<UnsafeMutableRawPointer?>.stride, as: UnsafeMutableRawPointer?.self)
                    }
                    storage.append(vector)
                    addresses.append(vector.address)
                    index += expanded ? tuple.argumentTypes.count : 1
                } else {
                    let address = native![index]
                    if let address, addressed[logical] == nil, !constants[logical].isEmpty {
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
                        nativeAddresses[range.lowerBound + element] = value!
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
        return Encoded(addresses: addresses, storage: storage, nativeAddresses: nativeAddresses)
    }
}
