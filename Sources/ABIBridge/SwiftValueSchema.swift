import ABIBridgeCore
import ABIBridgeRuntime

/// The native storage of a Swift value at one position, and the kind of
/// value it holds.
///
/// A declaration position derives its schema from its formal type: generic
/// parameters and unbound fields are stored indirectly, `valueABIs` layouts
/// apply to closed nominal types, and other closed values use their own Swift
/// metadata, inferring the convention of structs and enums without one. A
/// host type that passes a value by itself has the schema of its own
/// representation.
struct SwiftValueSchema: Sendable {
    /// How a value is held, which decides how it is copied and destroyed and
    /// how pointer authentication hashes it.
    enum Kind: Sendable, Equatable {
        /// Bytes without Swift ownership: integers, floating-point values,
        /// `Bool`, pointers, C structs, and an adapter's representation.
        case scalar
        /// A class reference, or an Optional of one.
        case reference
        /// A struct or enum, including an Optional, whose components pass in
        /// registers unless there are too many of them.
        case loadable
        /// A value that passes by address whatever its size.
        case addressOnly
        /// An existential container. It keeps its formal identity even where
        /// its storage passes by address.
        case existential
        /// A thin or thick metatype, or an Optional of one.
        case metatype
        /// A Swift function's entry point and context, or an Optional of one.
        case function
        /// A tuple, with its elements at their native offsets.
        case tuple
    }

    /// The storage with which the value passes.
    let type: CValueType
    let kind: Kind
    /// The native type, whose value witnesses copy and destroy the value.
    /// Nil when the schema comes from the host representation of another
    /// type, such as an adapter or a closure.
    let metadata: Any.Type?

    init(type: CValueType, kind: Kind, metadata: Any.Type?) {
        self.type = type
        self.kind = kind
        self.metadata = metadata
    }

    /// A struct or enum stored as `type`: address-only when `type` is
    /// indirect Swift storage, and loadable otherwise.
    init(storage type: CValueType, metadata: Any.Type?) {
        let addressOnly = withExtendedLifetime(type) { ABISwiftValueIsAddressOnly(type.handle) }
        self.init(type: type, kind: addressOnly ? .addressOnly : .loadable, metadata: metadata)
    }

    /// A value of `metadata` that passes by address.
    static func indirect(_ metadata: Any.Type) throws -> Self {
        Self(type: try storage(of: metadata), kind: .addressOnly, metadata: metadata)
    }

    private static func reference(_ metadata: Any.Type?) throws -> Self {
        Self(type: try CValueType(scalar: ABIValuePointer), kind: .reference, metadata: metadata)
    }

    private static func function(_ metadata: Any.Type?) throws -> Self {
        let pointer = try CValueType(scalar: ABIValuePointer)
        return Self(
            type: try CValueType(fields: [pointer, pointer]),
            kind: .function,
            metadata: metadata
        )
    }

    /// This schema for a value whose native type is `metadata`.
    private func withNativeType(_ metadata: Any.Type) -> Self {
        Self(type: type, kind: kind, metadata: metadata)
    }

    // MARK: Declaration positions

