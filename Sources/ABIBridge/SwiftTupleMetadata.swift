import ABIBridgeCore

typealias SwiftResultInitializer = @Sendable (Int, Int, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void

func swiftResultInitializer(nativeMetadata: Any.Type, generic: SwiftGenericResult = .concrete,
                            tuple: SwiftTupleValuePlan? = nil) -> SwiftResultInitializer {
    if let tuple {
        return { tuple.initializeNativeResult(logicalOffset: $0, size: $1, destination: $2, source: $3) }
    }
    if case .tuple(let tuple) = generic {
        return { tuple.initializeNativeResult(logicalOffset: $0, size: $1, destination: $2, source: $3) }
    }
    let closureResult: Bool
    if case .closure = generic { closureResult = true }
    else if case .concrete = generic { closureResult = nativeMetadata is any SwiftClosureValue.Type }
    else { closureResult = false }
    if closureResult {
        return { offset, size, destination, source in
            precondition(offset == 0 && size == MemoryLayout<ABISwiftClosureValue>.size,
                         "A prepared closure result transfers one native function/context pair.")
            destination.copyMemory(from: source, byteCount: size)
        }
    }
    let metadata: Any.Type
    if case .runtimeValue(let plan) = generic { metadata = plan.valueType.metadata }
    else { metadata = nativeMetadata }
    func projections(_ type: Any.Type, at offset: Int) -> [SwiftTupleValuePlan.NativeProjection] {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        let value = SwiftTupleValuePlan.NativeProjection(offset: offset, size: layout.size, metadata: type)
        guard let tuple = SwiftTupleMetadata(type) else { return [value] }
        return [value] + tuple.elements.flatMap { projections($0.type, at: offset + $0.offset) }
    }
    let prepared = projections(metadata, at: 0)
    return { offset, size, destination, source in
        guard let projection = prepared.first(where: { $0.offset == offset && $0.size == size }) else {
            preconditionFailure("A prepared callback result selects a complete native value projection.")
        }
        ABISwiftTakeValue(unsafeBitCast(projection.metadata, to: UnsafeRawPointer.self), destination, source)
    }
}

/// Swift tuple metadata supplies the instantiated element offsets, which need
/// not match a C struct's tail-padding rules.
struct SwiftTupleMetadata {
    struct Element {
        let type: Any.Type
        let offset: Int
    }
    let elements: [Element]
    let labels: [String]

    init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x301 else { return nil }
        let count = metadata.load(fromByteOffset: word, as: Int.self)
        if let names = metadata.load(fromByteOffset: 2 * word, as: UnsafePointer<CChar>?.self) {
            labels = String(cString: names).split(separator: " ", omittingEmptySubsequences: false).prefix(count).map(String.init)
        } else { labels = Array(repeating: "", count: count) }
        elements = (0..<count).map {
            Element(type: metadata.load(fromByteOffset: (3 + 2 * $0) * word, as: Any.Type.self),
                    offset: metadata.load(fromByteOffset: (4 + 2 * $0) * word, as: Int.self))
        }
    }

    func layout<Value>(for type: Value.Type, fields: [CValueType]) throws -> CValueType {
        try CValueType(swiftTuple: fields, offsets: elements.map(\.offset),
                       size: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
    }
}

struct SwiftTupleValuePlan: Sendable {
    struct Field: Sendable {
        let hostType: Any.Type
        let nativeType: Any.Type
        let hostOffset: Int
        let nativeOffset: Int
        let argument: SwiftGenericArgument
        let result: SwiftGenericResult
        let nativeClosure: SwiftGenericClosurePlan?
        let tuple: SwiftTupleValuePlan?
        fileprivate let leaves: [Leaf]
        var type: CValueType { tuple?.type ?? leaves[0].type }

        init(hostType: Any.Type, nativeType: Any.Type, hostOffset: Int, nativeOffset: Int,
             argument: SwiftGenericArgument, result: SwiftGenericResult,
             tuple: SwiftTupleValuePlan? = nil, nativeClosure: SwiftGenericClosurePlan? = nil) throws {
            self.hostType = hostType; self.nativeType = nativeType
            self.hostOffset = hostOffset; self.nativeOffset = nativeOffset
            self.argument = argument; self.result = result; self.tuple = tuple; self.nativeClosure = nativeClosure
            if let tuple {
                leaves = tuple.leaves.map { $0.rebased(host: hostOffset, native: nativeOffset) }
            } else {
                func prepare<Value>(_ type: Value.Type) throws -> Leaf {
                    try Leaf(hostType: type, nativeType: nativeType, hostOffset: hostOffset,
                             nativeOffset: nativeOffset, argument: argument, result: result, nativeClosure: nativeClosure)
                }
                leaves = [try _openExistential(hostType, do: prepare)]
            }
        }
    }

    fileprivate typealias HostDecoder = @Sendable (UnsafeMutableRawPointer, SwiftCallbackScope, UnsafeMutableRawPointer) throws -> Void

    struct Leaf: Sendable {
        let hostType: Any.Type
        let nativeType: Any.Type
        private(set) var hostOffset: Int
        private(set) var nativeOffset: Int
        let type: CValueType
        let argument: SwiftGenericArgument
        let result: SwiftGenericResult
        let nativeClosure: SwiftGenericClosurePlan?
        let nativeSize: Int
        fileprivate let constants: SwiftValueConstants
        fileprivate let codeLifetime: SwiftValueCodeLifetime?
        fileprivate let encodeArgument: @Sendable (UnsafeRawPointer, Bool, Bool, Any?) throws -> NativeValueStorage
        fileprivate let encodeResult: @Sendable (UnsafeRawPointer, Any?) throws -> NativeValueStorage
        fileprivate let encodeCopy: @Sendable (UnsafeRawPointer, Any?) throws -> (NativeValueStorage, Bool)
        fileprivate let decodeResult: @Sendable (NativeValueStorage, Any?, Any?, UnsafeMutableRawPointer) throws -> Void
        fileprivate let copyNative: @Sendable (UnsafeRawPointer, Any?, SwiftValueCodeLifetime?, SwiftCallbackScope?, UnsafeMutableRawPointer) throws -> Void
        fileprivate let callback: @Sendable (Bool) throws -> HostDecoder
        fileprivate let validateOwnedResult: @Sendable () throws -> Void
        fileprivate let destroyHost: @Sendable (UnsafeMutableRawPointer) -> Void

        fileprivate init<Value>(hostType: Value.Type, nativeType: Any.Type, hostOffset: Int, nativeOffset: Int,
                                argument: SwiftGenericArgument, result: SwiftGenericResult,
                                nativeClosure: SwiftGenericClosurePlan?) throws {
            self.hostType = hostType; self.nativeType = nativeType
            self.hostOffset = hostOffset; self.nativeOffset = nativeOffset
            self.argument = argument; self.result = result; self.nativeClosure = nativeClosure
            let metadata = unsafeBitCast(nativeType, to: UnsafeRawPointer.self)
            let layout = ABISwiftGetValueLayout(metadata)
            nativeSize = layout.size
            let inputRuntime = argument.runtimeValue
            let outputRuntime: SwiftRuntimeValuePlan?
            if case .runtimeValue(let plan) = result { outputRuntime = plan } else { outputRuntime = nil }
            let fieldLifetime = outputRuntime?.valueType.codeLifetime ?? inputRuntime?.valueType.codeLifetime
            codeLifetime = fieldLifetime

            let borrowed = try SwiftArgumentCodec<Value>(defaultConsuming: false, generic: argument)
            let consumed = try SwiftArgumentCodec<Value>(defaultConsuming: true, generic: argument)
            type = borrowed.type
            constants = SwiftValueConstants(ABISwiftValueIsIndirect(borrowed.type.handle) ? Void.self : nativeType)
            encodeArgument = { address, consuming, asynchronous, owner in
                let value = address.load(as: Value.self)
                if let inputRuntime {
                    return try inputRuntime.encode(value, convention: consuming ? .consuming : .borrowing,
                                                   asynchronous: asynchronous)
                }
                if case .closure(let plan, _) = argument {
                    return try (value as! any SwiftClosureValue).encodeGenericClosure(plan: plan,
                        retainingCode: owner, asynchronous: asynchronous, consuming: consuming)
                }
                return try consuming ? consumed.encode(value, retainingCode: owner) : borrowed.encode(value, retainingCode: owner)
            }

            let outputClosure: SwiftClosureCodec?
            if case .closure(let codec) = result { outputClosure = codec }
            else if case .concrete = result, let closure = Value.self as? any SwiftClosureValue.Type {
                outputClosure = try closure.makeClosureCodec()
            } else { outputClosure = nil }
            let ordinary: SwiftValueCodec<Value>?
            if case .concrete = result, outputClosure == nil { ordinary = try SwiftValueCodec<Value>() }
            else { ordinary = nil }
            let hostConstants = SwiftValueConstants(Value.self)
            let encode: @Sendable (UnsafeRawPointer, Any?) throws -> NativeValueStorage = { address, owner in
                let value = address.load(as: Value.self)
                if let outputRuntime { return try outputRuntime.encode(value, convention: .consuming, asynchronous: false) }
                if let outputClosure {
                    return try outputClosure.encodeValue?(value, owner)
                        ?? (value as! any SwiftClosureValue).encodeClosureResult()
                }
                if let ordinary { return try ordinary.encode(value, consuming: true) }
                let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
                storage.initialize(value)
                return storage
            }
            encodeResult = encode
            encodeCopy = { address, owner in
                if let runtime = outputRuntime ?? inputRuntime {
                    guard SwiftCopyability.accepts(runtime.valueType.metadata) else { throw NativeSwiftValueError.noncopyableType }
                    return (try runtime.encode(address.load(as: Value.self), convention: .borrowing, asynchronous: false), true)
                }
                return (try encode(address, owner), false)
            }
            validateOwnedResult = {
                if let outputRuntime {
                    guard Value.self != NativeSwiftBorrowedValue.self else {
                        throw ABIResolutionError.unsupportedDeclaration("A scoped runtime tuple field requires its callback borrow scope.")
                    }
                    try outputRuntime.requireOwnedValue()
                }
            }
            let decode: @Sendable (NativeValueStorage, Any?, Any?, UnsafeMutableRawPointer) throws -> Void = { storage, owner, codeOwner, output in
                let value: Value
                if let outputRuntime {
                    guard Value.self != NativeSwiftBorrowedValue.self else {
                        throw ABIResolutionError.unsupportedDeclaration("A scoped runtime tuple field requires its callback borrow scope.")
                    }
                    value = try outputRuntime.decode(storage) as! Value
                } else if let outputClosure {
                    // Closure adoption consumes its +1 even when entry preparation fails.
                    storage.relinquishValue()
                    value = try outputClosure.makeValue(storage.address.load(as: ABISwiftClosureValue.self),
                                                        codeOwner, true, storage.codeLifetime) as! Value
                } else if let ordinary {
                    value = try ordinary.decode(storage, retaining: owner, retainingCode: codeOwner)
                } else {
                    hostConstants.initialize(at: storage.address)
                    value = storage.take(as: Value.self)
                }
                output.initializeMemory(as: Value.self, repeating: value, count: 1)
            }
            decodeResult = decode
            copyNative = { source, codeOwner, lifetime, scope, output in
                if let runtime = outputRuntime ?? inputRuntime {
                    guard SwiftCopyability.accepts(runtime.valueType.metadata) else { throw NativeSwiftValueError.noncopyableType }
                }
                let lifetime = SwiftValueCodeLifetime.connect([lifetime, fieldLifetime, SwiftValueCodeLifetime.current].compactMap { $0 }, retaining: [])
                let storage = NativeValueStorage(size: layout.stride, alignment: layout.alignment, codeLifetime: lifetime)
                ABISwiftCopyValue(unsafeBitCast(nativeType, to: UnsafeRawPointer.self), storage.address, source)
                storage.assumeInitialized {
                    ABISwiftDestroyValue(unsafeBitCast(nativeType, to: UnsafeRawPointer.self), $0)
                }
                if Value.self == NativeSwiftBorrowedValue.self, let runtime = outputRuntime ?? inputRuntime {
                    guard let scope else {
                        throw ABIResolutionError.unsupportedDeclaration("A scoped runtime tuple field requires its callback borrow scope.")
                    }
                    let retained = runtime.valueType.retainingCode(lifetime ?? runtime.valueType.codeLifetime)
                    let value = NativeSwiftBorrowedValue(type: retained, borrow: scope.borrow(storage.address, retaining: storage))
                    output.initializeMemory(as: Value.self, repeating: value as! Value, count: 1)
                } else {
                    try decode(storage, nil, codeOwner, output)
                }
            }
            callback = { consuming in
                if consuming, Value.self == NativeSwiftBorrowedValue.self, inputRuntime != nil {
                    throw ABIResolutionError.unsupportedDeclaration("A borrowed runtime value cannot be consumed.")
                }
                let decoder = try SwiftCallbackValues.decoder(for: Value.self, generic: argument, consuming: consuming)
                return { source, scope, output in
                    let value = try decoder(source, scope) as! Value
                    output.initializeMemory(as: Value.self, repeating: value, count: 1)
                }
            }
            destroyHost = { $0.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
        }

        fileprivate func rebased(host: Int, native: Int) -> Self {
            var result = self
            result.hostOffset += host; result.nativeOffset += native
            return result
        }
    }

    struct NativeProjection: Sendable {
        let offset: Int
        let size: Int
        let metadata: Any.Type
    }
    let hostMetadata: Any.Type
    let nativeMetadata: Any.Type
    let type: CValueType
    let fields: [Field]
    let leaves: [Leaf]
    private let parameters: SwiftGenericParameters
    let argumentTypes: [CValueType]
    let nativeProjections: [NativeProjection]
    var needsConversion: Bool {
        leaves.contains { leaf in
            if leaf.argument.runtimeValue != nil || leaf.argument.closure != nil { return true }
            switch leaf.result { case .runtimeValue, .closure: return true; default: return false }
        }
    }
    var hasNestedClosures: Bool {
        leaves.contains { leaf in
            if leaf.argument.closure != nil || leaf.nativeClosure != nil { return true }
            if case .closure = leaf.result { return true }
            return false
        }
    }
    private let hostStride: Int
    private let hostAlignment: Int
    private let nativeStride: Int
    private let nativeAlignment: Int
    private let nativeConstants: SwiftValueConstants
    private let takeHost: @Sendable (NativeValueStorage) -> Any

    init(hostMetadata: Any.Type, nativeMetadata: Any.Type, type: CValueType, fields: [Field],
         groups: [SwiftGenericParameters.Group]? = nil) throws {
        self.hostMetadata = hostMetadata; self.nativeMetadata = nativeMetadata
        self.type = type; self.fields = fields
        leaves = fields.flatMap(\.leaves)
        let parameters = SwiftGenericParameters(actual: fields.map(\.hostType), arguments: fields.map(\.argument), groups: groups)
        self.parameters = parameters
        argumentTypes = parameters.types(from: fields.map(\.type))
        let host = ABISwiftGetValueLayout(unsafeBitCast(hostMetadata, to: UnsafeRawPointer.self))
        hostStride = host.stride; hostAlignment = host.alignment
        let native = ABISwiftGetValueLayout(unsafeBitCast(nativeMetadata, to: UnsafeRawPointer.self))
        nativeStride = native.stride; nativeAlignment = native.alignment
        nativeConstants = SwiftValueConstants(nativeMetadata)
        nativeProjections = [.init(offset: 0, size: native.size, metadata: nativeMetadata)] + fields.flatMap { field in
            if let tuple = field.tuple {
                return tuple.nativeProjections.map {
                    NativeProjection(offset: field.nativeOffset + $0.offset, size: $0.size, metadata: $0.metadata)
                }
            }
            let layout = ABISwiftGetValueLayout(unsafeBitCast(field.nativeType, to: UnsafeRawPointer.self))
            return [NativeProjection(offset: field.nativeOffset, size: layout.size, metadata: field.nativeType)]
        }
        func prepare<Host>(_ type: Host.Type) -> @Sendable (NativeValueStorage) -> Any {
            { $0.take(as: Host.self) }
        }
        takeHost = _openExistential(hostMetadata, do: prepare)
    }

    func validateOwnedResult() throws {
        for leaf in leaves { try leaf.validateOwnedResult() }
    }

    // Argument storage is a vector of independently owned/borrowed leaf addresses,
    // not a contiguous native tuple. Formal packs group these addresses separately.
    func encodeArgument(fromHost source: UnsafeRawPointer, consuming: Bool, asynchronous: Bool,
                        retainingCode owner: Any? = nil) throws -> NativeValueStorage {
        let values = try leaves.map { try $0.encodeArgument(source.advanced(by: $0.hostOffset), consuming, asynchronous, owner) }
        let lifetime = SwiftValueCodeLifetime.connect(values.compactMap(\.codeLifetime)
            + [SwiftValueCodeLifetime.current].compactMap { $0 }, retaining: [])
        let owner = SwiftTupleArgumentOwner(values)
        let storage = NativeValueStorage(size: leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
            alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment, owner: owner, codeLifetime: lifetime,
            didRelinquish: consuming ? { owner.relinquish() } : nil)
        for (index, value) in values.enumerated() {
            storage.address.storeBytes(of: Optional(value.address),
                toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride, as: UnsafeMutableRawPointer?.self)
        }
        return storage
    }

    func argumentAddresses(_ storage: NativeValueStorage) -> [UnsafeMutableRawPointer?] {
        Array(UnsafeBufferPointer(start: storage.address.assumingMemoryBound(to: UnsafeMutableRawPointer?.self), count: leaves.count))
    }

    func nativeArgumentAddresses(_ native: UnsafeMutableRawPointer) -> [UnsafeMutableRawPointer?] {
        leaves.map { native.advanced(by: $0.nativeOffset) }
    }

    func encodeArguments(from vector: UnsafeMutableRawPointer, retaining owner: NativeValueStorage? = nil,
                         consuming: Bool = false) -> SwiftGenericParameters.Encoded {
        let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        var offset = 0
        let logical = fields.map { field -> UnsafeMutableRawPointer? in
            defer { offset += field.leaves.count }
            if SwiftGenericParameters.expandedTuple(field.argument) != nil {
                return UnsafeMutableRawPointer(addresses.advanced(by: offset))
            }
            return addresses[offset]
        }
        return parameters.encode(logical, retaining: owner.map { Array(repeating: $0, count: fields.count) } ?? [], consuming: consuming)
    }

    func unpackArguments(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> SwiftGenericParameters.Encoded {
        let unpacked = parameters.unpack(native)
        let addresses = zip(fields, unpacked.addresses).flatMap { field, address -> [UnsafeMutableRawPointer?] in
            if SwiftGenericParameters.expandedTuple(field.argument) != nil {
                return Array(UnsafeBufferPointer(start: address!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                                                 count: field.leaves.count))
            }
            return [address]
        }
        return .init(addresses: addresses, storage: unpacked.storage, consumed: unpacked.consumed)
    }

    // A formal pack stores each tuple element contiguously. A consuming element
    // temporarily moves its leaves and restores them unless native invocation commits.
    func materializeArgument(from vector: UnsafeMutableRawPointer, consuming: Bool,
                             retaining owner: AnyObject? = nil) -> NativeValueStorage {
        let addresses = Array(UnsafeBufferPointer(
            start: vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self), count: leaves.count))
        let lifetime = SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime.current].compactMap { $0 }
            + leaves.compactMap(\.codeLifetime), retaining: [])
        let storage = NativeValueStorage(size: nativeStride, alignment: nativeAlignment, owner: owner,
            codeLifetime: lifetime, destroyingWith: { value in
                if consuming {
                    for (leaf, address) in zip(leaves, addresses) {
                        ABISwiftTakeValue(unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self),
                                          address!, value.advanced(by: leaf.nativeOffset))
                    }
                } else {
                    ABISwiftDestroyValue(unsafeBitCast(nativeMetadata, to: UnsafeRawPointer.self), value)
                }
            })
        for (leaf, address) in zip(leaves, addresses) {
            let metadata = unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self)
            let destination = storage.address.advanced(by: leaf.nativeOffset)
            if consuming { ABISwiftTakeValue(metadata, destination, address!) }
            else { ABISwiftCopyValue(metadata, destination, address!) }
        }
        nativeConstants.initialize(at: storage.address)
        return storage
    }

    func initializeNativeConstants(at address: UnsafeMutableRawPointer) {
        nativeConstants.initialize(at: address)
    }

    func callbackDecoder(consuming: Bool) throws -> SwiftCallbackDecoder {
        let decoders = try leaves.map { try $0.callback(consuming) }
        return { vector, scope in
            let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            var next = 0
            defer {
                if consuming {
                    for index in next..<leaves.count {
                        let source = addresses[index]!
                        leaves[index].constants.initialize(at: source)
                        ABISwiftDestroyValue(unsafeBitCast(leaves[index].nativeType, to: UnsafeRawPointer.self), source)
                    }
                }
            }
            let storage = try makeHostStorage(codeLifetime: SwiftValueCodeLifetime.current) { leaf, output in
                let index = next
                // A consuming leaf decoder owns its input, including its failure path.
                next += 1
                try decoders[index](addresses[index]!, scope, output)
            }
            return takeHost(storage)
        }
    }

    func makeResultStorage() -> NativeValueStorage {
        let lifetime = SwiftValueCodeLifetime.connect([SwiftValueCodeLifetime([])] + leaves.compactMap(\.codeLifetime), retaining: [])
        return NativeValueStorage(size: nativeStride, alignment: nativeAlignment, codeLifetime: lifetime)
    }

    func decodeResult<Value>(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any?,
                             as type: Value.Type) throws -> Value {
        nativeConstants.initialize(at: storage.address)
        storage.relinquishValue()
        let lifetime = SwiftValueCodeLifetime.connect([storage.codeLifetime, SwiftValueCodeLifetime.current].compactMap { $0 }
            + leaves.compactMap(\.codeLifetime), retaining: []) ?? SwiftValueCodeLifetime([])
        let nativeFields = leaves.map { leaf in
            let value = NativeValueStorage(borrowing: storage.address.advanced(by: leaf.nativeOffset), owner: storage,
                retainingResourcesOf: storage, codeLifetime: lifetime)
            value.assumeInitialized {
                ABISwiftDestroyValue(unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self), $0)
            }
            return value
        }
        var index = 0
        let host = try makeHostStorage(codeLifetime: lifetime) { leaf, output in
            defer { index += 1 }
            try leaf.decodeResult(nativeFields[index], owner, codeOwner, output)
        }
        return host.take(as: Value.self)
    }

    func copyNativeValue<Value>(from source: UnsafeRawPointer, retainingCode owner: Any?,
                               codeLifetime: SwiftValueCodeLifetime?, scope: SwiftCallbackScope? = nil,
                               as type: Value.Type) throws -> Value {
        if scope == nil { try validateOwnedResult() }
        let host = try makeHostStorage(codeLifetime: codeLifetime) { leaf, output in
            try leaf.copyNative(source.advanced(by: leaf.nativeOffset), owner, codeLifetime, scope, output)
        }
        return host.take(as: Value.self)
    }

    func prepareResult(fromHost source: UnsafeRawPointer, retainingCode owner: Any? = nil) throws -> (UnsafeMutableRawPointer) -> Void {
        try validateOwnedResult()
        let values = try leaves.map { try $0.encodeResult(source.advanced(by: $0.hostOffset), owner) }
        SwiftValueCodeLifetime.connect(values.compactMap(\.codeLifetime) + leaves.compactMap(\.codeLifetime)
            + [SwiftValueCodeLifetime.current].compactMap { $0 }, retaining: [])
        return { destination in
            for (leaf, value) in zip(leaves, values) {
                ABISwiftTakeValue(unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self),
                                  destination.advanced(by: leaf.nativeOffset), value.address)
                value.relinquishValue()
            }
        }
    }

    func prepareNativeCopy(fromHost source: UnsafeRawPointer, retainingCode owner: Any? = nil) throws -> (UnsafeMutableRawPointer) -> Void {
        let values = try leaves.map { try $0.encodeCopy(source.advanced(by: $0.hostOffset), owner) }
        SwiftValueCodeLifetime.connect(values.compactMap { $0.0.codeLifetime } + leaves.compactMap(\.codeLifetime)
            + [SwiftValueCodeLifetime.current].compactMap { $0 }, retaining: [])
        return { destination in
            for (leaf, prepared) in zip(leaves, values) {
                let (value, copying) = prepared
                let metadata = unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self)
                if copying { ABISwiftCopyValue(metadata, destination.advanced(by: leaf.nativeOffset), value.address) }
                else {
                    ABISwiftTakeValue(metadata, destination.advanced(by: leaf.nativeOffset), value.address)
                    value.relinquishValue()
                }
            }
        }
    }

    func initializeNativeResult(logicalOffset: Int, size: Int, destination: UnsafeMutableRawPointer, source: UnsafeMutableRawPointer) {
        guard let projection = nativeProjections.first(where: { $0.offset == logicalOffset && $0.size == size }) else {
            preconditionFailure("A prepared callback result selects a complete native value projection.")
        }
        ABISwiftTakeValue(unsafeBitCast(projection.metadata, to: UnsafeRawPointer.self), destination, source)
    }

    private func makeHostStorage(codeLifetime: SwiftValueCodeLifetime?,
                                 initialize: (Leaf, UnsafeMutableRawPointer) throws -> Void) throws -> NativeValueStorage {
        let storage = NativeValueStorage(size: hostStride, alignment: hostAlignment, codeLifetime: codeLifetime)
        var initialized = 0
        do {
            for leaf in leaves {
                try initialize(leaf, storage.address.advanced(by: leaf.hostOffset))
                initialized += 1
            }
        } catch {
            for leaf in leaves.prefix(initialized).reversed() {
                leaf.destroyHost(storage.address.advanced(by: leaf.hostOffset))
            }
            throw error
        }
        storage.assumeInitialized {
            ABISwiftDestroyValue(unsafeBitCast(hostMetadata, to: UnsafeRawPointer.self), $0)
        }
        return storage
    }
}

private final class SwiftTupleArgumentOwner {
    private let values: [NativeValueStorage]
    init(_ values: [NativeValueStorage]) { self.values = values }
    func relinquish() { for value in values { value.relinquishValue() } }
}
