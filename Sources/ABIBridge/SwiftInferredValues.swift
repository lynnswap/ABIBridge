import ABIBridgeCore
import ABIBridgeRuntime
import Darwin
import Synchronization

/// Where a value occurs in a Swift signature.
///
/// Swift passes a whole parameter, result, or `self` indirectly once its
/// loadable lowering exceeds four registers. A value whose resilience is
/// undecided but whose frozen lowering is already that large therefore has one
/// convention either way. Elsewhere, loadable and address-only values differ.
enum SwiftValuePosition: Sendable, Equatable {
    case parameter, result
    /// An Optional or enum payload, a stored field, or a tuple result element.
    case nested

    var isWhole: Bool { self != .nested }

    /// Parameters expand tuples into separate parameters; results lower a
    /// tuple as one value.
    var tupleElement: Self { self == .parameter ? .parameter : .nested }
}

/// Lowers a struct or enum without an explicit ABI from its runtime metadata.
///
/// A client passes a struct or enum indirectly when it is resilient to
/// clients, or when a stored field or direct payload is address-only.
/// Otherwise it is loadable and uses the same swiftcc expansion as an explicit
/// layout. Nothing in a descriptor, its field records, or its property
/// descriptors records `@frozen`, so resilience is decided from other evidence,
/// and an inference that the evidence does not decide fails:
///
/// - Runtime singleton metadata initialization stores a resilient type from
///   another module; a value that is not bitwise-takable stores a weak or
///   non-native unowned reference. Both are address-only.
/// - The value-witness addressable-for-dependencies bit is set for a resilient
///   type and for any value that stores one. Static metadata without it
///   certifies that nothing in the value is resilient, once its module has
///   shown that it sets the bit (Swift 6.2 and later) or is built without
///   library evolution.
/// - A set bit that no field explains marks the type itself resilient in a
///   library-evolution module. `String`, `Data`, and imported C structs
///   always set it, so such fields leave a public struct undecided.
/// - A resilient enum exports enum case symbols; a module built without
///   library evolution has trivial descriptors for its stored properties.
///   Missing exports count only after the bit leaves the question open.
///
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SIL/IR/TypeLowering.cpp
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenValueWitness.cpp
enum SwiftInferredValue {
    enum Convention: Sendable {
        case loadable(CValueType)
        case addressOnly
        /// The evidence does not decide whether the value is resilient.
        /// `frozen` is its lowering if it and every undecided value it stores
        /// were frozen.
        case undecided(frozen: CValueType, missing: String)
    }

    /// The storage of a value of `metadata` at `position`.
    static func layout(of metadata: Any.Type, position: SwiftValuePosition) throws -> CValueType {
        let convention: Convention
        do { convention = try self.convention(of: metadata) } catch let failure as InferenceFailure
        {
            let message = Self.message(for: metadata, failure.detail)
            throw failure.unsupported
                ? ABIResolutionError.unsupportedDeclaration(message)
                : ABIResolutionError.metadataUnavailable(message)
        }
        switch convention {
        case .loadable(let layout):
            return layout
        case .addressOnly:
            return try SwiftValueSchema.storage(of: metadata)
        case .undecided(let frozen, let missing):
            // A loadable value that large is already passed indirectly.
            if position.isWhole,
                withExtendedLifetime(frozen, { ABISwiftValueIsIndirect(frozen.handle) })
            {
                return try SwiftValueSchema.storage(of: metadata)
            }
            throw ABIResolutionError.metadataUnavailable(Self.message(for: metadata, missing))
        }
    }

    /// Whether a host type, or a value it contains as an Optional payload or
    /// tuple element, lowers only through inference.
    static func lowersByInference(_ type: Any.Type) -> Bool {
        if let optional = type as? any NativeOptionalValue.Type {
            return lowersByInference(optional.wrappedType)
        }
        if let tuple = SwiftTupleMetadata(type) {
            return tuple.elements.contains { lowersByInference($0.type) }
        }
        func infers<Value>(_: Value.Type) -> Bool { SwiftValueCodec<Value>.infersLayout }
        return _openExistential(type, do: infers)
    }

    private static func message(for type: Any.Type, _ detail: String) -> String {
        let module =
            ABISwiftTypeModuleName(unsafeBitCast(type, to: UnsafeRawPointer.self))
            .map { " in module " + String(cString: $0) } ?? ""
        return "Cannot infer the Swift calling convention of \(String(reflecting: type))\(module): "
            + detail + ". Describe the type with valueABIs or an ABIBridgeSwiftValue conformance."
    }