    /// The schema of a value at a declaration position with the formal type
    /// `formal`, whose native type is `actual`.
    ///
    /// - Parameter position: Where the value occurs; it decides how a value
    ///   whose inferred convention is undecided is passed.
    init(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding,
        position: SwiftValuePosition
    ) throws {
        let canonical = try binding.canonicalType(of: formal)
        if canonical != formal {
            self = try Self(canonical, actual: actual, binding: binding, position: position)
            return
        }
        if binding.isArchetype(formal) {
            self = try binding.isClassBound(formal) ? .reference(actual) : .indirect(actual)
            return
        }
        if case .tuple(let fields, _) = formal {
            self = try .tuple(fields, actual: actual, binding: binding, position: position)
            return
        }
        if case .function = formal {
            self = try .function(actual)
            return
        }
        if let index = formal.opaqueIndex {
            guard let opaque = binding.opaqueResults[index] else {
                throw ABIResolutionError.metadataUnavailable(
                    "The opaque result ABI has not been resolved."
                )
            }
            self = Self(storage: opaque.type, metadata: opaque.valueType.metadata)
            return
        }
        if formal.nominalDeclaration != nil, !binding.dependsOnParameters(formal),
            formal.opaqueIndices.isEmpty,
            let explicit = try binding.explicitValueType(actual)
        {
            self = Self(storage: explicit, metadata: actual)
            return
        }
        if let wrapped = formal.optionalWrapped {
            self = try .optional(wrapped, actual: actual, binding: binding)
            return
        }
        func prepare<Value>(_ type: Value.Type) throws -> Self {
            if !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty {
                return try .host(Value.self, position: position).withNativeType(actual)
            }
            if try binding.isClassBound(formal) { return try .reference(actual) }
            switch formal {
            case .associated:
                return try .indirect(actual)
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if !arguments.isEmpty && actual is AnyClass {
                    return try .reference(actual)
                }
                if ["Swift.Array", "Swift.Dictionary", "Swift.Set"].contains(name) {
                    return Self(
                        type: try CValueType(scalar: ABIValuePointer),
                        kind: .loadable,
                        metadata: actual
                    )
                }
                let isArchetype: Bool
                if case .named = formal {
                    isArchetype =
                        arguments.isEmpty
                        && binding.arguments[String(name.prefix { $0 != "." })] != nil
                } else {
                    isArchetype = false
                }
                if try isArchetype
                    || Self.isIndirect(
                        actual,
                        arguments: arguments,
                        binding: binding
                    )
                {
                    return try .indirect(actual)
                }
            case .reference(_, let arguments):
                if actual is AnyClass { return try .reference(actual) }
                if try Self.isIndirect(
                    actual,
                    arguments: arguments,
                    binding: binding
                ) {
                    return try .indirect(actual)
                }
            case .nested:
                if actual is AnyClass { return try .reference(actual) }
                if try Self.isIndirect(
                    actual,
                    arguments: formal.nominalDeclaration!.arguments,
                    binding: binding
                ) {
                    return try .indirect(actual)
                }
            case .metatype(let instance):
                guard let metatype = SwiftMetatypeMetadata(actual) else {
                    throw ABIResolutionError.signatureMismatch(
                        .init(expected: formal.spelling, found: [String(reflecting: actual)])
                    )
                }
                return Self(
                    type: try metatype.valueType(
                        for: Value.self,
                        thin: !metatype.isExistential
                            && Self.singletonMetatype(instance, binding: binding)
                    ),
                    kind: .metatype,
                    metadata: actual
                )
            case .existentialMetatype, .constrainedExistential:
                return try .host(Value.self, position: position).withNativeType(actual)
            case .tuple(let fields, _):
                return try .tuple(fields, actual: actual, binding: binding, position: position)
            case .opaqueResult:
                throw ABIResolutionError.metadataUnavailable(
                    "The opaque result ABI has not been resolved."
                )
            case .pack, .packValue:
                preconditionFailure("A pack expands within the containing parameter list or tuple.")
            case .function:
                return try .function(actual)
            case .foreignFunction(let convention, _, _):
                // A block is an object; a C function pointer is an address.
                return Self(
                    type: try CValueType(scalar: ABIValuePointer),
                    kind: convention == .block ? .reference : .scalar,
                    metadata: actual
                )
            case .objectiveCClass:
                return try .reference(actual)
            case .borrowing, .consuming, .inoutValue:
                throw ABIResolutionError.unsupportedDeclaration(
                    "Generic ownership arguments require their underlying value convention."
                )
            }
            if formal.nominalDeclaration != nil, formal.opaqueIndices.isEmpty,
                let explicit = try binding.explicitValueType(actual)
            {
                return Self(storage: explicit, metadata: actual)
            }
            return try .host(Value.self, position: position).withNativeType(actual)
        }
        self = try _openExistential(actual, do: prepare)
    }

