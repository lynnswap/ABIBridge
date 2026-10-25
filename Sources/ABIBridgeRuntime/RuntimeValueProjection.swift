import ABIBridgeCore
import ABIBridgeCore.Backend

package struct RuntimeEnumMetadata {
    package struct Case {
        package let name: String
        package let hasPayload: Bool
        package let isIndirect: Bool
    }

    private let metadata: UnsafeRawPointer
    package let cases: [Case]

    package init(_ type: Any.Type) throws {
        let nativeMetadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        metadata = nativeMetadata
        let kind = nativeMetadata.load(as: UInt.self)
        guard kind == 0x201 || kind == 0x202 else {
            throw RuntimeResolutionError.unsupportedDeclaration("The runtime value is not an enum.")
        }
        let count = ABISwiftTypeFieldCount(nativeMetadata)
        guard count != 0 else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum's case field metadata is unavailable."
            )
        }
        cases = try (0..<count).map { index in
            var info = ABISwiftEnumCaseInfo()
            guard ABISwiftGetEnumCaseInfo(nativeMetadata, index, &info), let name = info.name else {
                throw RuntimeResolutionError.metadataUnavailable(
                    "The enum's case name is unavailable."
                )
            }
            return Case(
                name: String(cString: name),
                hasPayload: info.hasPayload,
                isIndirect: info.indirect
            )
        }
    }

    package func tag(of value: UnsafeRawPointer) throws -> Int {
        var tag: UInt32 = 0
        guard ABISwiftGetEnumTag(metadata, value, &tag) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum's value witnesses are unavailable."
            )
        }
        return Int(tag)
    }

    package func initializeEmptyCase(at index: Int, in storage: UnsafeMutableRawPointer) throws {
        guard ABISwiftInitializeEmptyEnumCase(metadata, storage, UInt32(index)) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum's value witnesses are unavailable."
            )
        }
    }

    package func payloadType(at index: Int) throws -> Any.Type? {
        guard cases[index].hasPayload else { return nil }
        guard let payload = ABISwiftEnumCasePayloadMetadata(metadata, index) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum case's payload type metadata is unavailable."
            )
        }
        let type = unsafeBitCast(payload, to: Any.Type.self)
        if type == Void.self {
            // Field metadata callbacks can hide a noncopyable type as Void.
            // A resolvable field declaration distinguishes genuine empty tuples.
            // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenReflection.cpp
            guard let syntax = ABICopySwiftEnumCasePayloadSyntax(metadata, index) else {
                throw RuntimeResolutionError.metadataUnavailable(
                    "The enum case's payload type cannot be verified from runtime field metadata."
                )
            }
            ABIReleaseSwiftSyntax(syntax)
        }
        return type
    }

    package func initializeCase(
        at index: Int,
        in storage: UnsafeMutableRawPointer,
        taking payload: UnsafeMutableRawPointer,
        payloadType: Any.Type
    ) throws {
        guard
            ABISwiftInitializeEnumCase(
                metadata,
                storage,
                UInt32(index),
                unsafeBitCast(payloadType, to: UnsafeRawPointer.self),
                cases[index].isIndirect,
                payload
            )
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum's value witnesses are unavailable."
            )
        }
    }

    package func copyPayloadSyntax(at index: Int) throws -> OpaquePointer {
        guard let syntax = ABICopySwiftEnumCasePayloadSyntax(metadata, index) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The enum case's payload type syntax is unavailable."
            )
        }
        return syntax
    }
}

/// The scratch storage for a bridged Error remains live through the body.
package func withRuntimeExistentialProjection<Result>(
    type: Any.Type,
    value: UnsafeRawPointer,
    _ body: (Any.Type, UnsafeRawPointer) throws -> Result
) throws -> Result {
    var projection = ABISwiftExistentialProjection()
    return try withUnsafeMutablePointer(to: &projection) { projected in
        guard
            ABISwiftProjectExistentialValue(
                unsafeBitCast(type, to: UnsafeRawPointer.self),
                value,
                projected
            ),
            let metadata = projected.pointee.metadata, let address = projected.pointee.value
        else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The runtime value is not a supported existential container."
            )
        }
        return try body(unsafeBitCast(metadata, to: Any.Type.self), address)
    }
}
