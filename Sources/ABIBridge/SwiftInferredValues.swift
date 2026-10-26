import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime
import Darwin
import Synchronization

/// Where a value occurs in a Swift signature.
///
/// Swift passes a whole parameter, result, typed error, or `self` indirectly
/// once its loadable lowering exceeds four registers. A value whose convention
/// is undecided but whose frozen lowering is already that large therefore has
/// one convention either way. Elsewhere, loadable and address-only values
/// differ.
enum SwiftValuePosition: Sendable, Equatable {
    case parameter
    /// A whole result, or a typed error, which Swift returns as it does a
    /// result.
    case result
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
/// inference decides only from records the compiler wrote and that are
/// present. Everything else stays undecided and fails:
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
///   symbols that only library evolution emits.
/// - A nongeneric type whose static value witnesses leave the bit clear is
///   loadable once a type of its module sets the bit, which Swift 6.1 and
///   earlier compilers never do, and when its fields explain whether its value
///   witnesses are POD: a `@sensitive` type is address-only, and only its
///   non-POD value witnesses show it. Its fields, including generic
///   instances, are decided with it.
/// - Otherwise, a nongeneric type whose fields explain whether its value
///   witnesses are POD, or a generic instance, is loadable when it is not
///   resilient, no stored property has an opaque type, and every field is
///   loadable on its own (``nonEvolutionGap(of:storedBy:)``). A generic
///   instance's fields come from its field records with its generic
///   arguments, and an unowned reference in it is address-only unless its
///   referent is a Swift class that uses native reference counting.
/// - Neither applies to a value that is, or stores, a value whose static
///   value witnesses leave the bit clear although a value it stores sets it.
///   Swift ORs the bit over stored values except for a `@sensitive` struct.
///
/// Missing symbols, the value witnesses of a generic instance, which the
/// runtime builds from field layouts or reuses from its pattern, and the
/// Swift class bit of an unowned referent are not evidence: each made a
/// resilient or address-only value look loadable.
///
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SIL/IR/TypeLowering.cpp
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenValueWitness.cpp
enum SwiftInferredValue {
    #if DEBUG
    @TaskLocal static var moduleImageLoader: (@Sendable (String) throws -> RuntimeImage)?
    @TaskLocal static var onClassification: (@Sendable (Any.Type) -> Void)?
    #endif
    @TaskLocal private static var currentMemo: InferenceMemo?

    fileprivate static func moduleImage(at path: String) throws -> RuntimeImage {
        #if DEBUG
        if let loader = moduleImageLoader { return try loader(path) }
        #endif
        return try RuntimeImage.opening(path: path, loading: .loadedOnly)
    }

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
            convention = try classification(of: metadata).convention
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
        func infers<Value>(_: Value.Type) -> Bool { SwiftValueSchema.infersLayout(Value.self) }
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

    private struct Classification: Sendable {
        let convention: Convention
        /// Whether a value it stores, at any depth, is not POD, as its field
        /// records show. A `@sensitive` type's own value witnesses are not
        /// POD even when its fields are.
        let storesNonPOD: Bool
        /// Whether the rules for modules built without library evolution
        /// decide the value: it is nongeneric, and its fields explain whether
        /// its value witnesses are POD.
        var followsNonEvolutionRules = false
        /// Whether it, or a value it stores, has static value witnesses that
        /// leave the addressable-for-dependencies bit clear although a value
        /// it stores sets the bit. Swift sets the bit for a value whenever a
        /// value it stores sets it, except for a `@sensitive` struct, which is
        /// address-only.
        var masksAddressability = false
    }

    private static let classifications = Mutex<[ObjectIdentifier: Classification]>([:])

    // Reuse inconclusive outcomes within a traversal, while later lookups can
    // retry them after missing image evidence becomes available.
    private final class InferenceMemo: Sendable {
        let classifications = Mutex<[ObjectIdentifier: Result<Classification, InferenceFailure>]>(
            [:])
        let nonEvolutionGaps = Mutex<[StoredKey: String]>([:])
    }

