import ABIBridgeCore

/// Compares how a host type passes with how a declaration passes the type it
/// names at the same position.
///
/// A complete declaration name, or a type's receiver representation, lets a
/// host type with another Swift name stand for a declared type. Such an
/// adapter is accepted when both pass in the same register components, or
/// both by address with enough storage for the declared value.
enum SwiftDeclaredLowering {
    /// Throws `signatureMismatch` without a position when a value of `host`,
    /// stored as `layout`, does not pass as the declared `type` does.
    static func check(
        _ host: Any.Type,
        layout: CValueType,
        as type: String,
        declared: CValueType,
        position: SwiftValuePosition
    ) throws {
        let isResult = position == .result
        let passes = withExtendedLifetime((layout, declared)) {
            ABISwiftValuePassesAs(layout.handle, declared.handle, isResult)
        }
        guard passes else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: type + ", passed " + description(of: declared, isResult),
                    found: [
                        String(reflecting: host) + ", passed " + description(of: layout, isResult)
                    ]
                )
            )
        }
    }

    /// The failure to establish how the declaration passes its type, naming
    /// the host type and position, or nil for another kind of error.
    static func unestablished(
        _ error: ABIResolutionError,
        host: Any.Type,
        declared type: String,
        at position: String
    ) -> ABIResolutionError? {
        func message(_ detail: String) -> String {
            "Cannot compare \(String(reflecting: host)) at \(position) with the declared type \(type), whose convention is not established: \(detail) To pass the value without the comparison, state its convention with a valueABIs entry for \(String(reflecting: host))."
        }
        return switch error {
        case .metadataUnavailable(let detail): .metadataUnavailable(message(detail))
        case .unsupportedDeclaration(let detail): .unsupportedDeclaration(message(detail))
        default: nil
        }
    }

    private static func description(of type: CValueType, _ isResult: Bool) -> String {
        withExtendedLifetime(type) {
            guard let text = ABICopySwiftValueLoweringDescription(type.handle, isResult) else {
                return ""
            }
            defer { ABIFreeString(text) }
            return String(cString: text)
        }
    }
}