    // MARK: Classification

    fileprivate struct InferenceFailure: Error {
        /// A value kind that field records cannot describe, rather than
        /// missing evidence.
        let unsupported: Bool
        let detail: String
    }

    private static let conventions = Mutex<
        [ObjectIdentifier: Result<Convention, InferenceFailure>]
    >([:])

    /// The classification of a struct or enum, cached per metadata. Swift
    /// metadata stays valid because images with Swift metadata are not unloaded.
    private static func convention(of metadata: Any.Type) throws -> Convention {
        let key = ObjectIdentifier(metadata)
        if let cached = conventions.withLock({ $0[key] }) { return try cached.get() }
        // Fields classify recursively, so classify outside the lock.
        let result = Result { () throws(InferenceFailure) -> Convention in
            try classify(metadata)
        }
        return try conventions.withLock { conventions in
            conventions[key] = conventions[key] ?? result
            return conventions[key]!
        }.get()
    }

    private struct Field {
        let name: String
        /// Nil for an indirect enum case, which stores a box reference.
        let type: Any.Type?
        let offset: Int
        let reference: ABISwiftReferenceStorage
        let genericDependent: Bool

        var description: String {
            type.map { "`\(name): \(String(reflecting: $0))`" } ?? "`\(name)`"
        }
    }

    /// A field's storage in its parent. Loadable storage is nil for a field
    /// with no bytes, such as a thin metatype.
    private enum Part {
        case loadable(CValueType?)
        case addressOnly
        case undecided(CValueType?, missing: String)
    }

    // Value-witness flags (MetadataValues.h).
    private static let nonBitwiseTakable: UInt32 = 0x0010_0000
    private static let nonCopyable: UInt32 = 0x0080_0000
    private static let addressableForDependencies: UInt32 = 0x0200_0000

    private static func classify(_ metadata: Any.Type) throws(InferenceFailure) -> Convention {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        var info = ABISwiftValueDescriptorInfo()
        guard ABISwiftGetValueDescriptorInfo(pointer, &info) else {
            throw InferenceFailure(unsupported: true, detail: "it is not a struct or enum")
        }
        let flags = ABISwiftGetValueWitnessFlags(pointer)
        if flags & nonCopyable != 0 {
            throw InferenceFailure(unsupported: true, detail: "noncopyable values are not inferred")
        }
        // Clang owns these layouts: bitfields, packing, and pointer-authenticated
        // fields are not visible in their field records.
        if info.metadataInitialization == 2 {
            throw InferenceFailure(
                unsupported: true,
                detail: "imported C structs and unions are not inferred from their field records"
            )
        }
        // Runtime initialization lays out a resilient type from another module.
        if info.metadataInitialization == 1 || flags & nonBitwiseTakable != 0 {
            return .addressOnly
        }
        let fields = try readFields(of: metadata, info: info)
        var parts: [CValueType?] = []
        var undecidedField: String?
        for field in fields {
            let part: Part
            do throws(InferenceFailure) {
                part = try self.part(of: field)
            } catch {
                throw InferenceFailure(
                    unsupported: error.unsupported,
                    detail: "its field \(field.description) cannot be lowered: \(error.detail)"
                )
            }
            switch part {
            case .addressOnly: return .addressOnly
            case .loadable(let layout): parts.append(layout)
            case .undecided(let layout, let missing):
                parts.append(layout)
                undecidedField = undecidedField ?? missing
            }
        }
        let frozen = try layout(of: metadata, info: info, fields: fields, parts: parts)
        let module = ModuleContext(metadata)
        let isStatic = !info.isGeneric && info.metadataInitialization == 0
        // Nothing in a value whose bit stays clear is resilient.
        if isStatic, flags & addressableForDependencies == 0,
            module.setsAddressableForDependencies || module.evidence?.libraryEvolution == .disabled
        {
            return .loadable(frozen)
        }
        switch resilience(of: metadata, info: info, flags: flags, fields: fields, module: module) {
        case .resilient:
            return .addressOnly
        case .fixed:
            return undecidedField.map { .undecided(frozen: frozen, missing: $0) }
                ?? .loadable(frozen)
        case .unknown(let missing):
            return .undecided(frozen: frozen, missing: missing)
        }
    }

