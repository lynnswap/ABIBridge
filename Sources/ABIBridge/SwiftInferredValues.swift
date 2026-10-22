import ABIBridgeCore
import ABIBridgeRuntime
import Darwin
import Synchronization

/// Where a value occurs in a Swift signature.
///
/// Swift passes a whole parameter, result, or `self` indirectly once its
/// loadable lowering exceeds four registers. A value whose convention is
/// undecided but whose frozen lowering is already that large therefore has one
/// convention either way. Elsewhere, loadable and address-only values differ.
enum SwiftValuePosition: Sendable, Equatable {
    case parameter, result
    /// `self`, which `receiverABI` describes instead of `valueABIs`.
    case receiver
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
/// layout. Nothing in a descriptor or its field records records `@frozen`, so
/// inference decides only from summaries the compiler wrote into the type's
/// own static metadata and from positive evidence of resilience. Everything
/// else stays undecided and fails:
///
/// - Singleton metadata initialization stores a resilient type from another
///   module, and static value witnesses that are not bitwise-takable store a
///   weak or non-native unowned reference. Both are address-only, as is a
///   value that stores a weak reference, an opaque existential, or another
///   address-only value.
/// - Exported enum case symbols mark an enum resilient.
/// - The value-witness addressable-for-dependencies bit is set for a resilient
///   type, for a stored property of an opaque type (`some P`) that is not
///   class-bound, and for any value that stores either. A set bit that no
///   field explains marks the type resilient where its module exports
///   symbols that only library evolution emits. `String`, `Data`, and
///   imported C structs always set it, so such fields leave a type undecided.
/// - A nongeneric type whose static value witnesses leave the bit clear is
///   loadable once a type of its module sets the bit, which Swift 6.1 and
///   earlier compilers never do. Its fields, including generic instances, are
///   decided with it.
///
/// Missing symbols, the form of property descriptors, the runtime-built value
/// witnesses of a generic instance, and class reference counting are not
/// evidence: each made a resilient or address-only value look loadable.
///
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SIL/IR/TypeLowering.cpp
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenValueWitness.cpp
enum SwiftInferredValue {
    enum Convention: Sendable {
        case loadable(CValueType)
        case addressOnly
        /// The evidence does not decide whether the value is resilient or
        /// address-only. `frozen` is its lowering if it and every value it
        /// stores were frozen.
        case undecided(frozen: CValueType, missing: String)
    }

