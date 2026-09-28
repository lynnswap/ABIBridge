import ABIBridgeCore
import Foundation

/// An owned error thrown by a native Swift implementation.
///
/// The wrapper preserves the original Swift error and the resolved code owners
/// needed while inspecting or destroying it. Bridge lookup/conversion failures
/// remain their original error types.
public final class NativeSwiftError: Error, @unchecked Sendable, CustomStringConvertible, LocalizedError {
    // The value is immutable until final destruction. Owners are immutable
    // image/implementation leases, never receiver or temporary call storage.
    private var value: (any Error)?
    private let codeOwner: Any?

    init(_ value: any Error, retainingCode owner: Any?) {
        self.value = value
        codeOwner = owner
    }

    /// Inspects the original error while retaining its resolved implementation.
    ///
    /// Values that escape the body and still depend on foreign code must keep
    /// this wrapper alive. The body may cast the error to its imported Swift type.
    public func withUnderlyingError<Result>(_ body: (any Error) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) { try body(value!) }
    }

    /// The original error's description.
    public var description: String { withUnderlyingError { String(describing: $0) } }

    /// The original error's localized description.
    public var errorDescription: String? { withUnderlyingError { ($0 as NSError).localizedDescription } }

    deinit { withExtendedLifetime(codeOwner) { value = nil } }
}

struct SwiftErrorPlan: Sendable {
    let type: CValueType
    let isTyped: Bool
    let identity: ObjectIdentifier
    let makeStorage: @Sendable () -> NativeValueStorage
    let decode: @Sendable (NativeValueStorage) throws -> any Error

    static func validateReplacement(_ replacement: SwiftErrorPlan?, for original: SwiftErrorPlan?) throws {
        guard replacement == nil || original?.identity == replacement?.identity else {
            throw ABIResolutionError.signatureMismatch(
                expected: "A replacement with the same native error type, or a nonthrowing replacement", found: []
            )
        }
    }

    static func make<Failure: Error>(_ failure: Failure.Type) throws -> Self? {
        if Failure.self == Never.self { return nil }
        return try Self(failure)
    }

    private init<Failure: Error>(_ failure: Failure.Type) throws {
        identity = ObjectIdentifier(Failure.self)
        isTyped = Failure.self != (any Error).self
        if !isTyped {
            type = try CValueType(scalar: ABIValuePointer)
            makeStorage = { NativeValueStorage(size: MemoryLayout<Failure>.stride,
                                               alignment: MemoryLayout<Failure>.alignment) }
            decode = { $0.take(as: Failure.self) }
        } else {
            let base = (Failure.self as? any NativeOptionalValue.Type)?.wrappedType ?? Failure.self
            guard !(base is any ABIBridgeValue.Type) || Failure.self is any ABIBridgeSwiftValue.Type else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Typed native errors need their actual Swift representation; foreign conversion adapters are not supported."
                )
            }
            let codec = try SwiftValueCodec<Failure>()
            type = codec.type
            makeStorage = { codec.makeStorage() }
            decode = { try codec.decode($0, retaining: nil) }
        }
    }
}
