import ABIBridgeRuntime
import ABIBridgeCore
import ObjectiveC

/// The conformance through which a type conforms to a protocol.
struct SwiftConformance {
    /// The conformance descriptor of the witness table the Swift runtime finds.
    let descriptor: UnsafeRawPointer
    /// The image that holds the descriptor and the conformance's witnesses.
    let image: NativeImage?
    /// The declaration name of the conforming type: the type itself, or the
    /// ancestor class whose conformance it inherits.
    let conformingType: String
}

/// The candidates of a protocol member's requirement tier.
struct SwiftRequirementCandidates {
    var candidates: [SwiftCandidate]
    /// The witnesses kept only to show which requirements the protocol
    /// declares: each serves another conformance than the lookup type's.
    var others: Set<String> = []
    /// The conformance descriptors of the witnesses considered, with their
    /// images, whose witnesses can name the protocol's requirements.
    var conformances: [UnsafeRawPointer: NativeImage] = [:]
}

extension NativeSwiftType {
    /// The descriptor of the protocol that qualifies `request`, nil when no
    /// loaded image declares a protocol with that name.
    nonisolated func protocolDescriptor(
        qualifying request: NativeDeclaration
    ) throws
        -> ResolvedSymbol?
    {
        guard let protocolName = SwiftMemberLookup.owner(of: request.name) else { return nil }
        do {
            return try resolver.resolve(
                NativeDeclaration(
                    name: "protocol descriptor for " + protocolName,
                    language: .swift,
                    kind: .data
                ),
                in: .automatic,
                loading: .loadedOnly
            )
        } catch ABIResolutionError.declarationNotFound {
            return nil
        }
    }

    /// This type's conformance to the protocol whose descriptor is at
    /// `protocolDescriptor`, nil when it does not conform.
    nonisolated func conformance(
        to protocolDescriptor: UnsafeRawPointer
    ) throws
        -> SwiftConformance?
    {
        func descriptor(of type: Any.Type) -> UnsafeRawPointer? {
            ABISwiftConformance(unsafeBitCast(type, to: UnsafeRawPointer.self), protocolDescriptor)
                .flatMap { ABISwiftConformanceDescriptor($0) }
        }
        guard let conformance = descriptor(of: metadata) else { return nil }
        // A subclass's witness table is its ancestor's when it inherits the
        // ancestor's conformance.
        var conforming: AnyClass? = metadata as? AnyClass
        while let current = conforming, let parent = class_getSuperclass(current),
            descriptor(of: parent) == conformance
        {
            conforming = parent
        }
        let conformingType: String
        if let conforming, ObjectIdentifier(conforming) != ObjectIdentifier(metadata) {
            let runtimeName = try swiftFunctionTypeName(conforming)
            conformingType = try swiftTypeDeclarationName(
                conforming,
                in: swiftClassImage(conforming, named: runtimeName, resolver: resolver),
                suggestedName: runtimeName,
                resolver: resolver
            )
        } else {
            conformingType = try declarationName()
        }
        return SwiftConformance(
            descriptor: conformance,
            image: try swiftImplementationImage(containing: conformance),
            conformingType: conformingType
        )
    }

    /// The witnesses of a protocol requirement in the image of this type's
    /// conformance, when Swift mangles them in another module than the
    /// requirement's: the module of the conforming type.
    nonisolated func witnesses(
        of requirement: NativeDeclaration,
        through conformance: SwiftConformance,
        includingSharedCache: Bool
    ) throws -> [SwiftCandidate] {
        guard let image = conformance.image,
            let module = SwiftModuleFilter(conformance.conformingType)?.module,
            module != SwiftModuleFilter(requirement.name)?.module
        else { return [] }
        return try resolver.swiftDeclarationCandidates(
            requirement,
            in: image,
            module: module,
            includingSharedCache: includingSharedCache
        ).filter {
            guard case .witness = $0.record.role else { return false }
            return true
        }
    }

