import ABIBridgeRuntime

/// Chooses one Swift declaration from the candidates of a lookup tier.
///
/// Candidates that name the same declaration are considered once, preferring
/// the declaration's code over its dispatch thunk. Every candidate that is not
/// chosen keeps its reason, so an unsupported candidate never hides a valid one.
struct SwiftCandidateSelection<Value> {
    private(set) var accepted: [(entry: SwiftEntry, value: Value)] = []
    private var rejections: [(declaration: NativeDeclaration, error: any Error)] = []

    /// - Parameter accept: Prepares a candidate, or returns nil when it does
    ///   not apply. A signature mismatch also means it does not apply.
    init(_ candidates: [SwiftCandidate], accept: (SwiftCandidate) throws -> Value?) {
        for candidate in Self.distinct(candidates) {
            do {
                if !candidate.record.runsOwnCode {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "\(candidate.declaration.name) is exported only through its dispatch thunk."
                    )
                }
                guard let value = try accept(candidate) else { continue }
                accepted.append((candidate.entry, value))
            } catch ABIResolutionError.signatureMismatch {
            } catch {
                rejections.append((candidate.declaration, error))
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

    /// Why no candidate applied, when one could not be prepared. Several
    /// unsupported candidates report each declaration's reason.
    var failure: (any Error)? {
        let reasons = rejections.compactMap { rejection -> String? in
            guard case ABIResolutionError.unsupportedDeclaration(let reason) = rejection.error
            else { return nil }
            return rejection.declaration.name + ": " + reason
        }
        guard rejections.count > 1, reasons.count == rejections.count else {
            return rejections.last?.error
        }
        return ABIResolutionError.unsupportedDeclaration(reasons.joined(separator: "\n"))
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
