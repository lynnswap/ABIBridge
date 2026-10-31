import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime

/// How the host represents a runtime value at one position.
struct SwiftRuntimeHandle {
    enum Projection {
        case none
        /// `NativeSwiftValue?` or `NativeSwiftBorrowedValue?` for a native Optional.
        case optional
        /// A host collection of handles for a native Array, Set, or Dictionary.
        case collection(SwiftHostCollection)
    }

    /// `NativeSwiftValue` or `NativeSwiftBorrowedValue`. A collection's
    /// elements are always owned.
    let type: Any.Type
    let projection: Projection

    /// The plan for the native value with this host representation.
    func apply(to plan: SwiftRuntimeValuePlan) throws -> SwiftRuntimeValuePlan {
        switch projection {
        case .none: plan
        case .optional: try plan.projectingOptional()
        case .collection(let host): try plan.projectingCollection(host)
        }
    }
}

/// What the host holds at one element, key, or value position of a collection.
enum SwiftHostElement {
    case handle
    case optionalHandle
    /// The native type itself.
    case value(Any.Type)

    init(_ type: Any.Type) {
        if type == NativeSwiftValue.self { self = .handle }
        else if type == NativeSwiftValue?.self { self = .optionalHandle }
        else { self = .value(type) }
    }

    var isHandle: Bool { if case .value = self { false } else { true } }
}

/// A host collection type that stands for a native collection because it
/// holds handles: `[E]` for an Array or Set, and `[K: V]` or
/// `[(key: K, value: V)]` for a Dictionary.
struct SwiftHostCollection: @unchecked Sendable {
    enum Shape {
        case array(element: Any.Type)
        case dictionary(key: Any.Type, value: Any.Type)
        /// An array of `(key:value:)` tuples, whose value field is at `valueOffset`.
        case pairs(tuple: Any.Type, key: Any.Type, value: Any.Type, valueOffset: Int)
    }

    let type: Any.Type
    let shape: Shape

    init?(_ type: Any.Type) {
        guard let collection = type as? any SwiftHostCollectionType.Type else { return nil }
        var shape = collection.hostCollectionShape
        if case .array(let element) = shape, let pair = Self.keyValuePair(element) {
            shape = .pairs(tuple: element, key: pair.key, value: pair.value, valueOffset: pair.valueOffset)
        }
        let positions: [Any.Type] = switch shape {
        case .array(let element): [element]
        case .dictionary(let key, let value), .pairs(_, let key, let value, _): [key, value]
        }
        guard positions.contains(where: { SwiftHostElement($0).isHandle }) else { return nil }
        self.type = type
        self.shape = shape
    }

    /// The fields of a `(key:value:)` tuple type.
    private static func keyValuePair(_ type: Any.Type) -> (key: Any.Type, value: Any.Type, valueOffset: Int)? {
        guard runtimeMetadataKind(type) == .tuple else { return nil }
        // TupleTypeMetadata: kind, element count, labels, then (type, offset) per element.
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.stride
        guard metadata.load(fromByteOffset: word, as: UInt.self) == 2,
              let labels = metadata.load(fromByteOffset: 2 * word, as: UnsafePointer<CChar>?.self),
              String(cString: labels) == "key value "
        else { return nil }
        func element(_ index: Int) -> (type: Any.Type, offset: Int) {
            let base = (3 + 2 * index) * word
            return (unsafeBitCast(metadata.load(fromByteOffset: base, as: UnsafeRawPointer.self), to: Any.Type.self),
                    metadata.load(fromByteOffset: base + word, as: Int.self))
        }
        return (element(0).type, element(1).type, element(1).offset)
    }
}

protocol SwiftHostCollectionType {
    static var hostCollectionShape: SwiftHostCollection.Shape { get }
}

extension Array: SwiftHostCollectionType {
    static var hostCollectionShape: SwiftHostCollection.Shape { .array(element: Element.self) }
}

extension Dictionary: SwiftHostCollectionType {
    static var hostCollectionShape: SwiftHostCollection.Shape { .dictionary(key: Key.self, value: Value.self) }
}

/// Converts between a native Array, Set, or Dictionary and the host
/// collection that stands for it. Each conversion copies the elements.
struct SwiftRuntimeCollectionPlan: @unchecked Sendable {
    enum Kind { case array, set, dictionary }

    /// One element, key, or value position.
    struct Position: @unchecked Sendable {
        let native: NativeSwiftType
        let host: SwiftHostElement
        /// The wrapped type when the host holds `NativeSwiftValue?`.
        let payload: NativeSwiftType?

