import ABIBridgeCore
import ABIBridgeCore.Backend

/// Compares how a host type passes with how a declaration passes the type it
/// names at the same position.
///
/// A complete declaration name, or a type's receiver representation, lets a
/// host type with another Swift name stand for a declared type. Such an
/// adapter is accepted when both pass in the same register components, or
/// both by address with enough storage for the declared value. An explicit
/// ABI for an Optional is compared the same way with the Optional's storage.
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

    /// Throws `unsupportedDeclaration` when `explicit`, the storage that
    /// `source` states for the Optional `type`, does not pass as `own`, the
    /// storage with which Swift passes it there. The ABI is wrong for any
    /// declaration, so the failure is not a mismatch with one candidate.
    static func checkExplicit(
        _ explicit: CValueType,
        statedBy source: String,
        forOptional type: Any.Type,
        own: CValueType
    ) throws {
        let passes = withExtendedLifetime((explicit, own)) {
            ABISwiftValuePassesAs(explicit.handle, own.handle, false)
        }
        guard !passes else { return }
        throw explicitMismatch(
            statedBy: source,
            forOptional: type,
            passing: lowering(of: explicit),
            swiftPassing: lowering(of: own)
        )
    }

    /// The failure of an explicit ABI that `source` states for the Optional
    /// `type`, which passes it as `passing` where Swift passes it as
    /// `swiftPassing`.
    static func explicitMismatch(
        statedBy source: String,
        forOptional type: Any.Type,
        passing: String,
        swiftPassing: String
    ) -> ABIResolutionError {
        .unsupportedDeclaration(
            "\(source) for \(String(reflecting: type)) passes it \(passing), "
                + "but Swift passes this Optional \(swiftPassing)."
        )
    }

    /// How a value stored as `type` passes as an argument.
    static func lowering(of type: CValueType) -> String { description(of: type, false) }

    /// How a value stored as `type` passes as a result.
    static func lowering(ofResult type: CValueType) -> String { description(of: type, true) }

    /// Whether values stored as `first` and as `second` pass alike: in the
    /// same register components, or by address in the same role with storage
    /// of the same size and alignment.
    static func passAlike(_ first: CValueType, _ second: CValueType, isResult: Bool) -> Bool {
        withExtendedLifetime((first, second)) {
            ABISwiftValuePassesAs(first.handle, second.handle, isResult)
                && ABISwiftValuePassesAs(second.handle, first.handle, isResult)
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
