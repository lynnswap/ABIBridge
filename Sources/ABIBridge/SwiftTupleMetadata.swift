import ABIBridgeRuntime
import ABIBridgeCore
import ABIBridgeCore.Backend

typealias SwiftResultInitializer =
    @Sendable (Int, Int, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void

/// - Parameter generic: How the result passes, or nil for a result that its
///   type converts by itself.
func swiftResultInitializer(
    nativeMetadata: Any.Type,
    generic: SwiftGenericResult? = nil,
    tuple: SwiftTupleValuePlan? = nil
) -> SwiftResultInitializer {
    if let tuple {
        return {
            tuple.initializeNativeResult(logicalOffset: $0, size: $1, destination: $2, source: $3)
        }
    }
    if case .tuple(let tuple) = generic {
        return {
            tuple.initializeNativeResult(logicalOffset: $0, size: $1, destination: $2, source: $3)
        }
    }
    let closureResult: Bool
    switch generic {
    case .closure: closureResult = true
    case .host(let conversion):
        if case .closure = conversion.kind { closureResult = true } else { closureResult = false }
    case nil: closureResult = nativeMetadata is any SwiftClosureValue.Type
    default: closureResult = false
    }
    if closureResult {
        return { offset, size, destination, source in
            precondition(
                offset == 0 && size == MemoryLayout<ABISwiftClosureValue>.size,
                "A prepared closure result transfers one native function/context pair."
            )
            destination.copyMemory(from: source, byteCount: size)
        }
    }
    let metadata: Any.Type
    if case .runtimeValue(let plan) = generic {
        metadata = plan.valueType.metadata
    } else {
        metadata = nativeMetadata
    }
    func projections(_ type: Any.Type, at offset: Int) -> [SwiftTupleValuePlan.NativeProjection] {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        let value = SwiftTupleValuePlan.NativeProjection(
            offset: offset,
            size: layout.size,
            metadata: type
        )
        guard let tuple = SwiftTupleMetadata(type) else { return [value] }
        return [value] + tuple.elements.flatMap { projections($0.type, at: offset + $0.offset) }
    }
    let prepared = projections(metadata, at: 0)
    return { offset, size, destination, source in
        guard let projection = prepared.first(where: { $0.offset == offset && $0.size == size })
        else {
            preconditionFailure(
                "A prepared callback result selects a complete native value projection."
            )
        }
        ABISwiftTakeValue(
            unsafeBitCast(projection.metadata, to: UnsafeRawPointer.self),
            destination,
            source
        )
    }
}

/// Swift tuple metadata supplies the instantiated element offsets, which need not match a C struct's tail-padding rules.
typealias SwiftTupleMetadata = RuntimeTupleMetadata

extension RuntimeTupleMetadata {
    func layout<Value>(for type: Value.Type, fields: [CValueType]) throws -> CValueType {
        try withRuntimeErrors { CValueType(try layout(for: type, fields: fields.map(\.runtime))) }
    }
}

struct SwiftTupleValuePlan: Sendable {
    struct Field: Sendable {
        /// How the field's host value converts.
        let conversion: SwiftHostConversion
        /// How the field passes as an element of the tuple's arguments.
        let argument: SwiftGenericArgument
        var hostType: Any.Type { conversion.host }
        let nativeType: Any.Type
        let hostOffset: Int
        let nativeOffset: Int
        let nativeClosure: SwiftGenericClosurePlan?
        let tuple: SwiftTupleValuePlan?
        fileprivate let leaves: [Leaf]
        var type: CValueType { tuple?.type ?? leaves[0].type }

        /// - Parameter position: The element's position, which decides how
        ///   an undecided inferred host value is passed.
        init(
            hostType: Any.Type,
            nativeType: Any.Type,
            hostOffset: Int,
            nativeOffset: Int,
            argument: SwiftGenericArgument,
            tuple: SwiftTupleValuePlan? = nil,
            nativeClosure: SwiftGenericClosurePlan? = nil,
            position: SwiftValuePosition
        ) throws {
            try self.init(
                input: SwiftCallValues.Argument(
                    host: hostType,
                    plan: argument,
                    defaultConsuming: false,
                    asynchronous: false,
                    position: position
                ),
                argument: argument,
                nativeType: nativeType,
                hostOffset: hostOffset,
                nativeOffset: nativeOffset,
                tuple: tuple,
                nativeClosure: nativeClosure
            )
        }

        fileprivate init(
            input: SwiftCallValues.Argument,
            argument: SwiftGenericArgument,
            nativeType: Any.Type,
            hostOffset: Int,
            nativeOffset: Int,
            tuple: SwiftTupleValuePlan?,
            nativeClosure: SwiftGenericClosurePlan?
        ) throws {
            conversion = input.conversion
            self.argument = argument; self.nativeType = nativeType
            self.hostOffset = hostOffset; self.nativeOffset = nativeOffset
            self.tuple = tuple; self.nativeClosure = nativeClosure
            // A field converts in both directions, so a closure prepares the
            // codec that wraps native functions for the host.
            if case .closure(let closure) = conversion.kind { _ = try closure.codec() }
            if let tuple {
                leaves = tuple.leaves.map { $0.rebased(host: hostOffset, native: nativeOffset) }
            } else {
                leaves = [
                    Leaf(
                        input: input,
                        nativeType: nativeType,
                        hostOffset: hostOffset,
                        nativeOffset: nativeOffset,
                        nativeClosure: nativeClosure
                    )
                ]
            }
        }
    }

    fileprivate typealias HostDecoder =
        @Sendable (UnsafeMutableRawPointer, SwiftCallbackScope, UnsafeMutableRawPointer) throws ->
        Void

    /// A field that is not itself a tuple, at its offsets in the outermost
    /// host and native tuples.
    struct Leaf: Sendable {
        /// How the leaf's host value converts.
        let conversion: SwiftHostConversion
        var hostType: Any.Type { conversion.host }
        let nativeType: Any.Type
        private(set) var hostOffset: Int
        private(set) var nativeOffset: Int
        /// The storage with which the leaf passes as an argument.
        let type: CValueType
        let nativeClosure: SwiftGenericClosurePlan?
        let nativeSize: Int
        /// Whether a runtime value leaf passes to an async function.
        private let asynchronous: Bool
        fileprivate let constants: SwiftValueConstants
        fileprivate let codeLifetime: SwiftValueCodeLifetime?

        fileprivate init(
            input: SwiftCallValues.Argument,
            nativeType: Any.Type,
            hostOffset: Int,
            nativeOffset: Int,
            nativeClosure: SwiftGenericClosurePlan?
        ) {
            conversion = input.conversion
            self.nativeType = nativeType
            self.hostOffset = hostOffset; self.nativeOffset = nativeOffset
            type = input.type
            asynchronous = input.asynchronous
            self.nativeClosure = nativeClosure
            nativeSize =
                ABISwiftGetValueLayout(unsafeBitCast(nativeType, to: UnsafeRawPointer.self)).size
            constants = SwiftValueConstants(
                ABISwiftValueIsIndirect(input.type.handle) ? Void.self : nativeType
            )
            codeLifetime = conversion.runtimeValue?.valueType.codeLifetime
        }

        fileprivate func encodeArgument(
            _ address: UnsafeRawPointer,
            consuming: Bool,
            asynchronous: Bool,
            retainingCode owner: Any?
        ) throws -> NativeValueStorage {
            try conversion.encode(
                address,
                convention: consuming ? .consuming : .borrowing,
                asynchronous: asynchronous,
                retainingCode: owner
            )
        }

        fileprivate func encodeResult(
            _ address: UnsafeRawPointer,
            retainingCode owner: Any?
        ) throws -> NativeValueStorage {
            try conversion.encodeResult(address, retainingCode: owner)
        }

        fileprivate func encodeCopy(
            _ address: UnsafeRawPointer,
            retainingCode owner: Any?
        ) throws -> (storage: NativeValueStorage, copying: Bool) {
            try conversion.encodeCopy(address, retainingCode: owner)
        }

        fileprivate func decodeResult(
            _ storage: NativeValueStorage,
            retaining owner: Any?,
            retainingCode codeOwner: Any?,
            into output: UnsafeMutableRawPointer
        ) throws {
            try conversion.decode(storage, retaining: owner, retainingCode: codeOwner, into: output)
        }

        /// Copies the native value at `source` into a host value at `output`.
        fileprivate func copyNative(
            _ source: UnsafeRawPointer,
            retainingCode codeOwner: Any?,
            codeLifetime: SwiftValueCodeLifetime?,
            scope: SwiftCallbackScope?,
            into output: UnsafeMutableRawPointer
        ) throws {
            let runtime = conversion.runtimeValue
            if let runtime {
                guard SwiftCopyability.accepts(runtime.valueType.metadata) else {
                    throw NativeSwiftValueError.noncopyableType
                }
            }
            let lifetime = SwiftValueCodeLifetime.connect(
                [codeLifetime, self.codeLifetime, SwiftValueCodeLifetime.current].compactMap { $0 },
                retaining: []
            )
            let metadata = unsafeBitCast(nativeType, to: UnsafeRawPointer.self)
            let layout = ABISwiftGetValueLayout(metadata)
            let storage = NativeValueStorage(
                size: layout.stride,
                alignment: layout.alignment,
                codeLifetime: lifetime
            )
            ABISwiftCopyValue(metadata, storage.address, source)
            storage.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
            if hostType == NativeSwiftBorrowedValue.self, let runtime {
                guard let scope else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A scoped runtime tuple field requires its callback borrow scope."
                    )
                }
                let retained = runtime.valueType.retainingCode(
                    lifetime ?? runtime.valueType.codeLifetime
                )
                output.initializeMemory(
                    as: NativeSwiftBorrowedValue.self,
                    repeating: NativeSwiftBorrowedValue(
                        type: retained,
                        borrow: scope.borrow(storage.address, retaining: storage)
                    ),
                    count: 1
                )
            } else {
                try decodeResult(storage, retaining: nil, retainingCode: codeOwner, into: output)
            }
        }

        fileprivate func callback(consuming: Bool) throws -> HostDecoder {
            let decoder = try conversion.callbackDecoder(
                convention: consuming ? .consuming : .borrowing,
                asynchronous: asynchronous,
                failure: (any Error).self
            )
            let initialize = conversion.initializeHost
            return { source, scope, output in
                initialize(try decoder(source, scope), output)
            }
        }

        fileprivate func validateOwnedResult() throws { try conversion.validateOwnedResult() }

        fileprivate func destroyHost(_ address: UnsafeMutableRawPointer) {
            conversion.destroyHost(at: address)
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
    let parameters: SwiftGenericParameters
    let argumentTypes: [CValueType]
    let nativeProjections: [NativeProjection]
    /// Whether a leaf's host value differs from its native value.
    var needsConversion: Bool {
        leaves.contains { leaf in
            switch leaf.conversion.kind {
            case .runtimeValue, .closure, .adapter: true
            default: leaf.conversion.runtimeValue != nil || leaf.conversion.closure != nil
            }
        }
    }
    /// Whether a leaf passes its value through an adapter's representation.
    var hasAdapters: Bool {
        leaves.contains { if case .adapter = $0.conversion.kind { true } else { false } }
    }
    var hasNestedClosures: Bool {
        leaves.contains { leaf in
            if leaf.conversion.closure != nil || leaf.nativeClosure != nil { return true }
            if case .closure = leaf.conversion.kind { return true }
            return false
        }
    }
    private let hostStride: Int
    private let hostAlignment: Int
    private let nativeStride: Int
    private let nativeAlignment: Int
    private let nativeConstants: SwiftValueConstants
    private let takeHost: @Sendable (NativeValueStorage) -> Any

    init(
        hostMetadata: Any.Type,
        nativeMetadata: Any.Type,
        type: CValueType,
        fields: [Field],
        groups: [SwiftGenericParameters.Group]? = nil
    ) throws {
        self.hostMetadata = hostMetadata; self.nativeMetadata = nativeMetadata
        self.type = type; self.fields = fields
        leaves = fields.flatMap(\.leaves)
        let parameters = SwiftGenericParameters(
            actual: fields.map(\.hostType),
            arguments: fields.map(\.argument),
            groups: groups
        )
        self.parameters = parameters
        argumentTypes = parameters.types(from: fields.map(\.type))
        let host = ABISwiftGetValueLayout(unsafeBitCast(hostMetadata, to: UnsafeRawPointer.self))
        hostStride = host.stride; hostAlignment = host.alignment
        let native = ABISwiftGetValueLayout(
            unsafeBitCast(nativeMetadata, to: UnsafeRawPointer.self)
        )
        nativeStride = native.stride; nativeAlignment = native.alignment
        nativeConstants = SwiftValueConstants(nativeMetadata)
        nativeProjections =
            [.init(offset: 0, size: native.size, metadata: nativeMetadata)]
            + fields.flatMap { field in
                if let tuple = field.tuple {
                    return tuple.nativeProjections.map {
                        NativeProjection(
                            offset: field.nativeOffset + $0.offset,
                            size: $0.size,
                            metadata: $0.metadata
                        )
                    }
                }
                let layout = ABISwiftGetValueLayout(
                    unsafeBitCast(field.nativeType, to: UnsafeRawPointer.self)
                )
                return [
                    NativeProjection(
                        offset: field.nativeOffset,
                        size: layout.size,
                        metadata: field.nativeType
                    )
                ]
            }
        func prepare<Host>(_ type: Host.Type) -> @Sendable (NativeValueStorage) -> Any {
            { $0.take(as: Host.self) }
        }
        takeHost = _openExistential(hostMetadata, do: prepare)
    }

    // A whole tuple passed by address stores its functions at maximal
    // abstraction, including when AFD rather than a generic parameter makes it indirect.
    func usingStorageConvention(binding: SwiftGenericBinding) throws -> Self {
        guard hasNestedClosures else { return self }
        let fields = try fields.map { field in
            let nested = try field.tuple?.usingStorageConvention(binding: binding)
            let argument: SwiftGenericArgument
            let closure: SwiftGenericClosurePlan?
            if let host = field.hostType as? any SwiftClosureValue.Type {
                let plan = try binding.storedClosurePlan(metadata: field.nativeType, as: host.swiftFunctionType)
                argument = .closure(plan)
                closure = plan
            } else if let nested {
                argument = .tuple(nested)
                closure = nil
            } else {
                argument = field.argument
                closure = try field.nativeClosure.map { _ in
                    try SwiftGenericClosurePlan.nativeValue(swiftStoredFunction(field.nativeType)!)
                }
            }
            return try Field(hostType: field.hostType, nativeType: field.nativeType,
                hostOffset: field.hostOffset, nativeOffset: field.nativeOffset,
                argument: argument, tuple: nested, nativeClosure: closure, position: .nested)
        }
        return try Self(hostMetadata: hostMetadata, nativeMetadata: nativeMetadata, type: type,
                        fields: fields, groups: parameters.groups)
    }

    func validateOwnedResult() throws {
        for leaf in leaves { try leaf.validateOwnedResult() }
    }

    // Argument storage is a vector of independently owned/borrowed leaf addresses,
    // not a contiguous native tuple. Formal packs group these addresses separately.
    func encodeArgument(
        fromHost source: UnsafeRawPointer,
        consuming: Bool,
        asynchronous: Bool,
        retainingCode owner: Any? = nil
    ) throws -> NativeValueStorage {
        let values = try leaves.map {
            try $0.encodeArgument(
                source.advanced(by: $0.hostOffset),
                consuming: consuming,
                asynchronous: asynchronous,
                retainingCode: owner
            )
        }
        let lifetime = SwiftValueCodeLifetime.connect(
            values.compactMap(\.codeLifetime)
                + [SwiftValueCodeLifetime.current].compactMap { $0 },
            retaining: []
        )
        let owner = SwiftTupleArgumentOwner(values)
        let storage = NativeValueStorage(
            size: leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
            alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment,
            owner: owner,
            codeLifetime: lifetime,
            didRelinquish: consuming ? { owner.relinquish() } : nil
        )
        if consuming {
            storage.destroyTransferredCopy = { [leaves] in
                for (leaf, value) in zip(leaves, values) {
                    leaf.constants.initialize(at: value.address)
                    ABISwiftDestroyValue(
                        unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self),
                        value.address
                    )
                    value.relinquishValue()
                }
            }
        }
        for (index, value) in values.enumerated() {
            storage.address.storeBytes(
                of: Optional(value.address),
                toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                as: UnsafeMutableRawPointer?.self
            )
        }
        return storage
    }

    func argumentAddresses(_ storage: NativeValueStorage) -> [UnsafeMutableRawPointer?] {
        Array(
            UnsafeBufferPointer(
                start: storage.address.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                count: leaves.count
            )
        )
    }

    func nativeArgumentAddresses(_ native: UnsafeMutableRawPointer) -> [UnsafeMutableRawPointer?] {
        leaves.map { native.advanced(by: $0.nativeOffset) }
    }

    func encodeArguments(
        from vector: UnsafeMutableRawPointer,
        retaining owner: NativeValueStorage? = nil,
        consuming: Bool = false
    ) -> SwiftGenericParameters.Encoded {
        let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        var offset = 0
        let logical = fields.map { field -> UnsafeMutableRawPointer? in
            defer { offset += field.leaves.count }
            if SwiftGenericParameters.expandedTuple(field.argument) != nil {
                return UnsafeMutableRawPointer(addresses.advanced(by: offset))
            }
            return addresses[offset]
        }
        return parameters.encode(
            logical,
            retaining: owner.map { Array(repeating: $0, count: fields.count) } ?? [],
            consuming: consuming
        )
    }

    func unpackArguments(
        _ native: UnsafePointer<UnsafeMutableRawPointer?>?
    ) -> SwiftGenericParameters.Encoded {
        let unpacked = parameters.unpack(native)
        let addresses = zip(fields, unpacked.addresses).flatMap {
            field,
            address -> [UnsafeMutableRawPointer?] in
            if SwiftGenericParameters.expandedTuple(field.argument) != nil {
                return Array(
                    UnsafeBufferPointer(
                        start: address!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                        count: field.leaves.count
                    )
                )
            }
            return [address]
        }
        return .init(addresses: addresses, storage: unpacked.storage, consumed: unpacked.consumed)
    }

    // A formal pack stores each tuple element contiguously. A consuming element
    // temporarily moves its leaves and restores them unless native invocation commits.
    func materializeArgument(
        from vector: UnsafeMutableRawPointer,
        consuming: Bool,
        retaining owner: AnyObject? = nil
    ) -> NativeValueStorage {
        let addresses = Array(
            UnsafeBufferPointer(
                start: vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                count: leaves.count
            )
        )
        let lifetime = SwiftValueCodeLifetime.connect(
            [SwiftValueCodeLifetime.current].compactMap { $0 }
                + leaves.compactMap(\.codeLifetime),
            retaining: []
        )
        let storage = NativeValueStorage(
            size: nativeStride,
            alignment: nativeAlignment,
            owner: owner,
            codeLifetime: lifetime,
            destroyingWith: { value in
                if consuming {
                    for (leaf, address) in zip(leaves, addresses) {
                        ABISwiftTakeValue(
                            unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self),
                            address!,
                            value.advanced(by: leaf.nativeOffset)
                        )
                    }
                } else {
                    ABISwiftDestroyValue(
                        unsafeBitCast(nativeMetadata, to: UnsafeRawPointer.self),
                        value
                    )
                }
            }
        )
        for (leaf, address) in zip(leaves, addresses) {
            let metadata = unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self)
            let destination = storage.address.advanced(by: leaf.nativeOffset)
            if consuming {
                ABISwiftTakeValue(metadata, destination, address!)
            } else {
                ABISwiftCopyValue(metadata, destination, address!)
            }
        }
        nativeConstants.initialize(at: storage.address)
        return storage
    }

    func initializeNativeConstants(at address: UnsafeMutableRawPointer) {
        nativeConstants.initialize(at: address)
    }

    func callbackDecoder(consuming: Bool) throws -> SwiftCallbackDecoder {
        let decoders = try leaves.map { try $0.callback(consuming: consuming) }
        return { vector, scope in
            let addresses = vector.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            var next = 0
            defer {
                if consuming {
                    for index in next..<leaves.count {
                        let source = addresses[index]!
                        leaves[index].constants.initialize(at: source)
                        ABISwiftDestroyValue(
                            unsafeBitCast(leaves[index].nativeType, to: UnsafeRawPointer.self),
                            source
                        )
                    }
                }
            }
            let storage = try makeHostStorage(codeLifetime: SwiftValueCodeLifetime.current) {
                leaf,
                output in
                let index = next
                // A consuming leaf decoder owns its input, including its failure path.
                next += 1
                try decoders[index](addresses[index]!, scope, output)
            }
            return takeHost(storage)
        }
    }

    func makeResultStorage() -> NativeValueStorage {
        let lifetime = SwiftValueCodeLifetime.connect(
            [SwiftValueCodeLifetime([])] + leaves.compactMap(\.codeLifetime),
            retaining: []
        )
        return NativeValueStorage(
            size: nativeStride,
            alignment: nativeAlignment,
            codeLifetime: lifetime
        )
    }

    func decodeResult<Value>(
        _ storage: NativeValueStorage,
        retaining owner: Any?,
        retainingCode codeOwner: Any?,
        as type: Value.Type
    ) throws -> Value {
        nativeConstants.initialize(at: storage.address)
        storage.relinquishValue()
        let lifetime =
            SwiftValueCodeLifetime.connect(
                [storage.codeLifetime, SwiftValueCodeLifetime.current].compactMap { $0 }
                    + leaves.compactMap(\.codeLifetime),
                retaining: []
            ) ?? SwiftValueCodeLifetime([])
        let nativeFields = leaves.map { leaf in
            let value = NativeValueStorage(
                borrowing: storage.address.advanced(by: leaf.nativeOffset),
                owner: storage,
                retainingResourcesOf: storage,
                codeLifetime: lifetime
            )
            value.assumeInitialized {
                ABISwiftDestroyValue(unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self), $0)
            }
            return value
        }
        var index = 0
        let host = try makeHostStorage(codeLifetime: lifetime) { leaf, output in
            defer { index += 1 }
            try leaf.decodeResult(
                nativeFields[index],
                retaining: owner,
                retainingCode: codeOwner,
                into: output
            )
        }
        return host.take(as: Value.self)
    }

    func copyNativeValue<Value>(
        from source: UnsafeRawPointer,
        retainingCode owner: Any?,
        codeLifetime: SwiftValueCodeLifetime?,
        scope: SwiftCallbackScope? = nil,
        as type: Value.Type
    ) throws -> Value {
        if scope == nil { try validateOwnedResult() }
        let host = try makeHostStorage(codeLifetime: codeLifetime) { leaf, output in
            try leaf.copyNative(
                source.advanced(by: leaf.nativeOffset),
                retainingCode: owner,
                codeLifetime: codeLifetime,
                scope: scope,
                into: output
            )
        }
        return host.take(as: Value.self)
    }

    func prepareResult(
        fromHost source: UnsafeRawPointer,
        retainingCode owner: Any? = nil
    ) throws -> (UnsafeMutableRawPointer) -> Void {
        try validateOwnedResult()
        let values = try leaves.map {
            try $0.encodeResult(source.advanced(by: $0.hostOffset), retainingCode: owner)
        }
        SwiftValueCodeLifetime.connect(
            values.compactMap(\.codeLifetime) + leaves.compactMap(\.codeLifetime)
                + [SwiftValueCodeLifetime.current].compactMap { $0 },
            retaining: []
        )
        return { destination in
            for (leaf, value) in zip(leaves, values) {
                ABISwiftTakeValue(
                    unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self),
                    destination.advanced(by: leaf.nativeOffset),
                    value.address
                )
                value.relinquishValue()
            }
        }
    }

    func prepareNativeCopy(
        fromHost source: UnsafeRawPointer,
        retainingCode owner: Any? = nil
    ) throws -> (UnsafeMutableRawPointer) -> Void {
        let values = try leaves.map {
            try $0.encodeCopy(source.advanced(by: $0.hostOffset), retainingCode: owner)
        }
        SwiftValueCodeLifetime.connect(
            values.compactMap { $0.0.codeLifetime } + leaves.compactMap(\.codeLifetime)
                + [SwiftValueCodeLifetime.current].compactMap { $0 },
            retaining: []
        )
        return { destination in
            for (leaf, prepared) in zip(leaves, values) {
                let (value, copying) = prepared
                let metadata = unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self)
                if copying {
                    ABISwiftCopyValue(
                        metadata,
                        destination.advanced(by: leaf.nativeOffset),
                        value.address
                    )
                } else {
                    ABISwiftTakeValue(
                        metadata,
                        destination.advanced(by: leaf.nativeOffset),
                        value.address
                    )
                    value.relinquishValue()
                }
            }
        }
    }

    func initializeNativeResult(
        logicalOffset: Int,
        size: Int,
        destination: UnsafeMutableRawPointer,
        source: UnsafeMutableRawPointer
    ) {
        guard
            let projection = nativeProjections.first(where: {
                $0.offset == logicalOffset && $0.size == size
            })
        else {
            preconditionFailure(
                "A prepared callback result selects a complete native value projection."
            )
        }
        ABISwiftTakeValue(
            unsafeBitCast(projection.metadata, to: UnsafeRawPointer.self),
            destination,
            source
        )
    }

    private func makeHostStorage(
        codeLifetime: SwiftValueCodeLifetime?,
        initialize: (Leaf, UnsafeMutableRawPointer) throws -> Void
    ) throws -> NativeValueStorage {
        let storage = NativeValueStorage(
            size: hostStride,
            alignment: hostAlignment,
            codeLifetime: codeLifetime
        )
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

extension SwiftTupleValuePlan {
    /// The plan of a closed host tuple whose elements convert as their own
    /// host types do, or nil when `host` is not a tuple.
    ///
    /// An element's conversion gives its native type: a closure's native
    /// function, an adapter's representation, a nested tuple's native tuple,
    /// or the element's own type. The native tuple of those types places the
    /// elements.
    ///
    /// - Parameters:
    ///   - explicitLayout: The `valueABIs` layout of an element's host type,
    ///     if any.
    ///   - position: The tuple's own position. Elements of a parameter are
    ///     whole parameters; elements of a result are nested.
    init?(
        host: Any.Type,
        explicitLayout: (Any.Type) throws -> CValueType? = { _ in nil },
        position: SwiftValuePosition
    ) throws {
        guard let tuple = SwiftTupleMetadata(host) else { return nil }
        var inputs: [(SwiftCallValues.Argument, SwiftGenericArgument, SwiftTupleValuePlan?)] = []
        for element in tuple.elements {
            let nested = try Self(
                host: element.type,
                explicitLayout: explicitLayout,
                position: position.tupleElement
            )
            let argument: SwiftGenericArgument
            if let nested {
                argument = .tuple(nested)
            } else if let closure = element.type as? any SwiftClosureValue.Type {
                argument = .closure(try SwiftGenericClosurePlan.concrete(closure.swiftFunctionType))
            } else if let explicit = try explicitLayout(element.type) {
                argument = .value(explicit, consuming: false)
            } else {
                argument = .host(
                    try SwiftHostConversion(host: element.type, position: position.tupleElement)
                )
            }
            let input = try SwiftCallValues.Argument(
                host: element.type,
                plan: argument,
                defaultConsuming: false,
                asynchronous: false,
                position: position.tupleElement
            )
            inputs.append((input, argument, nested))
        }
        let nativeTypes = try inputs.map { try $0.0.conversion.nativeType() }
        let native = try Self.tupleMetadata(
            nativeTypes,
            labels: tuple.labels,
            replacing: host,
            elements: tuple.elements
        )
        let nativeElements = SwiftTupleMetadata(native)!.elements
        let fields = try zip(inputs, zip(tuple.elements, nativeElements)).map {
            input,
            elements in
            try Field(
                input: input.0,
                argument: input.1,
                nativeType: elements.1.type,
                hostOffset: elements.0.offset,
                nativeOffset: elements.1.offset,
                tuple: input.2,
                nativeClosure: nil
            )
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(native, to: UnsafeRawPointer.self))
        try self.init(
            hostMetadata: host,
            nativeMetadata: native,
            type: CValueType(
                swiftTuple: fields.map(\.type),
                offsets: fields.map(\.nativeOffset),
                size: layout.size,
                alignment: layout.alignment
            ),
            fields: fields
        )
    }

    /// The tuple metadata of `elements` with `labels`, or `host` when its
    /// elements are those types.
    static func tupleMetadata(
        _ types: [Any.Type],
        labels: [String],
        replacing host: Any.Type,
        elements: [SwiftTupleMetadata.Element]
    ) throws -> Any.Type {
        if zip(types, elements).allSatisfy({ $0.0 == $0.1.type }) { return host }
        let pointers = types.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
        let value = pointers.withUnsafeBufferPointer { pointers in
            if labels.allSatisfy(\.isEmpty) {
                return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil)
            }
            return (labels.joined(separator: " ") + " ").withCString {
                ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
            }
        }
        guard let value else {
            throw ABIResolutionError.metadataUnavailable(
                "The tuple exceeds Swift's metadata element count."
            )
        }
        return unsafeBitCast(value, to: Any.Type.self)
    }
}