        var metadata: UnsafeRawPointer { unsafeBitCast(native.metadata, to: UnsafeRawPointer.self) }
        var hostMetadata: UnsafeRawPointer {
            switch host {
            case .handle: unsafeBitCast(NativeSwiftValue.self, to: UnsafeRawPointer.self)
            case .optionalHandle: unsafeBitCast(NativeSwiftValue?.self, to: UnsafeRawPointer.self)
            case .value(let type): unsafeBitCast(type, to: UnsafeRawPointer.self)
            }
        }

        init(
            native: Any.Type,
            host type: Any.Type,
            collection: NativeSwiftType,
            retaining types: [NativeSwiftType]
        ) throws {
            self.native = try swiftRuntimeValueType(
                metadata: native,
                retaining: [collection] + types
            )
            host = SwiftHostElement(type)
            switch host {
            case .handle:
                payload = nil
            case .optionalHandle:
                guard runtimeMetadataKind(native) == .optional,
                      let wrapped = ABISwiftEnumCasePayloadMetadata(unsafeBitCast(native, to: UnsafeRawPointer.self), 0)
                else {
                    throw ABIResolutionError.signatureMismatch(
                        .init(expected: "An Optional native element for NativeSwiftValue?", found: [self.native.name])
                    )
                }
                payload = try swiftRuntimeValueType(metadata: unsafeBitCast(wrapped, to: Any.Type.self),
                    retaining: [self.native] + types
                )
            case .value(let type):
                guard type == native else {
                    throw ABIResolutionError.signatureMismatch(
                        .init(expected: self.native.name, found: [String(reflecting: type)])
                    )
                }
                payload = nil
            }
        }

        /// A native copy of the host value at `address`, checked against this position's type.
        func nativeCopy(ofHost address: UnsafeRawPointer) throws -> NativeValueStorage {
            let storage = makeStorage(for: native)
            switch host {
            case .value:
                ABISwiftCopyValue(metadata, storage.address, address)
            case .handle:
                let source = try access(address.load(as: NativeSwiftValue.self), as: native)
                ABISwiftCopyValue(metadata, storage.address, source.address)
                connect(storage, source)
            case .optionalHandle:
                guard let handle = address.load(as: NativeSwiftValue?.self), let payload else {
                    ABISwiftInitializeEmptyEnumCase(metadata, storage.address, 1)
                    break
                }
                let source = try access(handle, as: payload)
                let payloadMetadata = unsafeBitCast(payload.metadata, to: UnsafeRawPointer.self)
                let copy = makeStorage(for: payload)
                ABISwiftCopyValue(payloadMetadata, copy.address, source.address)
                ABISwiftInitializeEnumCase(metadata, storage.address, 0, payloadMetadata, false, copy.address)
                connect(storage, source)
            }
            return storage.adopt(metadata)
        }

        /// Initializes the host value at `address` from an owned native value,
        /// which it takes.
        func initializeHost(_ address: UnsafeMutableRawPointer, taking storage: NativeValueStorage,
                            lifetime: SwiftValueCodeLifetime?) {
            let type = lifetime.map { native.retainingCode($0) } ?? native
            switch host {
            case .value:
                ABISwiftTakeValue(metadata, address, storage.address)
                storage.relinquishValue()
            case .handle:
                address.initializeMemory(as: NativeSwiftValue.self, repeating: NativeSwiftValue(storage: storage, type: type), count: 1)
            case .optionalHandle:
                var projected: NativeSwiftValue?
                var tag: UInt32 = 0
                _ = ABISwiftGetEnumTag(metadata, storage.address, &tag)
                if tag == 0, let payload {
                    let payloadType = lifetime.map { payload.retainingCode($0) } ?? payload
                    let payloadMetadata = unsafeBitCast(payload.metadata, to: UnsafeRawPointer.self)
                    let value = makeStorage(for: payloadType)
                    ABISwiftTakeEnumPayload(metadata, storage.address, payloadMetadata, false, value.address)
                    storage.relinquishValue()
                    projected = NativeSwiftValue(storage: value.adopt(payloadMetadata), type: payloadType)
                }
                address.initializeMemory(as: NativeSwiftValue?.self, repeating: projected, count: 1)
            }
        }

