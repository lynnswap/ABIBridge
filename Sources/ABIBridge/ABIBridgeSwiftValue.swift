/// An imported Swift value with an explicitly established ABI convention.
///
/// The Swift frontend uses the compiler to initialize, copy, transfer, and
/// destroy Self. Unlike ABIBridgeValue, this conformance describes Self's actual
/// Swift storage and does not convert a foreign value into a different wrapper.
///
/// Supply a layout whose scalar components and field offsets match the target
/// declaration's Swift calling convention. A matching size alone does not prove
/// that convention. Frozen structs and payload enums can use this contract when
/// their lowering is known. Use an opaque NativeType to declare a formally
/// indirect argument/result convention, such as an imported resilient value.
///
/// For example, a frozen struct containing one object reference followed by an
/// Int64 can describe pointer and Int64 fields without implementing ARC manually.
/// NativeType uses C field placement, so flatten descriptions when Swift reuses
/// a nested value's trailing padding. See <doc:ExplicitSwiftValues>.
public protocol ABIBridgeSwiftValue: SendableMetatype {
    /// Fixed ABI components, or an opaque descriptor for formally indirect values.
    ///
    /// This component description must remain stable for prepared handles.
    /// Storage size, stride, and alignment come from Self; the component
    /// aggregate may have different trailing padding and alignment.
    /// Its extent must cover Self's size without exceeding its stride, and
    /// scalar fields must fit Self's size. The descriptor does not establish
    /// field identity or validate the target declaration's ABI. An opaque
    /// descriptor selects indirection; its optional storage dimensions are
    /// unused because Self supplies the actual live storage dimensions.
    static var swiftABIType: NativeType { get }
}