    /// The schema of an Optional at a declaration position, from its wrapped
    /// formal type and the Optional's native type.
    private static func optional(
        _ wrapped: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding
    ) throws -> Self {
        let wrappedType = try (actual as? any NativeOptionalValue.Type)?.wrappedType
            ?? binding.types(wrapped)[0]
        // A generic or opaque payload is a reference only when its
        // constraints say so, whatever type it is bound to.
        let isFormallyAbstract =
            binding.dependsOnParameters(wrapped) || !wrapped.opaqueIndices.isEmpty
        if try isFormallyAbstract
            ? binding.isClassBound(wrapped) : wrappedType is AnyClass || wrappedType == AnyObject.self
        {
            return try .reference(actual)
        }
        if case .metatype(let instance) = try binding.canonicalType(of: wrapped),
            let metatype = SwiftMetatypeMetadata(wrappedType)
        {
            if try !metatype.isExistential && singletonMetatype(instance, binding: binding) {
                return Self(
                    type: CValueType(swiftOptionalSingleton: ()),
                    kind: .metatype,
                    metadata: actual
                )
            }
            func thick<Value>(_ type: Value.Type) throws -> CValueType {
                try metatype.valueType(for: type, thin: false)
            }
            return Self(
                type: try _openExistential(actual, do: thick),
                kind: .metatype,
                metadata: actual
            )
        }
        let payload = try Self(wrapped, actual: wrappedType, binding: binding, position: .nested)
        return Self(
            storage: try optionalStorage(
                of: actual,
                wrapped: payload.type,
                wrappedType: wrappedType
            ),
            metadata: actual
        )
    }

    /// The native tuple schema of `fields`, with packs as address vectors.
    static func tuple(
        _ fields: [SwiftFormalType],
        actual: Any.Type,
        binding: SwiftGenericBinding,
        position: SwiftValuePosition
    ) throws -> Self {
        let elements = try SwiftGenericCallPlan.tupleElements(fields, actual: actual, binding: binding)
        let native = ABISwiftGetValueLayout(unsafeBitCast(actual, to: UnsafeRawPointer.self))
        var types: [CValueType] = [], offsets: [Int] = []
        var index = 0
        for field in fields {
            let offset = index < elements.count ? elements[index].offset : native.size
            offsets.append(offset)
            if case .pack(let pattern, let shape) = field {
                let count = try binding.packCount(in: shape ?? pattern)
                let selected = elements[index..<(index + count)]
                let layouts = try selected.map { try storage(of: $0.type) }
                let positions = selected.map { $0.offset - offset }
                let size = zip(positions, layouts).map { $0.0 + $0.1.size }.max() ?? 0
                types.append(
                    try CValueType(
                        swiftTuple: layouts,
                        offsets: positions,
                        size: size,
                        alignment: layouts.map(\.alignment).max() ?? 1,
                        isPack: true
                    )
                )
                index += count
            } else {
                types.append(
                    try Self(
                        field,
                        actual: elements[index].type,
                        binding: binding,
                        position: position.tupleElement
                    ).type
                )
                index += 1
            }
        }
        return Self(
            type: try CValueType(
                swiftTuple: types,
                offsets: offsets,
                size: native.size,
                alignment: native.alignment
            ),
            kind: .tuple,
            metadata: actual
        )
    }

    private static func singletonMetatype(
        _ type: SwiftFormalType,
        binding: SwiftGenericBinding
    ) throws -> Bool {
        let type = try binding.canonicalType(of: type)
        if case .metatype(let instance) = type {
            return try singletonMetatype(instance, binding: binding)
        }
        if binding.isArchetype(type) { return false }
        return try !(binding.types(type)[0] is AnyClass)
    }

    // MARK: Host types

    /// The schema of a value that the host type `type` passes by itself at
    /// `position`, from the type's own representation.
    init(host type: Any.Type, position: SwiftValuePosition) throws {
        func prepare<Value>(_: Value.Type) throws -> Self {
            try .host(Value.self, position: position)
        }
        self = try _openExistential(type, do: prepare)
    }