    private static func readFields(
        of metadata: Any.Type,
        info: ABISwiftValueDescriptorInfo
    ) throws(InferenceFailure) -> [Field] {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        guard info.hasFieldRecords else {
            throw InferenceFailure(
                unsupported: false,
                detail:
                    "it has no reflection field descriptor; its image may be built without reflection metadata"
            )
        }
        guard info.fieldRecords == info.declaredFields else {
            throw InferenceFailure(
                unsupported: false,
                detail:
                    "its reflection records list \(info.fieldRecords) fields, but its descriptor declares \(info.declaredFields)"
            )
        }
        let count = Int(info.isEnum ? info.payloadCases : info.declaredFields)
        return try (0..<count).map { index throws(InferenceFailure) -> Field in
            let name =
                ABISwiftTypeFieldName(pointer, index).map { String(cString: $0) } ?? "#\(index)"
            var caseInfo = ABISwiftEnumCaseInfo()
            if info.isEnum, ABISwiftGetEnumCaseInfo(pointer, index, &caseInfo), caseInfo.indirect {
                return Field(
                    name: name,
                    type: nil,
                    offset: 0,
                    reference: ABISwiftReferenceStorageNone,
                    genericDependent: false
                )
            }
            let reference = ABISwiftTypeFieldReferenceStorage(pointer, index)
            guard reference != ABISwiftReferenceStorageUnknown,
                let field = ABISwiftTypeFieldMetadata(pointer, index)
            else {
                throw InferenceFailure(
                    unsupported: false,
                    detail:
                        "the type of its field `\(name)` cannot be resolved from its field record"
                )
            }
            var offset = 0
            if !info.isEnum {
                guard ABISwiftStructFieldOffset(pointer, index, &offset) else {
                    throw InferenceFailure(
                        unsupported: false,
                        detail: "its metadata has no field offset for `\(name)`"
                    )
                }
            }
            return Field(
                name: name,
                type: unsafeBitCast(field, to: Any.Type.self),
                offset: offset,
                reference: reference,
                genericDependent: ABISwiftTypeFieldIsGenericDependent(pointer, index)
            )
        }
    }

    // MARK: Field storage

    private static func part(of field: Field) throws(InferenceFailure) -> Part {
        guard let type = field.type else { return try .loadable(pointer()) }
        if field.reference == ABISwiftReferenceStorageWeak { return .addressOnly }
        // Unowned references keep their referent's storage; a non-native one is
        // not bitwise-takable, which already made the parent address-only.
        return try part(of: type, genericDependent: field.genericDependent)
    }

    private static func part(
        of type: Any.Type,
        genericDependent: Bool = false
    ) throws(InferenceFailure)
        -> Part
    {
        switch runtimeMetadataKind(type) {
        case .function:
            return try .loadable(functionStorage(type))
        case .optional:
            let wrapped = (type as! any NativeOptionalValue.Type).wrappedType
            func optional(_ payload: CValueType?) throws(InferenceFailure) -> CValueType {
                try failing {
                    try SwiftValueSchema.optionalStorage(
                        of: type,
                        wrapped: payload
                            ?? CValueType(swiftAggregate: [], offsets: [], size: 0, alignment: 1),
                        wrappedType: wrapped
                    )
                }
            }
            switch try part(of: wrapped, genericDependent: genericDependent) {
            case .addressOnly: return .addressOnly
            case .loadable(let payload): return try .loadable(optional(payload))
            case .undecided(let payload, let missing):
                return try .undecided(optional(payload), missing: missing)
            }
        case .tuple:
            return try tuplePart(type)
        case .metatype, .existentialMetatype, .extendedExistential:
            guard let metatype = SwiftMetatypeMetadata(type) else { return try codecPart(type) }
            // A field stores a concrete non-class metatype thin, in no bytes,
            // unless its declared type is generic.
            if metatype.isSingleton, !genericDependent { return .loadable(nil) }
            func thick<Value>(_: Value.Type) throws -> CValueType {
                try metatype.valueType(for: Value.self, thin: false)
            }
            return try .loadable(failing { try _openExistential(type, do: thick) })
        case .opaque:
            return try .loadable(builtinStorage(type))
        case .structure, .enumeration:
            guard lowersByInference(type) else { return try codecPart(type) }
            let convention: Convention
            do { convention = try self.convention(of: type) } catch { throw failure(from: error) }
            switch convention {
            case .loadable(let layout): return .loadable(layout)
            case .addressOnly: return .addressOnly
            case .undecided(let frozen, let missing): return .undecided(frozen, missing: missing)
            }
        default:
            return try codecPart(type)
        }
    }

