import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import ObjectiveC

/// The conformance through which a type conforms to a protocol.
struct SwiftConformance {
    /// The witness table the Swift runtime finds for the type.
    let table: UnsafeRawPointer
    /// The conformance descriptor of that witness table.
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
        func table(of type: Any.Type) -> UnsafeRawPointer? {
            ABISwiftConformance(unsafeBitCast(type, to: UnsafeRawPointer.self), protocolDescriptor)
        }
        func descriptor(of type: Any.Type) -> UnsafeRawPointer? {
            table(of: type).flatMap { ABISwiftConformanceDescriptor($0) }
        }
        guard let table = table(of: metadata),
            let conformance = ABISwiftConformanceDescriptor(table)
        else { return nil }
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
            table: table,
            descriptor: conformance,
            image: try swiftImplementationImage(containing: conformance),
            conformingType: conformingType
        )
    }

    /// The witnesses of a protocol requirement in the image of this type's
    /// conformance, when Swift mangles them in another module than the
    /// requirement's: the module of the conforming type.
    ///
    /// - Parameter found: Candidates already found, which this search leaves
    ///   out. A mangling that does not start with a plain module name, such as
    ///   one that substitutes words of the module's name, is read by every
    ///   module's search.
    nonisolated func witnesses(
        of requirement: NativeDeclaration,
        through conformance: SwiftConformance,
        excluding found: [SwiftCandidate],
        includingSharedCache: Bool
    ) throws -> [SwiftCandidate] {
        guard let image = conformance.image,
            let module = SwiftModuleFilter(conformance.conformingType)?.module,
            module != SwiftModuleFilter(requirement.name)?.module
        else { return [] }
        let names = Set(found.lazy.filter { $0.symbol.image == image }.map(\.symbol.linkageName))
        return try resolver.swiftDeclarationCandidates(
            requirement,
            in: image,
            module: module,
            includingSharedCache: includingSharedCache
        ).filter {
            guard case .witness = $0.record.role else { return false }
            return !names.contains($0.symbol.linkageName)
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
            candidates.lazy.filter { $0.record.role == .dispatchThunk }.compactMap(
                \.record.requirement
            )
        )
        let type = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        // This type's conformance descriptor for each protocol, nil when it
        // does not conform.
        var conformances: [UnsafeRawPointer: UnsafeRawPointer?] = [:]
        var served: Set<String> = []
        var others: [(requirement: String, witness: SwiftCandidate)] = []
        var result = SwiftRequirementCandidates(candidates: [])
        for candidate in candidates {
            guard case .witness(let conformanceName) = candidate.record.role,
                let requirement = candidate.record.requirement
            else {
                result.candidates.append(candidate)
                continue
            }
            guard !thunks.contains(requirement) else { continue }
            guard
                let descriptor = resolver.swiftConformanceDescriptor(
                    named: conformanceName,
                    in: candidate.symbol.image
                )
            else {
                // Without its descriptor, the conformance is not established.
                others.append((requirement, candidate))
                continue
            }
            let applies = { (address: UnsafeRawPointer) -> Bool? in
                result.conformances[address] = candidate.symbol.image
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
            }(descriptor)
            switch applies {
            case true?:
                served.insert(requirement)
                result.candidates.append(candidate)
            case false?:
                others.append((requirement, candidate))
            case nil:
                if served.insert(requirement).inserted {
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
    /// The qualified name refers to the protocol's own members; a requirement
    /// that the protocol inherits has the inherited protocol's name. A Swift
    /// protocol's descriptor records each requirement's kind and effects but
    /// not its name, so only a requirement of the member's own kind, static
    /// or not and async or not, can be the member. Each such requirement is
    /// named by its method descriptor, which library evolution exports, or by
    /// the witness that a conformance's witness table holds in its slot. A
    /// named requirement with the requested name that selection has not
    /// considered is checked against the request with that witness. When a
    /// requirement of the member's kind has no established name, lookup fails
    /// instead of selecting the extension member.
    ///
    /// An Objective-C protocol, imported or declared `@objc`, is not checked:
    /// its runtime records name requirements only by selectors, which do not
    /// establish their Swift names. Marker protocols cannot be extended.
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
        // Generic binding identifies an Objective-C protocol by this name
        // before a Swift protocol descriptor.
        if NSProtocolFromString(
            protocolName.hasPrefix("__C.") ? String(protocolName.dropFirst(4)) : protocolName
        ) != nil {
            return
        }
        guard let protocolSymbol = try protocolDescriptor(qualifying: request) else {
            throw undecided(
                "neither a Swift protocol descriptor nor an Objective-C protocol named \(protocolName) is in the loaded images, so whether it declares this member as a requirement is not established."
            )
        }
        let protocolAddress = unsafe protocolSymbol.withUnsafeAddress { $0 }
        // The requirements of the member's kind, with their witness-table
        // slots, which follow the conformance descriptor's.
        let isStatic = request.name.hasPrefix("static ")
        let member = SwiftMemberLookup.member(of: request.name)
        let kind: UInt32 =
            request.name.contains(".getter : ")
            ? 3
            : request.name.contains(".setter : ")
                ? 4 : member.map { $0.hasPrefix("init(") || $0.hasPrefix("init<") } == true ? 2 : 1
        var unnamed = RuntimeProtocolLayout(protocolAddress).witnessRequirements.enumerated()
            .filter { _, requirement in
                requirement.kind == kind
                    && (kind == 2 || requirement.isInstance != isStatic)
                    && (kind == 4 || requirement.isAsync == isAsync)
            }.map { (slot: $0.offset + 1, requirement: $0.element) }
        guard !unnamed.isEmpty else { return }
        let key = SwiftMemberLookup.key(request.name)
        // Checks a named requirement that the request can name and selection
        // has not considered.
        func check(_ requirement: String, witness: SwiftCandidate?) throws {
            if let name = DeclarationKey.demangle(requirement, language: .swift),
                SwiftMemberLookup.key(name) != key
            {
                return
            }
            guard !considered.contains(requirement) else { return }
            guard let witness else {
                throw undecided(
                    "\(protocolName) declares a requirement with this name whose dispatch thunk is not in the loaded images."
                )
            }
            guard try !accepts(witness) else {
                throw ABIResolutionError.metadataUnavailable(
                    request.name
                        + ": \(protocolName) declares a requirement that this member names, which selection could not call for \(self.name), so no extension member stands in for it."
                )
            }
        }
        // A method descriptor symbol names the requirement at its address.
        unnamed = try unnamed.filter { entry in
            let requirements = resolver.swiftMethodDescriptorRequirements(
                at: entry.requirement.address,
                in: protocolSymbol.image
            )
            for requirement in requirements { try check(requirement, witness: nil) }
            return requirements.isEmpty
        }
        guard !unnamed.isEmpty else { return }
        // A conformance's witness table names a requirement by the witness in
        // its slot. Besides this type's conformance and those whose witnesses
        // selection saw, the conformance records of the protocol's image and
        // of this type's conformance's image list conformances to try.
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
        for descriptor in sources where tried.insert(descriptor).inserted && !unnamed.isEmpty {
            guard
                let image = try conformances[descriptor]
                    ?? swiftImplementationImage(containing: descriptor),
                !stripped.contains(image)
            else { continue }
            let witnesses = resolver.swiftWitnesses(ofConformanceAt: descriptor, in: image)
            guard !witnesses.isEmpty else {
                stripped.insert(image)
                continue
            }
            guard
                let table = descriptor == own?.descriptor
                    ? own?.table : ABISwiftConformanceWitnessTablePattern(descriptor)
            else { continue }
            // A linker can fold several witnesses into one address. A slot
            // holding it is named by each of them.
            var byAddress: [UnsafeRawPointer: [SwiftCandidate]] = [:]
            for witness in witnesses {
                unsafe witness.symbol.withUnsafeAddress {
                    byAddress[$0, default: []].append(witness)
                }
            }
            unnamed = try unnamed.filter { entry in
                let isAsync = entry.requirement.isAsync
                // An async slot holds the witness's async function pointer.
                guard
                    let held = ABISwiftWitnessTableEntry(table, entry.slot, isAsync).flatMap({
                        isAsync ? ABISwiftAsyncFunctionPointerCode($0) : $0
                    })
                else { return true }
                let named = byAddress[held] ?? []
                for witness in named {
                    guard let requirement = witness.record.requirement else { continue }
                    try check(requirement, witness: witness)
                }
                return named.isEmpty
            }
        }
        guard unnamed.isEmpty else {
            throw undecided(
                "\(unnamed.count) requirements of \(protocolName) that this member could be have no method descriptor or conformance's witness in the loaded images, so whether it is one of them is not established. A conformance's witnesses are local symbols, which stripping removes."
            )
        }
    }
}
