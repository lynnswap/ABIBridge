/// One explicit argument in a Swift declaration's generic context.
///
/// Scalar type arguments may use linked metatypes or retained runtime type
/// handles. A pack supplies the ordered element types for one parameter pack.
public struct NativeSwiftGenericArgument: Sendable {
    enum Storage: Sendable {
        case type(Any.Type, owner: NativeSwiftType?)
        case pack([NativeSwiftGenericArgument])
    }
    let storage: Storage

    /// Binds an ordinary linked Swift type. Its implementation must remain loaded.
    public static func type(_ type: Any.Type) -> Self {
        Self(storage: .type(type, owner: nil))
    }

    /// Binds a runtime type and retains its metadata and implementation images.
    public static func type(_ type: NativeSwiftType) -> Self {
        Self(storage: .type(type.metadata, owner: type))
    }

    /// Binds one parameter pack. Each element is a scalar type argument.
    public static func pack(_ elements: [Self]) -> Self {
        Self(storage: .pack(elements))
    }
}