    private static func failing<Result>(
        _ body: () throws -> Result
    ) throws(InferenceFailure) -> Result {
        do { return try body() } catch { throw failure(from: error) }
    }

    private static func failure(from error: any Error) -> InferenceFailure {
        switch error {
        case let failure as InferenceFailure: failure
        case ABIResolutionError.unsupportedDeclaration(let detail):
            InferenceFailure(unsupported: true, detail: detail)
        case ABIResolutionError.metadataUnavailable(let detail):
            InferenceFailure(unsupported: false, detail: detail)
        default: InferenceFailure(unsupported: false, detail: "\(error)")
        }
    }

    private static func pointer() throws(InferenceFailure) -> CValueType {
        try failing { try CValueType(scalar: ABIValuePointer) }
    }

    /// Classes, existentials, and values with built-in codecs keep their
    /// codec's storage.
    private static func codecPart(_ type: Any.Type) throws(InferenceFailure) -> Part {
        func storage<Value>(_: Value.Type) throws -> CValueType {
            let codec = try SwiftValueCodec<Value>()
            guard codec.storesSwiftValue else {
                throw InferenceFailure(
                    unsupported: true,
                    detail: "\(String(reflecting: Value.self)) converts to a foreign representation"
                )
            }
            return codec.type
        }
        let layout = try failing { try _openExistential(type, do: storage) }
        return withExtendedLifetime(layout, { ABISwiftValueIsAddressOnly(layout.handle) })
            ? .addressOnly : .loadable(layout)
    }

    /// Thick Swift functions store an entry point and a context; blocks, thin
    /// functions, and C function pointers store one word.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h
    private static func functionStorage(_ type: Any.Type) throws(InferenceFailure) -> CValueType {
        let flags = unsafeBitCast(type, to: UnsafeRawPointer.self)
            .load(fromByteOffset: MemoryLayout<UInt>.size, as: UInt.self)
        return try failing {
            let pointer = try CValueType(scalar: ABIValuePointer)
            return flags >> 16 & 0xff == 0 ? try CValueType(fields: [pointer, pointer]) : pointer
        }
    }

    /// Builtin storage that stdlib structs such as `ObjectIdentifier` hold.
    /// Vectors, `FPIEEE16`, and integers wider than a word have no lowering
    /// here.
    private static func builtinStorage(_ type: Any.Type) throws(InferenceFailure) -> CValueType {
        let name = _mangledTypeName(type) ?? String(reflecting: type)
        let scalar: Int? =
            switch name {
            case "Bi1_", "Bi8_": ABIValueUInt8
            case "Bi16_": ABIValueUInt16
            case "Bi32_": ABIValueUInt32
            case "Bi64_": ABIValueUInt64
            case "Bf32_": ABIValueFloat
            case "Bf64_": ABIValueDouble
            case "Bw", "Bp", "Bo", "Bb", "BO": ABIValuePointer
            default: nil
            }
        guard let scalar else {
            throw InferenceFailure(
                unsupported: true,
                detail:
                    "it stores \(String(reflecting: type)); SIMD vectors, Float16, and Int128 are not inferred"
            )
        }
        return try failing { try CValueType(scalar: scalar) }
    }