    /// Conclusive classifications are cached per metadata. Swift
    /// metadata stays valid because images with Swift metadata are not unloaded.
    private static func classification(
        of metadata: Any.Type
    ) throws(InferenceFailure) -> Classification {
        let key = ObjectIdentifier(metadata)
        if let cached = classifications.withLock({ $0[key] }) { return cached }
        guard let memo = currentMemo else {
            let result = $currentMemo.withValue(InferenceMemo()) {
                Result { () throws(InferenceFailure) -> Classification in
                    try Self.classification(of: metadata)
                }
            }
            return try result.get()
        }
        if let cached = memo.classifications.withLock({ $0[key] }) { return try cached.get() }
        // Fields classify recursively, so classify outside the lock.
        let result = Result { () throws(InferenceFailure) -> Classification in
            try classify(metadata)
        }
        memo.classifications.withLock { $0[key] = result }
        let classification = try result.get()
        // Missing image evidence can become available after initialization.
        guard case .undecided = classification.convention else {
            return classifications.withLock { classifications in
                classifications[key] = classifications[key] ?? classification
                return classifications[key]!
            }
        }
        return classification
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
        /// The field's lowering if every value in it is frozen, nil for a
        /// field with no bytes such as a thin metatype, whether a value in it
        /// is not POD, and whether a value in it masks the addressable-for-
        /// dependencies bit (``Classification/masksAddressability``).
        case fixed(CValueType?, nonPOD: Bool, masksAddressability: Bool = false)
    }

    // Value-witness flags (MetadataValues.h).
    private static let nonPOD: UInt32 = 0x0001_0000
    private static let nonBitwiseTakable: UInt32 = 0x0010_0000
    private static let nonCopyable: UInt32 = 0x0080_0000
    private static let addressableForDependencies: UInt32 = 0x0200_0000