    /// The storage of a value of `metadata` at `position`.
    static func layout(of metadata: Any.Type, position: SwiftValuePosition) throws -> CValueType {
        let convention: Convention
        do throws(InferenceFailure) {
            convention = try self.convention(of: metadata)
        } catch {
            let message = Self.message(for: metadata, error.detail, at: position)
            throw error.unsupported
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
            throw ABIResolutionError.metadataUnavailable(
                Self.message(for: metadata, missing, at: position)
            )
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

    private static func message(
        for type: Any.Type,
        _ detail: String,
        at position: SwiftValuePosition
    ) -> String {
        let module =
            ABISwiftTypeModuleName(unsafeBitCast(type, to: UnsafeRawPointer.self))
            .map { " in module " + String(cString: $0) } ?? ""
        let remedy =
            position == .receiver
            ? "Describe self with receiverABI or an ABIBridgeSwiftValue conformance."
            : "Describe the type with valueABIs or an ABIBridgeSwiftValue conformance."
        return "Cannot infer the Swift calling convention of \(String(reflecting: type))\(module): "
            + detail + ". " + remedy
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
    private static func convention(of metadata: Any.Type) throws(InferenceFailure) -> Convention {
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

    /// A field's storage in its parent.
    ///
    /// A field that is undecided on its own, such as a generic instance, is
    /// decided with its parent: only a parent whose static value witnesses
    /// certify everything it stores is loadable.
    private enum Part {
        case addressOnly
        /// The field's lowering if every value in it is frozen, or nil for a
        /// field with no bytes such as a thin metatype.
        case fixed(CValueType?)
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
        if info.metadataInitialization == 1 { return .addressOnly }
        // Only static value witnesses summarize the concrete fields; a generic
        // instance's come from its pattern.
        if !info.isGeneric, flags & nonBitwiseTakable != 0 { return .addressOnly }
        let module = ModuleContext(metadata)
        if info.isEnum, module.exportsEnumCases { return .addressOnly }
        let fields = try readFields(of: metadata, info: info)
        var parts: [CValueType?] = []
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
            guard case .fixed(let layout) = part else { return .addressOnly }
            parts.append(layout)
        }
        switch decide(metadata, info: info, flags: flags, fields: fields, module: module) {
        case .addressOnly:
            return .addressOnly
        case .loadable:
            return try .loadable(layout(of: metadata, info: info, fields: fields, parts: parts))
        case .undecided(let missing):
            let frozen = try layout(of: metadata, info: info, fields: fields, parts: parts)
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
        guard let type = field.type else { return try .fixed(pointer()) }
        if field.reference == ABISwiftReferenceStorageWeak { return .addressOnly }
        // An unowned reference is loadable when its referent uses native Swift
        // reference counting. Otherwise it is not bitwise-takable, which the
        // static value witnesses of a type that stores it show.
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
            return try .fixed(functionStorage(type))
        case .optional:
            let wrapped = (type as! any NativeOptionalValue.Type).wrappedType
            let part = try self.part(of: wrapped, genericDependent: genericDependent)
            guard case .fixed(let payload) = part else { return .addressOnly }
            let layout = try failing {
                try SwiftValueSchema.optionalStorage(
                    of: type,
                    wrapped: payload
                        ?? CValueType(swiftAggregate: [], offsets: [], size: 0, alignment: 1),
                    wrappedType: wrapped
                )
            }
            return .fixed(layout)
        case .tuple:
            return try tuplePart(type)
        case .metatype, .existentialMetatype, .extendedExistential:
            guard let metatype = SwiftMetatypeMetadata(type) else { return try codecPart(type) }
            // A field stores a concrete non-class metatype thin, in no bytes,
            // unless its declared type is generic.
            if metatype.isSingleton, !genericDependent { return .fixed(nil) }
            func thick<Value>(_: Value.Type) throws -> CValueType {
                try metatype.valueType(for: Value.self, thin: false)
            }
            return try .fixed(failing { try _openExistential(type, do: thick) })
        case .opaque:
            return try .fixed(builtinStorage(type))
        case .structure, .enumeration:
            guard lowersByInference(type) else { return try codecPart(type) }
            switch try convention(of: type) {
            case .addressOnly: return .addressOnly
            case .loadable(let layout), .undecided(let layout, _): return .fixed(layout)
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
            ? .addressOnly : .fixed(layout)
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
        for element in tuple.elements {
            guard case .fixed(let layout) = try part(of: element.type) else { return .addressOnly }
            layouts.append(layout)
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        let aggregate = try aggregate(
            layouts,
            offsets: tuple.elements.map(\.offset),
            size: layout.size,
            alignment: layout.alignment,
            of: type
        )
        return .fixed(aggregate)
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

    /// The value's lowering, assuming that it and every value it stores are frozen.
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

    // MARK: Decision

    private enum Decision {
        case loadable, addressOnly
        case undecided(String)
    }

    private enum Addressability {
        case no, yes, unknown
    }

    /// What the value's own static value witnesses and its module's exports
    /// decide, once none of its fields is address-only.
    private static func decide(
        _ metadata: Any.Type,
        info: ABISwiftValueDescriptorInfo,
        flags: UInt32,
        fields: [Field],
        module: ModuleContext
    ) -> Decision {
        let name = String(reflecting: metadata)
        let kind = info.isEnum ? "enum" : "struct"
        let moduleName = module.name.map { "module `\($0)`" } ?? "its module"
        guard !info.isGeneric else {
            return .undecided(
                "generic \(kind) `\(name)` has runtime-built metadata, whose value witnesses do not show whether it is resilient"
            )
        }
        if flags & addressableForDependencies != 0 {
            if let explanation = explanation(of: metadata, fields: fields) {
                return .undecided(
                    "\(explanation) its addressable-for-dependencies value-witness bit, so the bit does not show whether \(kind) `\(name)` is resilient"
                )
            }
            // Without library evolution, a stored property of an opaque type
            // can set the bit alone, so only library-evolution symbols show
            // that the type itself is resilient.
            if module.showsLibraryEvolution { return .addressOnly }
            let exports =
                module.image == nil
                ? "ABIBridge cannot read the exports of \(moduleName)"
                : "\(moduleName) exports no symbols that only library evolution emits"
            return .undecided(
                "none of the fields of \(kind) `\(name)` explains its addressable-for-dependencies value-witness bit, and \(exports), so the bit can come from a stored property of an opaque (`some`) type, which its field record describes by its underlying type, rather than from resilience"
            )
        }
        guard module.setsAddressableForDependencies else {
            return .undecided(
                "\(moduleName) never sets the addressable-for-dependencies value-witness bit, as Swift 6.1 and earlier compilers do not, so the bit does not show whether `\(name)` is resilient"
            )
        }
        return .loadable
    }

    /// What explains a set addressable-for-dependencies bit other than
    /// resilience, as the start of a sentence, or nil when nothing does.
    private static func explanation(of metadata: Any.Type, fields: [Field]) -> String? {
        if isSelfAddressable(metadata) {
            return "its own @_addressableForDependencies attribute explains"
        }
        let explained = fields.map { ($0, $0.type.map(addressability) ?? .no) }
        if let field = explained.first(where: { if case .yes = $0.1 { true } else { false } }) {
            return "its field \(field.0.description) explains"
        }
        if let field = explained.first(where: { if case .unknown = $0.1 { true } else { false } }) {
            return "its field \(field.0.description) has runtime-built metadata, which may explain"
        }
        return nil
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

/// The mangled declaration, such as `8ProbeLib5PointV`, under which the image
/// that defines a struct or enum exports the type's nominal type descriptor.
/// A runtime type name omits a constrained extension's generic signature,
/// which this declaration includes.
func swiftExportedTypeDeclaration(_ metadata: Any.Type) -> String? {
    ModuleContext.exportedDeclaration(of: metadata)
}

/// The image and module that declare a nominal type, and what they show.
private struct ModuleContext {
    let name: String?
    let image: RuntimeImage?
    /// The type's mangled declaration as its image exports the type's
    /// descriptor, or nil when the export trie does not show the descriptor.
    let declaration: String?
    /// Whether the image exports a symbol of the module's own declarations
    /// that only library evolution emits.
    let showsLibraryEvolution: Bool
    let setsAddressableForDependencies: Bool

    private struct Key: Hashable {
        let header: UInt
        let module: String
    }
    private struct Image: Sendable {
        let image: RuntimeImage?
    }
    private static let images = Mutex<[UInt: Image]>([:])
    private static let addressability = Mutex<[Key: Bool]>([:])

    init(_ metadata: Any.Type) {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        name = ABISwiftTypeModuleName(pointer).map { String(cString: $0) }
        guard let name, let descriptor = ABISwiftTypeDescriptor(pointer),
            let (header, image) = Self.image(defining: descriptor)
        else {
            image = nil; declaration = nil; showsLibraryEvolution = false
            setsAddressableForDependencies = false
            return
        }
        let key = Key(header: header, module: name)
        if let sets = Self.addressability.withLock({ $0[key] }) {
            setsAddressableForDependencies = sets
        } else {
            let sets = ABISwiftModuleSetsAddressableForDependencies(pointer)
            Self.addressability.withLock { $0[key] = sets }
            setsAddressableForDependencies = sets
        }
        self.image = image
        // A missing image leaves only metadata evidence.
        guard let image else {
            declaration = nil; showsLibraryEvolution = false
            return
        }
        showsLibraryEvolution =
            Self.mangledContext(ofModule: name).map {
                RuntimeSymbolResolver.shared.exportsSwiftLibraryEvolutionSymbols(
                    ofModule: $0,
                    named: name,
                    in: image
                )
            } ?? false
        declaration = RuntimeSymbolResolver.shared.exportedSwiftTypeDeclaration(
            at: UInt64(UInt(bitPattern: descriptor)),
            in: image
        )
    }

    /// Whether the image exports enum case symbols for the type's own cases,
    /// which only a resilient enum has.
    var exportsEnumCases: Bool {
        guard let image, let declaration else { return false }
        return RuntimeSymbolResolver.shared.exportsSwiftEnumCases(
            declaration: declaration,
            in: image
        )
    }

    /// The mangled declaration under which the image that defines a struct
    /// or enum exports the type's nominal type descriptor.
    static func exportedDeclaration(of metadata: Any.Type) -> String? {
        guard
            let descriptor = ABISwiftTypeDescriptor(
                unsafeBitCast(metadata, to: UnsafeRawPointer.self)
            ),
            let image = image(defining: descriptor)?.image
        else { return nil }
        return RuntimeSymbolResolver.shared.exportedSwiftTypeDeclaration(
            at: UInt64(UInt(bitPattern: descriptor)),
            in: image
        )
    }

    /// The header of the image that defines `descriptor`, and the image when
    /// ABIBridge can read its exports.
    private static func image(
        defining descriptor: UnsafeRawPointer
    ) -> (header: UInt, image: RuntimeImage?)? {
        var info = Dl_info()
        guard dladdr(descriptor, &info) != 0, let base = info.dli_fbase,
            let path = info.dli_fname
        else { return nil }
        let header = UInt(bitPattern: base)
        if let cached = images.withLock({ $0[header] }) { return (header, cached.image) }
        let image = Image(
            image: try? RuntimeImage.opening(path: String(cString: path), loading: .loadedOnly)
        )
        let cached = images.withLock { images in
            images[header] = images[header] ?? image
            return images[header]!
        }
        return (header, cached.image)
    }

    /// The module's context as it starts the module's own symbols: `s` for
    /// the standard library, otherwise the module's name as the first
    /// identifier of a mangling. A type's runtime name need not start with
    /// it: a type declared in an extension of another module's type starts
    /// with the extended type.
    ///
    /// A word of the name that repeats an earlier word is mangled as a
    /// letter. A word starts at a character other than a digit or `_`, and
    /// ends before `_` or an uppercase letter that follows a non-uppercase
    /// one. Names outside ASCII use Punycode, which this does not reproduce.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Demangling/ManglingUtils.h
    static func mangledContext(ofModule name: String) -> String? {
        if name == "Swift" { return "s" }
        let text = Array(name.utf8)
        func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        func isUpper(_ byte: UInt8) -> Bool { (65...90).contains(byte) }
        // Imported Clang modules have their own contexts.
        guard let first = text.first, !isDigit(first), name != "__C", name != "__C_Synthesized",
            text.allSatisfy({ $0 < 0x80 })
        else { return nil }
        var words: [Range<Int>] = []
        var substitutions: [(start: Int, word: Int?)] = []
        var start: Int?
        for position in 0...text.count {
            let byte = position < text.count ? text[position] : 0
            if let wordStart = start,
                byte == 95 || byte == 0 || (!isUpper(text[position - 1]) && isUpper(byte))
            {
                let word = text[wordStart..<position]
                if let index = words.firstIndex(where: { text[$0].elementsEqual(word) }) {
                    substitutions.append((wordStart, index))
                } else if word.count >= 2, words.count < 26 {
                    words.append(wordStart..<position)
                }
                start = nil
            }
            if start == nil, byte != 0, byte != 95, !isDigit(byte) { start = position }
        }
        guard !substitutions.isEmpty else { return "\(text.count)\(name)" }
        // Literal runs carry their lengths; the last substitution is uppercase.
        var mangled = "0"
        var position = 0
        substitutions.append((text.count, nil))
        for (index, substitution) in substitutions.enumerated() {
            if position < substitution.start {
                mangled += "\(substitution.start - position)"
                    + String(decoding: text[position..<substitution.start], as: UTF8.self)
                position = substitution.start
            }
            guard let word = substitution.word else { continue }
            position += words[word].count
            let last = index == substitutions.count - 2
            mangled.append(Character(Unicode.Scalar(UInt8((last ? 65 : 97) + word))))
            if last, position == text.count { mangled += "0" }
        }
        return mangled
    }
}