    /// A tuple field is one formal value at its tuple metadata offsets.
    /// Inside a nominal type, a thin metatype element takes no bytes while the
    /// tuple metadata gives it a word, so those tuples are not inferred.
    private static func tuplePart(_ type: Any.Type) throws(InferenceFailure) -> Part {
        let tuple = SwiftTupleMetadata(type)!
        guard !tuple.elements.contains(where: { SwiftMetatypeMetadata($0.type) != nil }) else {
            throw InferenceFailure(
                unsupported: true,
                detail: "tuple fields containing metatypes are not inferred"
            )
        }
        var layouts: [CValueType?] = []
        var missing: String?
        for element in tuple.elements {
            switch try part(of: element.type) {
            case .addressOnly: return .addressOnly
            case .loadable(let layout): layouts.append(layout)
            case .undecided(let layout, let reason):
                layouts.append(layout)
                missing = missing ?? reason
            }
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        let aggregate = try aggregate(
            layouts,
            offsets: tuple.elements.map(\.offset),
            size: layout.size,
            alignment: layout.alignment,
            of: type
        )
        return missing.map { .undecided(aggregate, missing: $0) } ?? .loadable(aggregate)
    }

    private static func aggregate(
        _ fields: [CValueType?],
        offsets: [Int],
        size: Int,
        alignment: Int,
        of type: Any.Type
    ) throws(InferenceFailure) -> CValueType {
        // Fields without bytes say nothing about the layout; static metadata
        // places empty fields at offset 0, after the fields before them.
        let present = zip(fields, offsets).compactMap { field, offset in
            field.flatMap { $0.size == 0 ? nil : ($0, offset) }
        }
        do {
            return try CValueType(
                swiftAggregate: present.map(\.0),
                offsets: present.map(\.1),
                size: size,
                alignment: alignment
            )
        } catch {
            throw InferenceFailure(
                unsupported: false,
                detail: "its field metadata does not reproduce its value-witness layout (\(error))"
            )
        }
    }

    /// The value's lowering, assuming that it and its undecided fields are frozen.
    private static func layout(
        of metadata: Any.Type,
        info: ABISwiftValueDescriptorInfo,
        fields: [Field],
        parts: [CValueType?]
    ) throws(InferenceFailure) -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        guard info.isEnum else {
            return try aggregate(
                parts,
                offsets: fields.map(\.offset),
                size: layout.size,
                alignment: layout.alignment,
                of: metadata
            )
        }
        // An enum with exactly one case, which has a payload, lowers as that
        // payload. Other enums pass their bytes as integer chunks.
        // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenEnum.cpp
        guard info.declaredFields == 1, info.payloadCases == 1 else {
            return try failing { try SwiftValueSchema.enumStorage(of: metadata) }
        }
        return try aggregate(
            [parts[0]],
            offsets: [0],
            size: layout.size,
            alignment: layout.alignment,
            of: metadata
        )
    }

    // MARK: Resilience

    private enum Resilience {
        case resilient, fixed
        case unknown(String)
    }

    private enum Addressability {
        case no, yes, unknown
    }

    private static func resilience(
        of metadata: Any.Type,
        info: ABISwiftValueDescriptorInfo,
        flags: UInt32,
        fields: [Field],
        module: ModuleContext
    ) -> Resilience {
        let name = String(reflecting: metadata)
        let kind = info.isEnum ? "enum" : "struct"
        let evidence = module.evidence
        if evidence?.libraryEvolution == .disabled { return .fixed }
        if info.isEnum, let image = module.image, let declaration = module.declaration,
            RuntimeSymbolResolver.shared.exportsSwiftEnumCases(declaration: declaration, in: image)
        {
            return .resilient
        }
        let isStatic = !info.isGeneric && info.metadataInitialization == 0
        var explanation: String?
        if isStatic, module.setsAddressableForDependencies, flags & addressableForDependencies != 0
        {
            if isSelfAddressable(metadata) {
                explanation = "its own @_addressableForDependencies attribute explains"
            } else {
                let explained = fields.map { ($0, $0.type.map(addressability) ?? .no) }
                if let field = explained.first(where: {
                    if case .yes = $0.1 { true } else { false }
                }) {
                    explanation = "its field \(field.0.description) explains"
                } else if let field = explained.first(where: {
                    if case .unknown = $0.1 { true } else { false }
                }) {
                    explanation =
                        "its field \(field.0.description) has runtime-built metadata, which may explain"
                } else if evidence?.libraryEvolution == .enabled {
                    return .resilient
                }
            }
        }
        // Missing exports decide only what the value witnesses left open.
        if module.image != nil, let evidence {
            let exported = module.declaration != nil
            // An exported enum without case symbols is frozen.
            if info.isEnum, exported { return .fixed }
            // A declaration a library does not export is not public, so it is
            // not resilient.
            if !exported, evidence.isLibrary, evidence.exportsSymbols { return .fixed }
        }
        let moduleName = module.name.map { "module `\($0)`" } ?? "its module"
        let unreadable = "ABIBridge cannot read the exports of \(moduleName)"
        let undecidedModule = "\(moduleName) does not show whether it is built with library evolution"
        if let explanation {
            let status =
                switch evidence?.libraryEvolution {
                case .enabled:
                    "library-evolution \(moduleName) does not record whether \(kind) `\(name)` is @frozen"
                case nil: "\(unreadable), so it cannot tell whether \(kind) `\(name)` is resilient"
                default: "\(undecidedModule), or whether \(kind) `\(name)` is @frozen"
                }
            return .unknown(
                "\(status); \(explanation) its addressable-for-dependencies value-witness bit"
            )
        }
        if !isStatic {
            let module =
                evidence == nil
                ? unreadable : "\(moduleName) shows no evidence that it is built without library evolution"
            return .unknown(
                "\(info.isGeneric ? "generic " : "")\(kind) `\(name)` has runtime-built metadata, whose value witnesses do not show whether it is @frozen, and \(module)"
            )
        }
        if !module.setsAddressableForDependencies {
            return .unknown(
                "\(moduleName) never sets the addressable-for-dependencies value-witness bit, as Swift 6.1 and earlier compilers do not, and shows no other evidence of whether `\(name)` is @frozen"
            )
        }
        return .unknown(
            "\(evidence == nil ? unreadable : undecidedModule), so the addressable-for-dependencies value-witness bit of `\(name)` does not decide whether it is @frozen"
        )
    }

