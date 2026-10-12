import ABIBridge
import SwiftUI

/// A SwiftUI view that retains a native opaque result and its implementation images.
///
/// Resolve a nongeneric factory returning `some View` as `NativeSwiftValue`, then pass its result to the initializer. The provider's module and concrete type need not be importable. The factory call must satisfy its native ABI, argument lifetime, and isolation requirements. See <doc:DisplayingNativeViews> for an example.
///
/// Construction and body evaluation run on MainActor. This value is not Sendable because hidden views may retain thread- or actor-bound state.
///
/// Copies share ownership. Keep the view or its host alive while native view code, witnesses, or destruction can run.
public nonisolated struct NativeSwiftView: View {
    private let storage: Storage

    /// Creates an owned, type-erased view from an opaque native result.
    ///
    /// - Parameter value: A live result whose underlying type conforms to View.
    /// - Throws: ABIInvocationError.incompatibleValue if the result is not a View.
    @MainActor public init(_ value: NativeSwiftValue) throws {
        let content = try value.withCopy { payload in
            guard let view = payload as? any View else {
                throw ABIInvocationError.incompatibleValue(
                    expected: "any SwiftUI.View", actual: String(reflecting: Swift.type(of: payload)))
            }
            return AnyView(view)
        }
        storage = Storage(owner: value, content: content)
    }

    /// The native view, erased through its compiler-provided View conformance.
    @MainActor public var body: some View { storage.content! }

    private final class Storage {
        let owner: NativeSwiftValue
        var content: AnyView?
        init(owner: NativeSwiftValue, content: AnyView) {
            self.owner = owner
            self.content = content
        }
        deinit {
            // The erased value can execute native destruction code. Explicitly
            // release it before the last implementation-image owner.
            withExtendedLifetime(owner) { content = nil }
        }
    }
}