    private static func classify(_ metadata: Any.Type) throws(InferenceFailure) -> Classification {
        #if DEBUG
        onClassification?(metadata)
        #endif
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
        let addressOnly = Classification(convention: .addressOnly, storesNonPOD: true)
        // Only static value witnesses summarize the concrete fields. The
        // runtime builds a generic instance's from field layouts, or reuses
        // its pattern's, which IRGen computed for the unsubstituted
        // declaration, so they are never read.
        let hasStaticWitnesses = !info.isGeneric
        // Runtime initialization lays out a resilient type from another module.
        if info.metadataInitialization == 1 { return addressOnly }
        if hasStaticWitnesses, flags & nonBitwiseTakable != 0 { return addressOnly }
        let module = ModuleContext(metadata)
        if info.isEnum, module.exportsEnumCases { return addressOnly }
        let fields = try readFields(of: metadata, info: info)
        var parts: [CValueType?] = []
        var storesNonPOD = false
        var masking: Field?
        var unknownReferent: Field?
        for field in fields {
            // A generic instance has no static value witnesses to show that an
            // unowned reference is not bitwise-takable, so its referent
            // decides.
            if info.isGeneric, field.reference == ABISwiftReferenceStorageUnowned,
                let type = field.type
            {
                switch unownedStorage(of: type) {
                case .pointer: break
                case .addressOnly: return addressOnly
                case .unknown: if unknownReferent == nil { unknownReferent = field }
                }
            }
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
            case .addressOnly: return addressOnly
            case .fixed(let layout, let nonPOD, let masks):
                parts.append(layout)
                storesNonPOD = storesNonPOD || nonPOD
                if masks, masking == nil { masking = field }
            }
        }
        // Swift sets the addressable-for-dependencies bit for a value whenever
        // a value it stores sets it, except for a @sensitive struct, which is
        // address-only. Only static value witnesses show the bit.
        let masked =
            hasStaticWitnesses && flags & addressableForDependencies == 0
            ? fields.first { $0.type.map(addressability)?.isSet == true } : nil
        let kind = info.isEnum ? "enum" : "struct"
        let decision =
            hasStaticWitnesses
            ? decide(
                metadata,
                info: info,
                flags: flags,
                fields: fields,
                storesNonPOD: storesNonPOD,
                module: module
            )
            : .undecided(
                "generic \(kind) `\(String(reflecting: metadata))` has runtime-built metadata, whose value witnesses do not show whether it is resilient"
            )
        // A @sensitive struct is address-only, and only its non-POD static
        // value witnesses show it. Nothing shows it for a generic struct.
        let followsNonEvolutionRules =
            unknownReferent == nil
            && (!hasStaticWitnesses || flags & nonPOD == 0 || storesNonPOD)
        let convention: Convention
        switch decision {
        case .addressOnly: return addressOnly
        case _ where masked != nil || masking != nil:
            let detail =
                masked.map {
                    "the value witnesses of \(kind) `\(String(reflecting: metadata))` leave the addressable-for-dependencies bit clear although its field \($0.description) sets it, as a @sensitive struct's do, which is address-only"
                }
                ?? "its field \(masking!.description) stores a value whose value witnesses leave the addressable-for-dependencies bit clear although a value it stores sets it, as a @sensitive struct's do, which is address-only"
            var classification = Classification(
                convention: .undecided(
                    frozen: try layout(of: metadata, info: info, fields: fields, parts: parts),
                    missing: detail
                ),
                storesNonPOD: storesNonPOD
            )
            classification.masksAddressability = true
            return classification
        case .loadable:
            convention = try .loadable(layout(of: metadata, info: info, fields: fields, parts: parts))
        case .undecided(let missing):
            let frozen = try layout(of: metadata, info: info, fields: fields, parts: parts)
            if let unknownReferent {
                convention = .undecided(
                    frozen: frozen,
                    missing: missing
                        + "; nothing shows how its field \(unknownReferent.description) counts references to its referent, which decides whether an unowned reference is address-only"
                )
            } else if !followsNonEvolutionRules {
                convention = .undecided(frozen: frozen, missing: missing)
            } else if let gap = nonEvolutionGap(of: metadata, storedBy: []) {
                convention = .undecided(frozen: frozen, missing: missing + "; " + gap)
            } else {
                convention = .loadable(frozen)
            }
        }
        var classification = Classification(convention: convention, storesNonPOD: storesNonPOD)
        classification.followsNonEvolutionRules = followsNonEvolutionRules
        return classification
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
        guard let type = field.type else { return try .fixed(pointer(), nonPOD: true) }
        switch field.reference {
        case ABISwiftReferenceStorageWeak:
            return .addressOnly
        case ABISwiftReferenceStorageUnmanaged:
            // unowned(unsafe) stores its referent's bits without counting them.
            guard case .fixed(let layout, _, _) = try part(of: type) else { return .addressOnly }
            return .fixed(layout, nonPOD: false)
        default:
            // An unowned reference is loadable when its referent uses native
            // Swift reference counting. Otherwise it is not bitwise-takable,
            // which the static value witnesses of a type that stores it show;
            // ``classify(_:)`` reads a generic instance's referents instead.
            return try part(of: type, genericDependent: field.genericDependent)
        }
    }

    private enum UnownedStorage {
        case pointer, addressOnly, unknown
    }