    /// Whether a field explains its parent's addressable-for-dependencies bit.
    private static func addressability(of type: Any.Type) -> Addressability {
        switch runtimeMetadataKind(type) {
        case .optional:
            return addressability(of: (type as! any NativeOptionalValue.Type).wrappedType)
        case .tuple:
            let elements = SwiftTupleMetadata(type)!.elements.map { addressability(of: $0.type) }
            if elements.contains(where: { if case .yes = $0 { true } else { false } }) {
                return .yes
            }
            if elements.contains(where: { if case .unknown = $0 { true } else { false } }) {
                return .unknown
            }
            return .no
        case .structure, .enumeration:
            break
        default:
            // References, closures, existentials, metatypes, and builtins.
            return .no
        }
        if type == String.self { return .yes }
        if isSelfAddressable(type) { return .yes }
        if type is any SwiftCollectionValue.Type || type is any NativePointerValue.Type
            || type == Bool.self
        {
            return .no
        }
        func scalar<Value>(_: Value.Type) -> Bool { CValueCodec<Value>.isScalar }
        if _openExistential(type, do: scalar) { return .no }
        let pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
        var info = ABISwiftValueDescriptorInfo()
        guard ABISwiftGetValueDescriptorInfo(pointer, &info) else { return .unknown }
        if info.metadataInitialization == 2 { return .yes }
        // Only static metadata from a module known to set the bit carries it.
        guard !info.isGeneric, info.metadataInitialization == 0,
            ModuleContext(type).setsAddressableForDependencies
        else { return .unknown }
        return ABISwiftGetValueWitnessFlags(pointer) & addressableForDependencies != 0 ? .yes : .no
    }

    /// `@frozen @_addressableForDependencies` declarations set the bit for
    /// themselves, whatever they store.
    private static func isSelfAddressable(_ type: Any.Type) -> Bool {
        var name = String(reflecting: type)
        for group in SwiftGenericSyntax.groups(in: name).reversed() {
            name.removeSubrange(group.range)
        }
        return swiftSelfAddressableDeclarations.contains(name)
    }
}

// MARK: Module evidence

/// The image and module that declare a nominal type, and their evidence.
private struct ModuleContext {
    let name: String?
    let image: RuntimeImage?
    /// The type's mangled declaration as its image exports the type's
    /// descriptor, or nil when the export trie does not show the descriptor.
    let declaration: String?
    let evidence: RuntimeSwiftModuleEvidence?
    let setsAddressableForDependencies: Bool

    private struct Key: Hashable {
        let header: UInt
        let module: String
    }
    private struct Image: Sendable {
        let image: RuntimeImage?
        let setsAddressableForDependencies: Bool
    }
    private static let images = Mutex<[Key: Image]>([:])

