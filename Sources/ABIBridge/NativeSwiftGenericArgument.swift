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

    indirect enum Identity: Hashable {
        case type(ObjectIdentifier)
        case pack([Identity])
    }

    var identity: Identity {
        switch storage {
        case .type(let type, _): .type(ObjectIdentifier(type))
        case .pack(let elements): .pack(elements.map(\.identity))
        }
    }

    // A cache entry made with bare metatypes must not discard owners supplied
    // by a later lookup of the same specialization.
    func retainsOwners(of other: Self) -> Bool {
        switch (storage, other.storage) {
        case (.type(_, let retained), .type(_, let incoming)):
            incoming == nil || retained != nil
        case (.pack(let retained), .pack(let incoming)):
            zip(retained, incoming).allSatisfy { $0.retainsOwners(of: $1) }
        default:
            false
        }
    }

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