    /// The candidates that can serve this type, among the witnesses of
    /// protocol requirements.
    ///
    /// A requirement's dispatch thunk selects the witness of the conformance
    /// that a call passes, so a requirement with a thunk is not called
    /// through a witness. A witness runs one conformance's implementation and
    /// serves this type only when the Swift runtime finds that conformance
    /// for it. When this type does not conform, one witness of each
    /// requirement remains, so that binding reports the missing conformance
    /// as it does for a thunk. A requirement whose witnesses all serve other
    /// conformances keeps one of them in `others`, which shows that the
    /// protocol declares it.
    nonisolated func servingWitnesses(
        _ candidates: [SwiftCandidate]
    ) throws
        -> SwiftRequirementCandidates
    {
        let thunks = Set(
            candidates.lazy.filter {
                $0.record.context == .protocolRequirement && $0.record.role == .dispatchThunk
            }.map(\.record.identity)
        )
        let type = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        // This type's conformance descriptor for each protocol, nil when it
        // does not conform.
        var conformances: [UnsafeRawPointer: UnsafeRawPointer?] = [:]
        var served: Set<String> = []
        var others: [(requirement: String, witness: SwiftCandidate)] = []
        var result = SwiftRequirementCandidates(candidates: [])
        for candidate in candidates {
            guard case .witness(let witness) = candidate.record.role else {
                result.candidates.append(candidate)
                continue
            }
            guard !thunks.contains(witness.requirement) else { continue }
            let descriptor: ResolvedSymbol
            do {
                descriptor = try resolver.resolve(
                    NativeDeclaration(
                        machOName: "_" + witness.conformanceDescriptor,
                        language: .swift,
                        kind: .data
                    ),
                    in: candidate.symbol.image,
                    loading: .loadedOnly
                )
            } catch ABIResolutionError.declarationNotFound {
                // Without its descriptor, the conformance is not established.
                others.append((witness.requirement, candidate))
                continue
            }
            let applies = unsafe descriptor.withUnsafeAddress { address -> Bool? in
                result.conformances[address] = descriptor.image
                // The descriptor's first field references the protocol.
                guard let protocolDescriptor = ABISwiftProtocolRequirementDescriptor(address)
                else { return false }
                let conformance =
                    conformances[protocolDescriptor]
                    ?? ABISwiftConformance(type, protocolDescriptor).flatMap {
                        ABISwiftConformanceDescriptor($0)
                    }
                conformances[protocolDescriptor] = .some(conformance)
                guard let conformance else { return nil }
                return conformance == address
            }
            switch applies {
            case true?:
                served.insert(witness.requirement)
                result.candidates.append(candidate)
            case false?:
                others.append((witness.requirement, candidate))
            case nil:
                if served.insert(witness.requirement).inserted {
                    result.candidates.append(candidate)
                }
            }
        }
        for other in others where served.insert(other.requirement).inserted {
            result.candidates.append(other.witness)
            result.others.insert(other.witness.record.identity)
        }
        return result
    }

