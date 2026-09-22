import ABIBridgeCore

/// A native value's storage layout and, when available, its C ABI representation.
///
/// Names describe the intended foreign type. They do not prove its layout or
/// ownership. Use field descriptions for C-compatible aggregates; an opaque
/// byte size alone does not determine a function's calling convention.
public struct NativeType: Sendable, Hashable {
    /// One naturally laid-out C aggregate field.
    public struct Field: Sendable, Hashable {
        /// The field's value representation.
        public let type: NativeType
        /// The field's byte offset from the aggregate's start.
        public let offset: Int
    }

    private enum Representation: Sendable, Hashable {
        case scalar(Int), boolean, structure, opaque
    }

    /// A diagnostic name for this representation.
    public let name: String
    /// The number of accessible bytes described by this layout.
    public let size: Int
    /// The required storage alignment, in bytes.
    public let alignment: Int
    /// Field layouts for a C-compatible structure; empty for other types.
    public let fields: [Field]

    private let representation: Representation
    let cType: CValueType?

    private init(name: String, representation: Representation, cType: CValueType,
                 fields: [Field] = []) {
        self.name = name
        self.representation = representation
        self.cType = cType
        size = cType.size
        alignment = cType.alignment
        self.fields = fields
    }

    private init(name: String, size: Int, alignment: Int) {
        self.name = name
        self.size = size
        self.alignment = alignment
        representation = .opaque
        cType = nil
        fields = []
    }

    // These fixed constants are accepted by the internal scalar-type API.
    private static func scalar(_ kind: Int, named name: String) -> Self {
        .init(name: name, representation: .scalar(kind), cType: try! CValueType(scalar: kind))
    }

    /// No result value; not a valid explicit C parameter or structure field.
    public static let void = scalar(ABIValueVoid, named: "void")
    /// A C Boolean, represented by a canonical zero or one byte.
    public static let bool = Self(name: "bool", representation: .boolean,
                                  cType: try! CValueType(scalar: ABIValueUInt8))
    /// A signed 8-bit integer.
    public static let int8 = scalar(ABIValueInt8, named: "int8_t")
    /// An unsigned 8-bit integer.
    public static let uint8 = scalar(ABIValueUInt8, named: "uint8_t")
    /// A signed 16-bit integer.
    public static let int16 = scalar(ABIValueInt16, named: "int16_t")
    /// An unsigned 16-bit integer.
    public static let uint16 = scalar(ABIValueUInt16, named: "uint16_t")
    /// A signed 32-bit integer.
    public static let int32 = scalar(ABIValueInt32, named: "int32_t")
    /// An unsigned 32-bit integer.
    public static let uint32 = scalar(ABIValueUInt32, named: "uint32_t")
    /// A signed 64-bit integer.
    public static let int64 = scalar(ABIValueInt64, named: "int64_t")
    /// An unsigned 64-bit integer.
    public static let uint64 = scalar(ABIValueUInt64, named: "uint64_t")
    /// A pointer-sized signed integer.
    public static let int = MemoryLayout<Int>.size == 8 ? int64 : int32
    /// A pointer-sized unsigned integer.
    public static let uint = MemoryLayout<UInt>.size == 8 ? uint64 : uint32
    /// A C float.
    public static let float = scalar(ABIValueFloat, named: "float")
    /// A C double.
    public static let double = scalar(ABIValueDouble, named: "double")
    /// A pointer value; this does not describe or own its pointee.
    public static let pointer = scalar(ABIValuePointer, named: "void*")

    /// Creates a naturally laid-out C-compatible structure.
    ///
    /// - Parameters:
    ///   - name: A diagnostic foreign type name.
    ///   - fields: Field representations in declaration order.
    /// - Returns: The size, alignment, and offsets computed for the platform C ABI.
    /// - Throws: An error for empty structures, void fields, or fields without a
    ///   C representation. Packed, union, and nontrivial layouts need an adapter.
    public static func structure(named name: String, fields: [NativeType]) throws -> Self {
        let types = try fields.map { try $0.requireCType() }
        let cType = try CValueType(fields: types)
        let layouts = fields.enumerated().map {
            Field(type: $0.element, offset: ABIValueTypeFieldOffset(cType.handle, $0.offset))
        }
        // Field extents must fit the Swift-addressable storage even when a
        // synthetic aggregate overflows libffi's unsigned layout arithmetic.
        guard cType.size >= 0, layouts.allSatisfy({
            $0.offset >= 0 && $0.offset <= cType.size && $0.type.size <= cType.size - $0.offset
        }) else {
            throw NativeValueError.invalidLayout(size: cType.size, alignment: cType.alignment)
        }
        return .init(name: name, representation: .structure, cType: cType, fields: layouts)
    }

    /// Describes storage whose C ABI representation is unavailable.
    ///
    /// Opaque storage can be owned, borrowed, and accessed by an adapter. It
    /// cannot be passed by value through a C call interface. A zero-byte extent
    /// can represent an opaque resource whose address is used only as a pointer.
    ///
    /// - Parameters:
    ///   - name: A diagnostic foreign type name.
    ///   - size: The known accessible byte extent, defaulting to zero.
    ///   - alignment: A positive power of two, defaulting to one.
    /// - Returns: An opaque storage description.
    /// - Throws: A value error for a negative size or invalid alignment.
    public static func opaque(named name: String, size: Int = 0, alignment: Int = 1) throws -> Self {
        guard size >= 0, alignment > 0, alignment.nonzeroBitCount == 1 else {
            throw NativeValueError.invalidLayout(size: size, alignment: alignment)
        }
        return .init(name: name, size: size, alignment: alignment)
    }

    func requireCType() throws -> CValueType {
        guard let cType else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Opaque storage \(name) needs a C-compatible adapter before by-value invocation."
            )
        }
        return cType
    }

    var isPointer: Bool { representation == .scalar(ABIValuePointer) }

    func matchesLayout(of other: Self) -> Bool {
        representation == other.representation && size == other.size && alignment == other.alignment
            && fields.count == other.fields.count
            && zip(fields, other.fields).allSatisfy {
                $0.offset == $1.offset && $0.type.matchesLayout(of: $1.type)
            }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.representation == rhs.representation
            && lhs.size == rhs.size && lhs.alignment == rhs.alignment && lhs.fields == rhs.fields
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(representation)
        hasher.combine(size)
        hasher.combine(alignment)
        hasher.combine(fields)
    }
}

/// A runtime-known fixed signature for a C-compatible call.
///
/// Use function-type metatypes for ordinary typed calls. This description is
/// useful when an adapter discovers value layouts at runtime.
public struct NativeSignature: Sendable, Hashable {
    /// Explicit parameter representations in declaration order.
    public let parameters: [NativeType]
    /// The result representation, including void.
    public let result: NativeType

    /// Describes a fixed signature without preparing or invoking a function.
    ///
    /// - Parameters:
    ///   - parameters: Explicit parameter representations.
    ///   - result: The result representation.
    public init(parameters: [NativeType], returns result: NativeType) {
        self.parameters = parameters
        self.result = result
    }
}