        private func access(_ handle: NativeSwiftValue, as expected: NativeSwiftType) throws -> NativeValueStorage {
            guard SwiftRuntimeValuePlan.accepts(handle.type, as: expected, convention: .borrowing) else {
                throw ABIInvocationError.incompatibleValue(expected: expected.name, actual: handle.type.name)
            }
            return try handle.access(.borrowing)
        }

        /// The copy also needs the code its source value needs.
        private func connect(_ storage: NativeValueStorage, _ source: NativeValueStorage) {
            if let lifetime = storage.codeLifetime, let sourceLifetime = source.codeLifetime {
                _ = SwiftValueCodeLifetime.connect([lifetime, sourceLifetime], retaining: [])
            }
        }
    }

    let kind: Kind
    let host: SwiftHostCollection
    /// The element of an Array or Set, or the value of a Dictionary.
    let element: Position
    let key: Position?
    /// The native Set element's or Dictionary key's Hashable conformance.
    private let hashable: UnsafeRawPointer?
    /// The host Dictionary key's Hashable conformance.
    private let hostHashable: UnsafeRawPointer?

    init(
        native collection: NativeSwiftType,
        host: SwiftHostCollection,
        retaining types: [NativeSwiftType] = []
    ) throws {
        let metadata = unsafeBitCast(collection.metadata, to: UnsafeRawPointer.self)
        let descriptor = ABISwiftTypeDescriptor(metadata)
        let arguments = try SwiftGenericTypeMetadata(metadata: collection.metadata).arguments.compactMap {
            if case .type(let type, _) = $0.storage { type } else { nil }
        }
        func mismatch() -> ABIResolutionError {
            .signatureMismatch(.init(expected: "A native Array, Set, or Dictionary for \(String(reflecting: host.type))",
                                     found: [collection.name]))
        }
        switch (descriptor, host.shape) {
        case (Self.descriptor([Int].self), .array(let element)):
            kind = .array
            self.element = try Position(
                native: arguments[0],
                host: element,
                collection: collection,
                retaining: types
            )
            key = nil
        case (Self.descriptor(Set<Int>.self), .array(let element)):
            kind = .set
            self.element = try Position(
                native: arguments[0],
                host: element,
                collection: collection,
                retaining: types
            )
            key = nil
        case (Self.descriptor([Int: Int].self), .dictionary(let hostKey, let value)),
             (Self.descriptor([Int: Int].self), .pairs(_, let hostKey, let value, _)):
            kind = .dictionary
            key = try Position(
                native: arguments[0],
                host: hostKey,
                collection: collection,
                retaining: types
            )
            element = try Position(
                native: arguments[1],
                host: value,
                collection: collection,
                retaining: types
            )
        default:
            throw mismatch()
        }
        self.host = host
        let hashed = key ?? element
        if kind == .array {
            hashable = nil
        } else {
            guard let conformance = ABISwiftHashableConformance(hashed.metadata) else { throw mismatch() }
            hashable = conformance
        }
        if case .dictionary(let hostKey, _) = host.shape {
            hostHashable = ABISwiftHashableConformance(unsafeBitCast(hostKey, to: UnsafeRawPointer.self))
        } else {
            hostHashable = nil
        }
    }

    private static func descriptor(_ type: Any.Type) -> UnsafeRawPointer? {
        ABISwiftTypeDescriptor(unsafeBitCast(type, to: UnsafeRawPointer.self))
    }

    // MARK: Host to native

