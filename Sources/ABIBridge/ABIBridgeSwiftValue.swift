/// An imported Swift value with an explicitly established ABI convention.
///
/// The compiler initializes, copies, transfers, and destroys `Self` in its actual Swift storage. Supply scalar components and field offsets matching the target declaration's Swift calling convention; size alone does not establish compatibility.
///
/// Frozen structs and payload enums can use this contract when their lowering is known. An opaque `NativeType` selects a formally indirect convention, such as for an imported resilient value. `NativeType` uses C field placement, so flatten descriptions when Swift reuses a nested value's trailing padding. See <doc:ExplicitSwiftValues> for examples.
public protocol ABIBridgeSwiftValue: SendableMetatype {
    /// Fixed ABI components, or an opaque descriptor for formally indirect values.
    ///
    /// Keep this description stable for prepared handles. Storage size, stride, and alignment come from `Self`; the component aggregate may have different trailing padding and alignment. Its extent must cover `Self`'s size without exceeding its stride, and scalar fields must fit within its size.
    ///
    /// The descriptor does not validate field identity or the target declaration's ABI. An opaque descriptor selects indirection; its optional storage dimensions are unused because `Self` supplies them.
    static var swiftABIType: NativeType { get }
}
