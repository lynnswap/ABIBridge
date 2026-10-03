import ABIBridge
import SwiftUI

/// A SwiftUI view that owns a native opaque result and its implementation images.
///
/// Resolve a nongeneric native factory returning some View using
/// NativeSwiftValue, then pass its result to this initializer. The provider
/// module and concrete view type need not be importable by the consumer.
///
/// Construction and body evaluation occur on MainActor. The value does not
/// conform to Sendable: a hidden view can retain actor- or thread-bound state.
/// The native declaration's ABI, argument lifetimes, and isolation requirements
/// remain the caller's responsibility.
///
/// Copies share the result owner. Keep this view in the hierarchy or in its
/// hosting controller while native view code, witnesses, or destruction can run.
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