    init(_ metadata: Any.Type) {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        name = ABISwiftTypeModuleName(pointer).map { String(cString: $0) }
        var info = Dl_info()
        guard let name, let descriptor = ABISwiftTypeDescriptor(pointer),
            dladdr(descriptor, &info) != 0,
            let header = info.dli_fbase, let path = info.dli_fname
        else {
            image = nil; declaration = nil; evidence = nil; setsAddressableForDependencies = false
            return
        }
        let key = Key(header: UInt(bitPattern: header), module: name)
        let cached: Image
        if let image = Self.images.withLock({ $0[key] }) {
            cached = image
        } else {
            // A missing image leaves only metadata evidence.
            let image = Image(
                image: try? RuntimeImage.opening(path: String(cString: path), loading: .loadedOnly),
                setsAddressableForDependencies: ABISwiftModuleSetsAddressableForDependencies(
                    pointer
                )
            )
            cached = Self.images.withLock { images in
                images[key] = images[key] ?? image
                return images[key]!
            }
        }
        image = cached.image
        setsAddressableForDependencies = cached.setsAddressableForDependencies
        guard let image = cached.image else {
            declaration = nil; evidence = nil
            return
        }
        let mangled = _mangledTypeName(metadata)
        evidence = mangled.flatMap { Self.mangling(ofModule: name, in: $0) }.map {
            RuntimeSwiftModuleEvidence.evidence(forModule: $0, in: image)
        }
        let address = UInt64(UInt(bitPattern: descriptor))
        // The runtime spelling finds standard library substitutions such as
        // `Si`, whose symbols lie outside the module's context; the module's
        // exports by address find declarations the runtime spells otherwise.
        if let spelled = mangled.flatMap({ Self.declaration(of: $0, metadata: metadata) }),
            RuntimeSymbolResolver.shared.exportedAddress(named: "_$s" + spelled + "Mn", in: image)
                == address
        {
            declaration = spelled
        } else {
            declaration = evidence?.exportedDeclaration(at: address)
        }
    }

    /// The module's context as it starts a mangled type name and the
    /// module's symbols: `s` for the standard library, otherwise the leading
    /// identifier, when it names the module. Within that identifier, a word
    /// that repeats an earlier one is mangled as a letter.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/Demangling/Demangler.cpp
    private static func mangling(ofModule name: String, in mangled: String) -> String? {
        if name == "Swift" { return "s" }
        let text = Array(mangled.utf8)
        func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        func isUpper(_ byte: UInt8) -> Bool { (65...90).contains(byte) }
        func isLower(_ byte: UInt8) -> Bool { (97...122).contains(byte) }
        guard let first = text.first, isDigit(first),
            !text.starts(with: Array("00".utf8))
        else { return nil }
        var position = first == 48 ? 1 : 0
        var substitutes = first == 48
        var identifier: [UInt8] = []
        var words: [ArraySlice<UInt8>] = []
        repeat {
            while substitutes, position < text.count,
                isUpper(text[position]) || isLower(text[position])
            {
                let letter = text[position]
                position += 1
                substitutes = isLower(letter)
                let index = Int(letter - (substitutes ? 97 : 65))
                guard index < words.count else { return nil }
                identifier += words[index]
            }
            if position < text.count, text[position] == 48 {
                position += 1
                break
            }
            let start = position
            while position < text.count, isDigit(text[position]) { position += 1 }
            guard let length = Int(String(decoding: text[start..<position], as: UTF8.self)),
                length > 0, position + length <= text.count
            else { return nil }
            let part = text[position..<position + length]
            identifier += part
            // A word starts at a character other than a digit or `_` and
            // ends before `_` or an uppercase letter after a non-uppercase one.
            var word: Int?
            for index in part.startIndex...part.endIndex {
                let byte = index < part.endIndex ? part[index] : 0
                if let start = word,
                    byte == 95 || byte == 0 || (!isUpper(part[index - 1]) && isUpper(byte))
                {
                    if index - start >= 2, words.count < 26 { words.append(part[start..<index]) }
                    word = nil
                }
                if word == nil, !isDigit(byte), byte != 95, byte != 0 { word = index }
            }
            position += length
        } while substitutes
        guard identifier.elementsEqual(name.utf8) else { return nil }
        return String(decoding: text[..<position], as: UTF8.self)
    }

    private static func declaration(of mangled: String, metadata: Any.Type) -> String? {
        var info = ABISwiftValueDescriptorInfo()
        guard
            ABISwiftGetValueDescriptorInfo(
                unsafeBitCast(metadata, to: UnsafeRawPointer.self),
                &info
            ),
            info.isGeneric
        else { return mangled }
        return try? swiftNominalClosureName(mangled)
    }
}