    /// Builds the native collection from the host collection. Element types
    /// are checked before the collection is created.
    func makeNative(_ value: Any, type: NativeSwiftType) throws -> NativeSwiftValue {
        let entries = try nativeEntries(of: value)
        let metadata = unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)
        var collection: UnsafeRawPointer?
        switch kind {
        case .array:
            var elements: UnsafeMutableRawPointer?
            collection = ABISwiftArrayCreate(element.metadata, entries.count, &elements)
            let stride = ABISwiftGetValueLayout(element.metadata).stride
            for (index, entry) in entries.enumerated() {
                ABISwiftTakeValue(element.metadata, elements! + index * stride, entry.value.address)
                entry.value.relinquishValue()
            }
        case .set:
            collection = ABISwiftSetCreate(entries.count, element.metadata, hashable)
            for entry in entries {
                _ = ABISwiftSetInsert(&collection, entry.value.address, element.metadata, hashable)
                entry.value.relinquishValue()
            }
        case .dictionary:
            collection = ABISwiftDictionaryCreate(entries.count, key!.metadata, element.metadata, hashable)
            // The dictionary copies each key; the entry keeps destroying its own.
            for entry in entries {
                ABISwiftDictionaryUpdate(&collection, entry.key!.address, entry.value.address,
                                         key!.metadata, element.metadata, hashable)
                entry.value.relinquishValue()
            }
        }
        let layout = ABISwiftGetValueLayout(metadata)
        let storage = NativeValueStorage(size: layout.stride, alignment: layout.alignment, owner: type,
                                         codeLifetime: SwiftValueCodeLifetime(type.codeImages))
        storage.address.storeBytes(of: collection, as: UnsafeRawPointer?.self)
        storage.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
        // The collection also needs the code its elements' values need.
        let lifetimes = entries.flatMap { [$0.key?.codeLifetime, $0.value.codeLifetime] }.compactMap { $0 }
        if let lifetime = storage.codeLifetime, !lifetimes.isEmpty {
            _ = SwiftValueCodeLifetime.connect([lifetime] + lifetimes, retaining: [])
        }
        return NativeSwiftValue(storage: storage, type: type)
    }

    /// Native copies of the host collection's elements, or keys and values.
    private func nativeEntries(of value: Any) throws -> [(key: NativeValueStorage?, value: NativeValueStorage)] {
        var entries: [(key: NativeValueStorage?, value: NativeValueStorage)] = []
        func read<Host>(_ host: Host) throws {
            try withUnsafeBytes(of: host) { bytes in
                let collection = bytes.load(as: UnsafeRawPointer.self)
                switch self.host.shape {
                case .array:
                    try forEachArrayElement(collection, metadata: element.hostMetadata) {
                        entries.append((nil, try element.nativeCopy(ofHost: $0)))
                    }
                case .pairs(let tuple, _, _, let valueOffset):
                    try forEachArrayElement(collection, metadata: unsafeBitCast(tuple, to: UnsafeRawPointer.self)) {
                        entries.append((try key!.nativeCopy(ofHost: $0), try element.nativeCopy(ofHost: $0 + valueOffset)))
                    }
                case .dictionary:
                    let visit = SwiftCollectionVisit { first, second in
                        defer {
                            ABISwiftDestroyValue(key!.hostMetadata, first)
                            ABISwiftDestroyValue(element.hostMetadata, second!)
                        }
                        entries.append((try key!.nativeCopy(ofHost: first), try element.nativeCopy(ofHost: second!)))
                    }
                    try visit.run {
                        ABISwiftDictionaryForEach(collection, key!.hostMetadata, element.hostMetadata, hostHashable, $0, $1)
                    }
                }
            }
        }
        try _openExistential(value, do: read)
        return entries
    }

    private func forEachArrayElement(_ array: UnsafeRawPointer, metadata: UnsafeRawPointer,
                                     _ body: (UnsafeRawPointer) throws -> Void) throws {
        let layout = ABISwiftGetValueLayout(metadata)
        let element = UnsafeMutableRawPointer.allocate(byteCount: max(layout.size, 1), alignment: layout.alignment)
        defer { element.deallocate() }
        for index in 0..<ABISwiftArrayCount(array, metadata) {
            ABISwiftArrayCopyElement(array, index, metadata, element)
            defer { ABISwiftDestroyValue(metadata, element) }
            try body(element)
        }
    }

    // MARK: Native to host

    /// The host collection for the native collection at `address`, with each
    /// element an independent copy that keeps `lifetime`.
    func hostValue(ofNative address: UnsafeRawPointer, lifetime: SwiftValueCodeLifetime?) -> Any {
        let collection = address.load(as: UnsafeRawPointer.self)
        var entries: [(key: NativeValueStorage?, value: NativeValueStorage)] = []
        switch kind {
        case .array:
            for index in 0..<ABISwiftArrayCount(collection, element.metadata) {
                let value = makeStorage(for: element.native)
                ABISwiftArrayCopyElement(collection, index, element.metadata, value.address)
                entries.append((nil, value.adopt(element.metadata)))
            }
        case .set:
            let visit = SwiftCollectionVisit { first, _ in entries.append((nil, element.taking(first))) }
            try! visit.run { ABISwiftSetForEach(collection, element.metadata, hashable, $0, $1) }
        case .dictionary:
            let visit = SwiftCollectionVisit { first, second in
                entries.append((key!.taking(first), element.taking(second!)))
            }
            try! visit.run {
                ABISwiftDictionaryForEach(collection, key!.metadata, element.metadata, hashable, $0, $1)
            }
        }
        var result: UnsafeRawPointer?
        switch host.shape {
        case .array:
            var elements: UnsafeMutableRawPointer?
            result = ABISwiftArrayCreate(element.hostMetadata, entries.count, &elements)
            let stride = ABISwiftGetValueLayout(element.hostMetadata).stride
            for (index, entry) in entries.enumerated() {
                element.initializeHost(elements! + index * stride, taking: entry.value, lifetime: lifetime)
            }
        case .pairs(let tuple, _, _, let valueOffset):
            let tupleMetadata = unsafeBitCast(tuple, to: UnsafeRawPointer.self)
            var elements: UnsafeMutableRawPointer?
            result = ABISwiftArrayCreate(tupleMetadata, entries.count, &elements)
            let stride = ABISwiftGetValueLayout(tupleMetadata).stride
            for (index, entry) in entries.enumerated() {
                let pair = elements! + index * stride
                key!.initializeHost(pair, taking: entry.key!, lifetime: lifetime)
                element.initializeHost(pair + valueOffset, taking: entry.value, lifetime: lifetime)
            }
        case .dictionary:
            result = ABISwiftDictionaryCreate(entries.count, key!.hostMetadata, element.hostMetadata, hostHashable)
            let keyBuffer = HostBuffer(key!.hostMetadata), valueBuffer = HostBuffer(element.hostMetadata)
            for entry in entries {
                key!.initializeHost(keyBuffer.address, taking: entry.key!, lifetime: lifetime)
                element.initializeHost(valueBuffer.address, taking: entry.value, lifetime: lifetime)
                ABISwiftDictionaryUpdate(&result, keyBuffer.address, valueBuffer.address,
                                         key!.hostMetadata, element.hostMetadata, hostHashable)
                ABISwiftDestroyValue(key!.hostMetadata, keyBuffer.address)
            }
        }
        func move<Host>(_: Host.Type) -> Any {
            withUnsafeMutablePointer(to: &result) {
                $0.withMemoryRebound(to: Host.self, capacity: 1) { $0.move() }
            }
        }
        return _openExistential(host.type, do: move)
    }
}