    /// Checks that no requirement of the protocol that qualifies `request`
    /// can be the requested member, before an extension member stands in.
    ///
    /// A protocol descriptor records each requirement's kind and effects but
    /// not its name. The method descriptor symbols that library evolution
    /// exports name each requirement. Without them, the witnesses of one
    /// conformance name every requirement when they serve as many
    /// requirements as the protocol has. A requirement with the requested
    /// name that selection has not considered is checked against the request
    /// with one of its witnesses. When the names are not established, lookup
    /// fails instead of selecting the extension member.
    ///
    /// - Parameters:
    ///   - considered: The requirements that selection already considered.
    ///   - conformances: Conformance descriptors, with their images, whose
    ///     witnesses can name the requirements.
    ///   - accepts: Whether the request names the requirement that a
    ///     witness serves.
    nonisolated func checkRequirements(
        excluding request: NativeDeclaration,
        isAsync: Bool,
        considered: Set<String>,
        conformances: [UnsafeRawPointer: NativeImage],
        accepts: (SwiftCandidate) throws -> Bool
    ) throws {
        let protocolName = SwiftMemberLookup.owner(of: request.name) ?? request.name
        func undecided(_ reason: String) -> ABIResolutionError {
            .metadataUnavailable(
                request.name + ": " + reason
                    + " Name an extension member with its complete (extension in Module): declaration to select it."
            )
        }
        guard let protocolSymbol = try protocolDescriptor(qualifying: request) else {
            throw undecided(
                "the descriptor of \(protocolName) is not in the loaded images, so whether it declares this member as a requirement is not established."
            )
        }
        let requirements = unsafe protocolSymbol.withUnsafeAddress {
            RuntimeProtocolLayout($0).witnessRequirements
        }
        let code = requirements.filter(\.isCode)
        // The kinds of requirement the request can name.
        let isStatic = request.name.hasPrefix("static ")
        let text = isStatic ? String(request.name.dropFirst(7)) : request.name
        let member = SwiftMemberLookup.owner(of: text).map { text.dropFirst($0.count + 1) }
        let kind: UInt32 =
            text.contains(".getter : ")
            ? 3
            : text.contains(".setter : ")
                ? 4 : member.map { $0.hasPrefix("init(") || $0.hasPrefix("init<") } == true ? 2 : 1
        let matching = code.filter { requirement in
            requirement.kind == kind
                && (kind == 2 || requirement.isInstance != isStatic)
                && (kind == 4 || requirement.isAsync == isAsync)
        }
        guard !matching.isEmpty else { return }
        // Method descriptors name requirements by their addresses.
        let prefix = String(protocolSymbol.linkageName.dropLast(2)) + "P"
        var named: [UnsafeRawPointer: String] = [:]
        for symbol in resolver.runtime.exportedSymbols(
            withPrefix: prefix,
            in: protocolSymbol.image.runtimeValue
        ) where symbol.name.hasSuffix("Tq") {
            if let address = UnsafeRawPointer(bitPattern: UInt(symbol.address)) {
                named[address] = String(symbol.name.dropFirst().dropLast(2))
            }
        }
        let key = SwiftMemberLookup.key(request.name)
        func names(_ requirement: String) -> Bool {
            guard let name = DeclarationKey.demangle(requirement, language: .swift) else {
                return true
            }
            return SwiftMemberLookup.key(name) == key
        }
        if matching.allSatisfy({ named[$0.address] != nil }) {
            // A thunk accompanies each method descriptor, so selection has
            // considered every requirement that the request can name.
            for requirement in matching {
                let identity = named[requirement.address]!
                guard !names(identity) || considered.contains(identity) else {
                    throw undecided(
                        "\(protocolName) declares a requirement with this name whose dispatch thunk is not in the loaded images."
                    )
                }
            }
            return
        }
        // A conformance's witnesses name every requirement when there are as
        // many as the protocol's requirements implemented with code. Besides
        // this type's conformance and those whose witnesses selection saw,
        // the conformance records of the protocol's image and of this type's
        // conformance's image list conformances to try.
        let protocolAddress = unsafe protocolSymbol.withUnsafeAddress { $0 }
        let own = try conformance(to: protocolAddress)
        var sources: [UnsafeRawPointer] = own.map { [$0.descriptor] } ?? []
        sources += conformances.keys
        for address in [protocolAddress, own?.descriptor].compactMap({ $0 }) {
            let count = ABISwiftImageConformanceDescriptors(address, protocolAddress, nil, 0)
            var recorded = [UnsafeRawPointer?](repeating: nil, count: count)
            let copied = recorded.withUnsafeMutableBufferPointer {
                ABISwiftImageConformanceDescriptors(
                    address,
                    protocolAddress,
                    $0.baseAddress,
                    $0.count
                )
            }
            sources += recorded.prefix(min(count, copied)).compactMap { $0 }
        }
        var tried: Set<UnsafeRawPointer> = []
        // Stripping removes the witnesses of every conformance in an image.
        var stripped: Set<NativeImage> = []
        for descriptor in sources where tried.insert(descriptor).inserted {
            guard
                let image = try conformances[descriptor]
                    ?? swiftImplementationImage(containing: descriptor),
                !stripped.contains(image)
            else { continue }
            var witnesses: [String: SwiftCandidate] = [:]
            for witness in resolver.swiftWitnesses(ofConformanceAt: descriptor, in: image) {
                guard case .witness(let served) = witness.record.role else { continue }
                witnesses[served.requirement] = witness
            }
            if witnesses.isEmpty { stripped.insert(image) }
            guard witnesses.count == code.count else { continue }
            for (requirement, witness) in witnesses
            where names(requirement) && !considered.contains(requirement) {
                guard try !accepts(witness) else {
                    throw ABIResolutionError.metadataUnavailable(
                        request.name
                            + ": \(protocolName) declares a requirement that this member names, which selection could not call for \(self.name), so no extension member stands in for it."
                    )
                }
            }
            return
        }
        throw undecided(
            "no method descriptor or conformance's witnesses in the loaded images name the \(matching.count) requirements of \(protocolName) that this member could be, so whether it is one of them is not established. A conformance's witnesses are local symbols, which stripping removes."
        )
    }
}