    /// How a value stores an unowned reference to `referent`: as a pointer
    /// when the referent is a Swift class that uses native Swift reference
    /// counting, and address-only when it is another class, or an
    /// existential that is class-bound without a superclass, whose reference
    /// counting is unknown. Any other referent is unknown.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/AST/Type.cpp
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenMeta.cpp
    private static func unownedStorage(of referent: Any.Type) -> UnownedStorage {
        let metadata = unsafeBitCast(referent, to: UnsafeRawPointer.self)
        let kind = metadata.load(as: UInt.self)
        switch kind {
        // An Objective-C class wrapper.
        case 0x305:
            return .addressOnly
        case 0x303:
            // ExistentialTypeFlags: a clear class constraint bit means
            // class-bound; the next bit announces a superclass.
            let flags = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: UInt32.self)
            return flags & 0xc000_0000 == 0 ? .addressOnly : .unknown
        default:
            // Class metadata starts with an isa pointer, above every other
            // kind, and only a Swift class has a nominal type descriptor.
            // Its ClassFlags follow the superclass, the cache, and the data.
            guard kind > 0x7ff, ABISwiftTypeDescriptor(metadata) != nil else { return .unknown }
            let flags = metadata.load(
                fromByteOffset: 5 * MemoryLayout<UInt>.size,
                as: UInt32.self
            )
            // ClassFlags::UsesSwiftRefcounting
            return flags & 0x2 != 0 ? .pointer : .addressOnly
        }
    }

    private static func part(
        of type: Any.Type,
        genericDependent: Bool = false
    ) throws(InferenceFailure)
        -> Part
    {
        switch runtimeMetadataKind(type) {
        case .function:
            return try .fixed(functionStorage(type), nonPOD: witnessesAreNonPOD(type))
        case .optional:
            let wrapped = (type as! any NativeOptionalValue.Type).wrappedType
            let part = try self.part(of: wrapped, genericDependent: genericDependent)
            guard case .fixed(let payload, let nonPOD, let masks) = part else { return .addressOnly }
            let layout = try failing {
                try SwiftValueSchema.optionalStorage(
                    of: type,
                    wrapped: payload
                        ?? CValueType(swiftAggregate: [], offsets: [], size: 0, alignment: 1),
                    wrappedType: wrapped
                )
            }
            return .fixed(layout, nonPOD: nonPOD, masksAddressability: masks)
        case .tuple:
            return try tuplePart(type)
        case .metatype, .existentialMetatype, .extendedExistential:
            guard let metatype = SwiftMetatypeMetadata(type) else { return try codecPart(type) }
            // A field stores a concrete non-class metatype thin, in no bytes,
            // unless its declared type is generic.
            if metatype.isSingleton, !genericDependent { return .fixed(nil, nonPOD: false) }
            func thick<Value>(_: Value.Type) throws -> CValueType {
                try metatype.valueType(for: Value.self, thin: false)
            }
            return try .fixed(failing { try _openExistential(type, do: thick) }, nonPOD: false)
        case .opaque:
            return try .fixed(builtinStorage(type), nonPOD: witnessesAreNonPOD(type))
        case .structure, .enumeration:
            guard lowersByInference(type) else { return try codecPart(type) }
            let classification = try self.classification(of: type)
            switch classification.convention {
            case .addressOnly:
                return .addressOnly
            case .loadable(let layout), .undecided(let layout, _):
                return .fixed(
                    layout,
                    nonPOD: classification.storesNonPOD,
                    masksAddressability: classification.masksAddressability
                )
            }
        default:
            return try codecPart(type)
        }
    }

    private static func witnessesAreNonPOD(_ type: Any.Type) -> Bool {
        ABISwiftGetValueWitnessFlags(unsafeBitCast(type, to: UnsafeRawPointer.self)) & nonPOD != 0
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

    /// Classes, existentials, and values with built-in representations keep
    /// the storage of their own schema.
    private static func codecPart(_ type: Any.Type) throws(InferenceFailure) -> Part {
        let schema = try failing { try SwiftValueSchema(host: type, position: .nested) }
        // A value that converts has a native type other than its host type.
        guard schema.metadata == type else {
            throw InferenceFailure(
                unsupported: true,
                detail: "\(String(reflecting: type)) converts to a foreign representation"
            )
        }
        let layout = schema.type
        return withExtendedLifetime(layout, { ABISwiftValueIsAddressOnly(layout.handle) })
            ? .addressOnly : .fixed(layout, nonPOD: witnessesAreNonPOD(type))
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
        var storesNonPOD = false
        var masksAddressability = false
        for element in tuple.elements {
            guard case .fixed(let layout, let nonPOD, let masks) = try part(of: element.type)
            else { return .addressOnly }
            layouts.append(layout)
            storesNonPOD = storesNonPOD || nonPOD
            masksAddressability = masksAddressability || masks
        }
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        let aggregate = try aggregate(
            layouts,
            offsets: tuple.elements.map(\.offset),
            size: layout.size,
            alignment: layout.alignment,
            of: type
        )
        return .fixed(aggregate, nonPOD: storesNonPOD, masksAddressability: masksAddressability)
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
        // An enum without bytes, such as one with a single case and no
        // payload, passes nothing.
        if layout.size == 0 {
            return try aggregate([], offsets: [], size: 0, alignment: layout.alignment, of: metadata)
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

    /// Whether Swift's lowering of a type sets the addressable-for-
    /// dependencies bit, as the records that ABIBridge reads show.
    enum Addressability: Sendable, Equatable {
        case clear
        /// The bit is set; the clause names the type that sets it and how.
        case sets(String)
        /// Nothing shows whether the bit is set; the clause says why.
        case unknown(String)

        var isSet: Bool {
            if case .sets = self { return true }
            return false
        }
    }

    /// What the value's own static value witnesses and its module's exports
    /// decide, once none of its fields is address-only.
    private static func decide(
        _ metadata: Any.Type,
        info: ABISwiftValueDescriptorInfo,
        flags: UInt32,
        fields: [Field],
        storesNonPOD: Bool,
        module: ModuleContext
    ) -> Decision {
        let name = String(reflecting: metadata)
        let kind = info.isEnum ? "enum" : "struct"
        let moduleName = module.name.map { "module `\($0)`" } ?? "its module"
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
        // A @sensitive type is address-only, and only its non-POD value
        // witnesses show it.
        if flags & nonPOD != 0, !storesNonPOD {
            return .undecided(
                "the value witnesses of \(kind) `\(name)` are not POD, although none of its fields needs nontrivial copies or destruction, as for a @sensitive type, which is address-only"
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
        let explained = fields.map { ($0, $0.type.map(addressability) ?? .clear) }
        if let field = explained.first(where: { $0.1.isSet }) {
            return "its field \(field.0.description) explains"
        }
        if let field = explained.first(where: { if case .unknown = $0.1 { true } else { false } }) {
            return "its field \(field.0.description) has runtime-built metadata, which may explain"
        }
        return nil
    }

    /// Whether Swift's lowering of `type` sets the addressable-for-
    /// dependencies bit: a field with the bit explains its parent's bit, and
    /// Swift passes an input with it by address where a result borrows from
    /// the input.
    ///
    /// Only static value witnesses from a module that sets the bit for some
    /// type show it; the runtime builds a generic instance's. Swift sets it
    /// for `String`, for `@_addressableForDependencies` declarations, and for
    /// imported C structs and unions, and never for imported C enums,
    /// references, closures, existentials, metatypes, pointers, or
    /// collections, which store their values out of line.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SIL/IR/TypeLowering.cpp
    static func addressability(of type: Any.Type) -> Addressability {
        switch runtimeMetadataKind(type) {
        case .optional:
            return addressability(of: (type as! any NativeOptionalValue.Type).wrappedType)
        case .tuple:
            let elements = SwiftTupleMetadata(type)!.elements.map { addressability(of: $0.type) }
            return elements.first(where: \.isSet) ?? elements.first { $0 != .clear } ?? .clear
        case .structure, .enumeration:
            break
        default:
            // References, closures, existentials, metatypes, and builtins.
            return .clear
        }
        let name = "`\(String(reflecting: type))`"
        if type == String.self { return .sets("\(name) sets it") }
        if isSelfAddressable(type) {
            return .sets("\(name) sets it through its @_addressableForDependencies attribute")
        }
        if type is any SwiftCollectionValue.Type || type is any NativePointerValue.Type
            || type == Bool.self
        {
            return .clear
        }
        func scalar<Value>(_: Value.Type) -> Bool { CValueCodec<Value>.isScalar }
        if _openExistential(type, do: scalar) { return .clear }
        let pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
        var info = ABISwiftValueDescriptorInfo()
        guard ABISwiftGetValueDescriptorInfo(pointer, &info) else {
            return .unknown("ABIBridge cannot read the nominal type descriptor of \(name)")
        }
        if info.metadataInitialization == 2 {
            // Swift sets the bit for an imported C struct or union, and never
            // for an imported C enum, which its descriptor's kind shows unless
            // the importer made the enum a struct, as for an option set. Each
            // client emits an imported type's metadata, so its clear bit can
            // come from a compiler that never sets the bit.
            if info.isEnum { return .clear }
            if ABISwiftGetValueWitnessFlags(pointer) & addressableForDependencies != 0 {
                return .sets(
                    "the value witnesses of \(name), an imported C struct or union, set it"
                )
            }
            return .unknown(
                "the value witnesses of \(name), an imported C type, leave it clear, but its records do not show whether it imports a C struct or union, whose metadata a compiler that never sets the bit can emit, or another C type, such as an enum imported as a struct"
            )
        }
        if info.isGeneric {
            return .unknown(
                "\(name) is a generic instance, whose value witnesses the runtime builds, so they do not show the bit"
            )
        }
        if info.metadataInitialization != 0 {
            return .unknown(
                "the runtime initializes the metadata of \(name), so its value witnesses do not show the bit"
            )
        }
        // Only static metadata from a module known to set the bit carries it.
        let module = ModuleContext(type)
        guard module.setsAddressableForDependencies else {
            let moduleName = module.name.map { "module `\($0)`" } ?? "its module"
            return .unknown(
                "\(moduleName) never sets the bit, as Swift 6.1 and earlier compilers do not, so the clear bit of \(name) does not show it"
            )
        }
        return ABISwiftGetValueWitnessFlags(pointer) & addressableForDependencies != 0
            ? .sets("the static value witnesses of \(name) set it") : .clear
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

    // MARK: Modules built without library evolution

    private struct StoredKey: Hashable {
        let metadata: ObjectIdentifier
        let parents: Set<String>
    }

    private static let loadableContexts = Mutex<Set<StoredKey>>([])

    /// Why the records of a nongeneric struct or enum of a module built
    /// without library evolution leave it undecided where values of the
    /// modules `parents` store it, or nil when they make it loadable. Its
    /// fields must explain whether its value witnesses are POD, which
    /// ``classify(_:)`` checks.
    ///
    /// The value is not resilient when one of these holds:
    ///
    /// - Its image holds a trivial property descriptor for a stored `var` of
    ///   a struct or class of its module. Library evolution never gives a
    ///   stored `var` one; without it, Swift 6.0 and later give one to every
    ///   stored property with a descriptor.
    /// - A value of another module stores it, at any depth, through values
    ///   whose metadata needs no runtime initialization. That value's
    ///   compiler laid out every type it stores from another module, which a
    ///   resilient type would prevent.
    ///
    /// A field record holds the underlying type of a stored property of an
    /// opaque type (`some P`), which can make the value address-only. Such a
    /// property cannot take another declaration's opaque type, so a symbol
    /// that spells a property's declared type shows whether it is opaque: a
    /// property descriptor, an accessor, or a variable initializer. Every
    /// stored property of a struct needs one, at every depth. Enum payloads
    /// cannot be opaque.
    ///
    /// Each field must then be loadable on its own, where `parents` and the
    /// value's module store it. A static value proves only that the types it
    /// stores from other modules are not resilient, not that their stored
    /// properties are not opaque, nor anything about its own module's types.
    ///
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SILGen/SILGen.cpp
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenReflection.cpp
    private static func nonEvolutionGap(
        of metadata: Any.Type,
        storedBy parents: Set<String>
    ) -> String? {
        let key = StoredKey(metadata: ObjectIdentifier(metadata), parents: parents)
        if loadableContexts.withLock({ $0.contains(key) }) { return nil }
        if let cached = currentMemo?.nonEvolutionGaps.withLock({ $0[key] }) { return cached }
        if let gap = findNonEvolutionGap(of: metadata, storedBy: parents) {
            currentMemo?.nonEvolutionGaps.withLock { $0[key] = gap }
            return gap
        }
        loadableContexts.withLock { _ = $0.insert(key) }
        return nil
    }

    private static func findNonEvolutionGap(
        of metadata: Any.Type,
        storedBy parents: Set<String>
    ) -> String? {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        var info = ABISwiftValueDescriptorInfo()
        guard ABISwiftGetValueDescriptorInfo(pointer, &info),
            let fields = try? readFields(of: metadata, info: info)
        else { return "its field records cannot be read" }
        let module = ModuleContext(metadata)
        guard let name = module.name else { return "its module is unknown" }
        guard let image = module.image else {
            return "ABIBridge cannot read the symbols of the image that declares it"
        }
        if !parents.contains(where: { $0 != name }),
            !RuntimeSymbolResolver.shared.hasTrivialStoredVariableDescriptor(
                declaredBy: name,
                in: image
            )
        {
            return "no trivial property descriptor of a stored `var` in its image shows that module `\(name)` is built without library evolution"
        }
        if !info.isEnum {
            let declared =
                module.descriptor.map {
                    RuntimeSymbolResolver.shared.swiftPropertyDeclarations(
                        ofTypeAt: UInt64(UInt(bitPattern: $0)),
                        in: image
                    )
                } ?? [:]
            for field in fields {
                guard let opaque = declared[field.name] else {
                    return "no symbol in its image spells the declared type of its stored property `\(field.name)`, which could be opaque"
                }
                if opaque {
                    return "its stored property `\(field.name)` has an opaque (`some`) type, which its field record describes by its underlying type"
                }
            }
        }
        // A nongeneric value's metadata is static, because runtime
        // initialization makes it address-only, and shows that the types it
        // stores from other modules are not resilient. The runtime lays out a
        // generic instance, which shows nothing.
        let inner = info.isGeneric ? parents : parents.union([name])
        for field in fields {
            if let gap = field.type.flatMap({ nonEvolutionGap(ofField: $0, storedBy: inner) }) {
                return "its field \(field.description) is not decided: \(gap)"
            }
        }
        return nil
    }

    /// Why a field of `type` is not loadable on its own where values of the
    /// modules `parents` store it, or nil when it is. Values with built-in
    /// representations, references, closures, existentials, and metatypes
    /// are; an address-only field already makes its parent address-only.
    private static func nonEvolutionGap(
        ofField type: Any.Type,
        storedBy parents: Set<String>
    ) -> String? {
        switch runtimeMetadataKind(type) {
        case .optional:
            return nonEvolutionGap(
                ofField: (type as! any NativeOptionalValue.Type).wrappedType,
                storedBy: parents
            )
        case .tuple:
            return SwiftTupleMetadata(type)!.elements.lazy.compactMap {
                nonEvolutionGap(ofField: $0.type, storedBy: parents)
            }.first
        case .structure, .enumeration:
            guard lowersByInference(type) else { return nil }
            let classification: Classification
            do throws(InferenceFailure) {
                classification = try self.classification(of: type)
            } catch {
                return error.detail
            }
            switch classification.convention {
            case .loadable:
                return nil
            case .addressOnly:
                return "it is address-only"
            case .undecided(_, let missing):
                guard classification.followsNonEvolutionRules else { return missing }
                return nonEvolutionGap(of: type, storedBy: parents)
            }
        default:
            return nil
        }
    }
}

// MARK: Module evidence

/// The mangled declaration, such as `8ProbeLib1P33_…LLV`, under which the
/// image that defines a struct or enum names the type's nominal type
/// descriptor, in its exports or its symbol table. Only local symbols name a
/// type that the image does not export, such as a private or local type,
/// whose declaration has a private or local discriminator that its runtime
/// name omits, or an internal type in an extension of a generic type, whose
/// declaration has the extension's generic signature.
func swiftTypeDeclarationFromSymbols(_ metadata: Any.Type) -> String? {
    ModuleContext.descriptorDeclaration(of: metadata)
}

/// The image and module that declare a nominal type, and what they show.
private struct ModuleContext {
    let name: String?
    let image: RuntimeImage?
    /// The type's nominal type descriptor.
    let descriptor: UnsafeRawPointer?
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
    private static let images = Mutex<[UInt: RuntimeImage]>([:])
    private static let addressability = Mutex<[Key: Bool]>([:])

    init(_ metadata: Any.Type) {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        name = ABISwiftTypeModuleName(pointer).map { String(cString: $0) }
        descriptor = ABISwiftTypeDescriptor(pointer)
        guard let name, let descriptor,
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
    /// or enum names the type's nominal type descriptor, in its exports or
    /// its symbol table.
    static func descriptorDeclaration(of metadata: Any.Type) -> String? {
        guard
            let descriptor = ABISwiftTypeDescriptor(
                unsafeBitCast(metadata, to: UnsafeRawPointer.self)
            ),
            let image = image(defining: descriptor)?.image
        else { return nil }
        return RuntimeSymbolResolver.shared.swiftTypeDeclaration(
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
        if let cached = images.withLock({ $0[header] }) { return (header, cached) }
        guard let image = try? SwiftInferredValue.moduleImage(at: String(cString: path)) else {
            return (header, nil)
        }
        let cached = images.withLock { images in
            images[header] = images[header] ?? image
            return images[header]!
        }
        return (header, cached)
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