private extension SwiftRuntimeCollectionPlan.Position {
    /// Takes the owned native value at `address` into new storage.
    func taking(_ address: UnsafeMutableRawPointer) -> NativeValueStorage {
        let storage = makeStorage(for: native)
        ABISwiftTakeValue(metadata, storage.address, address)
        return storage.adopt(metadata)
    }
}

/// Uninitialized storage for one value of `type`.
private func makeStorage(for type: NativeSwiftType) -> NativeValueStorage {
    let layout = ABISwiftGetValueLayout(unsafeBitCast(type.metadata, to: UnsafeRawPointer.self))
    return NativeValueStorage(size: layout.stride, alignment: layout.alignment, owner: type,
                              codeLifetime: type.codeLifetime)
}

private extension NativeValueStorage {
    /// Marks the value the caller initialized as owned by this storage.
    func adopt(_ metadata: UnsafeRawPointer) -> NativeValueStorage {
        assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
        return self
    }
}

/// Uninitialized storage that a native call takes from.
private final class HostBuffer {
    let address: UnsafeMutableRawPointer
    init(_ metadata: UnsafeRawPointer) {
        let layout = ABISwiftGetValueLayout(metadata)
        address = .allocate(byteCount: max(layout.size, 1), alignment: layout.alignment)
    }
    deinit { address.deallocate() }
}

/// Passes a Swift closure to a C collection visitor. After the closure
/// throws, the remaining values are destroyed by the closure's `defer`s and
/// the error is rethrown when the visit ends.
private final class SwiftCollectionVisit {
    private let body: (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) throws -> Void
    private var error: Error?

    init(_ body: @escaping (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) throws -> Void) {
        self.body = body
    }

    func run(_ visit: (UnsafeMutableRawPointer, ABISwiftCollectionVisitor) -> Void) throws {
        withExtendedLifetime(self) {
            visit(Unmanaged.passUnretained(self).toOpaque()) { context, first, second in
                let visit = Unmanaged<SwiftCollectionVisit>.fromOpaque(context!).takeUnretainedValue()
                visit.receive(first!, second)
            }
        }
        if let error { throw error }
    }

    private func receive(_ first: UnsafeMutableRawPointer, _ second: UnsafeMutableRawPointer?) {
        do { try body(first, second) } catch { if self.error == nil { self.error = error } }
    }
}
