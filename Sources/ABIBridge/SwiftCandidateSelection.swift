import ABIBridgeRuntime

/// Chooses one Swift declaration from the candidates of a lookup tier.
///
/// Candidates that name the same declaration are considered once, preferring
/// the declaration's code over its dispatch thunk. Every candidate that is not
/// chosen keeps its reason, so an unsupported candidate never hides a valid one.
struct SwiftCandidateSelection<Value> {
    private(set) var accepted: [(entry: SwiftEntry, value: Value)] = []
    private var rejections: [(declaration: NativeDeclaration, error: any Error)] = []
    private var mismatches: [(declaration: NativeDeclaration, mismatch: ABIResolutionError.SignatureMismatch)] = []
    /// Why a declaration that applies to the request has no selectable code.
    /// Such a declaration still takes precedence over later lookup tiers.
    private(set) var unavailable: (any Error)?

    /// - Parameters:
    ///   - dispatch: Selects the code of a member exported only through its
    ///     class dispatch thunk. Without it, such candidates are rejected.
    ///   - namesDeclaration: Whether the request spells the complete
    ///     declaration of every candidate that `accept` does not skip. A
    ///     mismatch of such a candidate at any position is then reported.
    ///   - accept: Prepares a candidate from the entry of its declaration, or
    ///     returns nil when the candidate does not apply. A signature mismatch
    ///     also means it does not apply. Code is selected only afterwards.
    init(
        _ candidates: [SwiftCandidate],
        namesDeclaration: Bool = false,
        dispatch: ((SwiftCandidate) throws -> SwiftEntry)? = nil,
        accept: (SwiftCandidate, SwiftEntry) throws -> Value?
    ) {
        for candidate in Self.distinct(candidates) {
            let value: Value
            do {
                guard let applicable = try accept(candidate, candidate.entry) else { continue }
                value = applicable
            } catch let ABIResolutionError.signatureMismatch(mismatch) {
                // An argument or result that does not convert is an
                // incompatible request. A declaration whose context does not
                // bind, such as an extension constrained to other types, does
                // not apply and stays absent unless the request named it.
                switch mismatch.position {
                case .argument, .result, .receiver:
                    mismatches.append((candidate.declaration, mismatch))
                case .signature, .argumentCount:
                    if namesDeclaration { mismatches.append((candidate.declaration, mismatch)) }
                }
                continue
            } catch {
                rejections.append((candidate.declaration, error))
                continue
            }
            do {
                let entry: SwiftEntry
                if candidate.record.runsOwnCode {
                    entry = candidate.entry
                } else if let dispatch {
                    entry = try dispatch(candidate)
                } else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Its code is exported only through its dispatch thunk."
                    )
                }
                accepted.append((entry, value))
            } catch ABIResolutionError.signatureMismatch {
            } catch {
                rejections.append((candidate.declaration, error))
                if unavailable == nil {
                    unavailable = Self.naming(candidate.declaration, in: error)
                }
            }
        }
    }

    /// The single applicable candidate, nil when none applies.
    func selected(for request: NativeDeclaration) throws -> (entry: SwiftEntry, value: Value)? {
        guard accepted.count <= 1 else {
            throw ABIResolutionError.ambiguousDeclaration(
                request,
                candidates: accepted.map(\.entry.linkageName)
            )
        }
        return accepted.first
    }

    /// How the request is incompatible with the candidates that did not apply.
    ///
    /// One candidate reports its failing position and types; several list
    /// each declaration with its failing position.
    var mismatch: (any Error)? {
        guard mismatches.count > 1 else {
            return mismatches.first.map {
                ABIResolutionError.signatureMismatch($0.mismatch.inContext($0.declaration, at: $0.mismatch.position))
            }
        }
        return ABIResolutionError.signatureMismatch(
            .init(
                position: .signature,
                expected: "A declaration compatible with the requested signature",
                found: mismatches.map {
                    $0.mismatch.inContext($0.declaration, at: $0.mismatch.position)
                        .runtimeValue.summary
                }
            )
        )
    }

    /// Why no candidate applied, when one could not be prepared, naming the
    /// candidate. Several unsupported candidates report each declaration's
    /// reason.
    var failure: (any Error)? {
        let reasons = rejections.compactMap { rejection -> String? in
            guard case ABIResolutionError.unsupportedDeclaration(let reason) = rejection.error
            else { return nil }
            return Self.reason(reason, of: rejection.declaration)
        }
        guard rejections.count > 1, reasons.count == rejections.count else {
            return rejections.last.map { Self.naming($0.declaration, in: $0.error) }
        }
        return ABIResolutionError.unsupportedDeclaration(reasons.joined(separator: "\n"))
    }

    /// The error with the rejected candidate's name before its reason. The
    /// other cases identify their declaration, or concern no single one.
    private static func naming(_ declaration: NativeDeclaration, in error: any Error) -> any Error {
        switch error {
        case ABIResolutionError.unsupportedDeclaration(let reason):
            ABIResolutionError.unsupportedDeclaration(Self.reason(reason, of: declaration))
        case ABIResolutionError.metadataUnavailable(let reason):
            ABIResolutionError.metadataUnavailable(Self.reason(reason, of: declaration))
        default: error
        }
    }

    private static func reason(_ reason: String, of declaration: NativeDeclaration) -> String {
        declaration.name + ": " + reason
    }

    // A declaration's code and its dispatch thunk in one image share an identity.
    private static func distinct(_ candidates: [SwiftCandidate]) -> [SwiftCandidate] {
        let implemented = Set(candidates.lazy.filter(\.record.runsOwnCode).map(SwiftDeclarationKey.init))
        return candidates.filter {
            $0.record.runsOwnCode || !implemented.contains(SwiftDeclarationKey($0))
        }
    }
}

private struct SwiftDeclarationKey: Hashable {
    let identity: String
    let image: NativeImage
    init(_ candidate: SwiftCandidate) {
        identity = candidate.record.identity
        image = candidate.symbol.image
    }
}