    /// The schema of a value that the host type `Value` passes by itself at
    /// `position`.
    ///
    /// A type with its own Swift ABI keeps it, even in an Optional. A closure
    /// stores a function's entry point and context, a tuple stores its
    /// elements at their native offsets, and an adapter or a C value stores
    /// its C representation. Other values store their Swift storage, which a
    /// struct or enum without a built-in representation infers from its
    /// metadata.
    static func host<Value>(_: Value.Type, position: SwiftValuePosition) throws -> Self {
        guard !(Value.self is any SwiftConventionArgument.Type) else {
            throw ABIResolutionError.unsupportedDeclaration("Swift argument convention markers require the invocation argument path; results and managed callbacks cannot use them.")
        }
        if Value.self is any SwiftClosureValue.Type {
            return try .function(nil)
        }
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        // These wrappers are host classes; their reference is not the native value.
        guard Value.self == base
            || (base != NativeSwiftValue.self && base != NativeSwiftBorrowedValue.self)
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An Optional runtime value is unsupported; pass a NativeSwiftValue of the Optional type."
            )
        }
        let isObject = base is AnyClass || base == AnyObject.self
        let isAdapter = base is any ABIBridgeValue.Type && !(base is any ABIBridgeSwiftValue.Type)
        let managed = Value.self as? any ABIBridgeSwiftValue.Type
        let schema: Self
        if let tuple = SwiftTupleMetadata(Value.self) {
            return try hostTuple(Value.self, elements: tuple.elements, position: position)
        } else if let metatype = SwiftMetatypeMetadata(base) {
            let type =
                Value.self is any NativeOptionalValue.Type && metatype.isSingleton
                ? CValueType(swiftOptionalSingleton: ()) : try metatype.valueType(for: Value.self)
            schema = Self(type: type, kind: .metatype, metadata: Value.self)
        } else if let managed {
            return Self(
                storage: try explicitValueLayout(
                    of: Value.self,
                    abi: managed.swiftABIType,
                    source: "The ABIBridgeSwiftValue conformance"
                ),
                metadata: Value.self
            )
        } else if isAdapter {
            return Self(type: try CValueCodec<Value>().type, kind: .scalar, metadata: nil)
        } else if isObject {
            schema = try .reference(Value.self)
        } else if let existential = SwiftExistentialRepresentation(base) {
            let type = try existential.valueType(for: Value.self)
            // An Optional of an existential is an enum that reuses the
            // container's storage.
            schema =
                Value.self is any NativeOptionalValue.Type
                ? Self(storage: type, metadata: Value.self)
                : Self(type: type, kind: .existential, metadata: Value.self)
        } else if base is any SwiftCollectionValue.Type {
            schema = Self(
                type: try CValueType(scalar: ABIValuePointer),
                kind: .loadable,
                metadata: Value.self
            )
        } else if base == String.self {
            let word = try CValueType(
                scalar: MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32
            )
            let count = MemoryLayout<String>.size / MemoryLayout<UInt>.size
            schema = Self(
                type: try CValueType(fields: Array(repeating: word, count: count)),
                kind: .loadable,
                metadata: Value.self
            )
        } else if let optional = Value.self as? any NativeOptionalValue.Type,
            !(base is any NativePointerValue.Type)
        {
            // An Optional of a value with Swift storage is a Swift enum.
            schema = Self(
                storage: try optionalStorage(
                    of: Value.self,
                    wrapped: optionalPayloadStorage(optional.wrappedType),
                    wrappedType: optional.wrappedType
                ),
                metadata: Value.self
            )
        } else if infersLayout(Value.self) {
            // Explicit ABIs and built-in codecs take precedence over inference.
            schema = Self(
                storage: try SwiftInferredValue.layout(of: Value.self, position: position),
                metadata: Value.self
            )
        } else {
            return Self(type: try CValueCodec<Value>().type, kind: .scalar, metadata: Value.self)
        }
        guard schema.type.size == MemoryLayout<Value>.size,
            schema.type.alignment == MemoryLayout<Value>.alignment
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Unsupported Swift storage layout for \(String(reflecting: Value.self))."
            )
        }
        return schema
    }

    /// The schema of a host tuple: each element's host schema at the
    /// element's offset in the native tuple, which stores a native function
    /// where the host tuple stores a closure.
    private static func hostTuple<Value>(
        _: Value.Type,
        elements: [SwiftTupleMetadata.Element],
        position: SwiftValuePosition
    ) throws -> Self {
        let fields = try elements.map { element in
            let type = element.type
            guard !(type is any ABIBridgeValue.Type) || type is any ABIBridgeSwiftValue.Type else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Tuple elements require their native Swift storage representation."
                )
            }
            return try Self(host: type, position: position.tupleElement).type
        }
        let native = try SwiftGenericCallPlan.concreteNativeMetadata(Value.self)
        guard let nativeTuple = SwiftTupleMetadata(native) else {
            preconditionFailure("The native type of a tuple is a tuple.")
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(native, to: UnsafeRawPointer.self))
        return Self(
            type: try CValueType(
                swiftTuple: fields,
                offsets: nativeTuple.elements.map(\.offset),
                size: layout.size,
                alignment: layout.alignment
            ),
            kind: .tuple,
            metadata: native
        )
    }

    /// Whether `host` lowers `Value` from its metadata: a struct or enum with
    /// no Swift ABI conformance, adapter, built-in representation, or C
    /// representation.
    static func infersLayout<Value>(_: Value.Type) -> Bool {
        let kind = runtimeMetadataKind(Value.self)
        guard kind == .structure || kind == .enumeration else { return false }
        return !(Value.self is any ABIBridgeSwiftValue.Type)
            && !(Value.self is any ABIBridgeValue.Type)
            && !(Value.self is any SwiftCollectionValue.Type) && Value.self != String.self
            && !CValueCodec<Value>.hasRepresentation
    }

    // MARK: Storage

    /// The storage of an enum with payload cases, such as an Optional. Swift
    /// passes the whole value as integer data, whatever its payload types,
    /// and coalesces the bytes into pointer-sized chunks.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/EnumPayload.cpp
    static func enumStorage(of metadata: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        let byte = try CValueType(scalar: ABIValueUInt8)
        return try CValueType(
            swiftComponents: CValueType(fields: Array(repeating: byte, count: layout.size)),
            size: layout.size,
            alignment: layout.alignment
        )
    }

    /// The storage of an Optional of a value with `wrapped` storage. It is
    /// indirect when the wrapped value is address-only, and otherwise enum
    /// storage, even when the wrapped value alone is too large for registers.
    static func optionalStorage(
        of metadata: Any.Type,
        wrapped: CValueType,
        wrappedType: Any.Type
    ) throws -> CValueType {
        // A thin metatype occupies a word in memory but no register, so its
        // Optional would pass a different enum than the memory holds.
        guard !containsThinMetatype(wrappedType) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An Optional containing a thin metatype is unsupported: \(String(reflecting: metadata))."
            )
        }
        if withExtendedLifetime(wrapped, { ABISwiftValueIsAddressOnly(wrapped.handle) }) {
            return try storage(of: metadata)
        }
        return try enumStorage(of: metadata)
    }

    private static func containsThinMetatype(_ type: Any.Type) -> Bool {
        if let metatype = SwiftMetatypeMetadata(type) { return metatype.isSingleton }
        if let optional = type as? any NativeOptionalValue.Type {
            return containsThinMetatype(optional.wrappedType)
        }
        if let tuple = SwiftTupleMetadata(type) {
            return tuple.elements.contains { containsThinMetatype($0.type) }
        }
        return false
    }

    /// Indirect storage for a value of `type`, which native code addresses through its metadata.
    static func storage(of type: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    /// The Swift storage with which an Optional's payload of type `wrapped`
    /// passes, which decides the Optional's own storage.
    static func optionalPayloadStorage(_ wrapped: Any.Type) throws -> CValueType {
        let payload = try Self(host: wrapped, position: .nested)
        // A payload that converts, such as an adapter or a closure, has a
        // native type other than its host type.
        guard payload.metadata == wrapped else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An Optional requires its wrapped value's Swift storage: "
                    + "\(String(reflecting: wrapped))."
            )
        }
        return payload.type
    }

    /// The storage Swift gives a value of the Optional `metadata` from its
    /// payload's storage: what `payload` states, or the payload type's own.
    ///
    /// Nil when `metadata` is not an Optional or ABIBridge cannot establish
    /// the payload's convention. Any failure to establish it, such as missing
    /// metadata, an undecided inferred convention, or an unsupported element,
    /// means the convention is not established, so it does not throw.
    static func establishedOptionalStorage(
        of metadata: Any.Type,
        payload: () throws -> CValueType? = { nil }
    ) -> CValueType? {
        guard let wrapped = (metadata as? any NativeOptionalValue.Type)?.wrappedType else {
            return nil
        }
        return try? optionalStorage(
            of: metadata,
            wrapped: payload() ?? optionalPayloadStorage(wrapped),
            wrappedType: wrapped
        )
    }

    /// The storage `abi` describes for a Swift value of `metadata`.
    static func explicitLayout(of metadata: Any.Type, abi: NativeType) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        if let components = abi.cType {
            guard (layout.size...layout.stride).contains(components.size) else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Swift ABI components must cover the value without exceeding its stride: "
                        + "\(String(reflecting: metadata))."
                )
            }
            return try CValueType(
                swiftComponents: components,
                size: layout.size,
                alignment: layout.alignment
            )
        }
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    /// The storage `abi` describes for a value of `metadata` wherever the
    /// type occurs as a value, such as an argument, a result, or a field.
    ///
    /// An Optional passes as its enum storage, or by address when its payload
    /// is address-only, whatever ABI describes it. When ABIBridge establishes
    /// that storage from the payload's, `abi` must pass the same way, so a
    /// different convention fails here instead of passing the value wrongly.
    /// Otherwise `abi` states the Optional's convention unchecked.
    ///
    /// - Parameters:
    ///   - source: What states `abi`, such as "The valueABIs entry".
    ///   - payload: The storage the caller states for an Optional's payload,
    ///     or nil to use the payload's own. A failure counts as a payload
    ///     whose convention is not established.
    static func explicitValueLayout(
        of metadata: Any.Type,
        abi: NativeType,
        source: String,
        payload: () throws -> CValueType? = { nil }
    ) throws -> CValueType {
        let explicit = try explicitLayout(of: metadata, abi: abi)
        if let own = establishedOptionalStorage(of: metadata, payload: payload) {
            try SwiftDeclaredLowering.checkExplicit(
                explicit,
                statedBy: source,
                forOptional: metadata,
                own: own
            )
        }
        return explicit
    }

    /// An inline field whose size remains an unbound archetype makes the containing value formally indirect, independently of the nominal type's resilience. Other values follow their bound type's explicit or inferred convention.
    static func isIndirect(_ metadata: Any.Type, arguments: [SwiftFormalType],
                           binding: SwiftGenericBinding) throws -> Bool {
        let context = try SwiftGenericTypeContext(metadata: metadata)
        guard context.parameters.count == arguments.count else { return false }
        let substitutions = Dictionary(uniqueKeysWithValues: zip(context.parameters.map(\.name), arguments))
        func hasUnboundStorage(_ type: SwiftFormalType) throws -> Bool {
            let type = try binding.canonicalType(of: type)
            switch type {
            case .associated:
                return try !binding.isClassBound(type)
            case .opaqueResult(let index):
                guard let value = binding.opaqueResults[index] else {
                    throw ABIResolutionError.metadataUnavailable("The opaque field ABI has not been resolved.")
                }
                return ABISwiftValueIsIndirect(value.type.handle)
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if case .named = type, arguments.isEmpty, binding.arguments[String(name.prefix { $0 != "." })] != nil {
                    return try !binding.isClassBound(type)
                }
                if name == "Swift.Optional", let wrapped = arguments.first { return try hasUnboundStorage(wrapped) }
                if arguments.isEmpty || (!binding.dependsOnParameters(type) && type.opaqueIndices.isEmpty) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .reference(_, let arguments):
                if arguments.isEmpty || (!binding.dependsOnParameters(type) && type.opaqueIndices.isEmpty) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .nested:
                guard let declaration = type.nominalDeclaration, binding.dependsOnParameters(type) || !type.opaqueIndices.isEmpty else { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: declaration.arguments, binding: binding)
            case .tuple(let elements, _): return try elements.contains(where: hasUnboundStorage)
            case .pack: return true
            default: return false
            }
        }

        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        for index in 0..<ABISwiftTypeFieldCount(pointer) {
            guard let handle = ABICopySwiftTypeFieldSyntax(pointer, index) else { continue }
            let type = try SwiftFormalType(SwiftSyntax(adopting: handle).root)
                .qualifyingAssociatedTypes(using: context.conformances)
            if try hasUnboundStorage(type.substituting(substitutions)) { return true }
        }
        return false
    }
}
