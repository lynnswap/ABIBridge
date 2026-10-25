import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime

/// A physical slot and the owner of its storage. Declaration identity comes
/// from descriptors or original file fixups, never a currently installed hook.
/// Witness layouts and authentication follow Swift ABI Metadata.h/MetadataValues.h
/// and runtime Metadata.cpp::initProtocolWitness, checked by the compiler probe.
struct SwiftVirtualDispatch: Sendable {
    let address: UInt
    let authentication: NativePointerAuthentication
    let isAsync: Bool
    let image: NativeImage
    let generation: UInt64

    init(type: NativeSwiftType, entry: SwiftEntry, asynchronous: Bool) throws {
        guard entry.record?.context == .protocolRequirement else {
            let dispatch = try entry.classDispatch(
                in: type.metadata,
                resolver: type.resolver,
                asynchronous: asynchronous
            )
            address = dispatch.address
            authentication = dispatch.authentication
            isAsync = dispatch.isAsync
            image = dispatch.image
            generation = type.image.identity.loadGeneration
            return
        }
        func unavailable(_ reason: String) -> ABIResolutionError {
            .metadataUnavailable(entry.declaration.name + ": " + reason)
        }
        guard let identity = entry.record?.requirement,
            let requirementName = DeclarationKey.demangle(identity, language: .swift),
            let protocolName = SwiftMemberLookup.owner(of: requirementName),
            let protocolSymbol = try type.protocolDescriptor(named: protocolName)
        else { throw unavailable("The protocol requirement's descriptor identity is unavailable.") }
        let selected = try unsafe protocolSymbol.withUnsafeAddress { protocolAddress in
            guard let conformance = try type.conformance(to: protocolAddress),
                let image = conformance.image
            else { throw unavailable("The lookup type has no retained Swift conformance.") }
            let requirements = RuntimeProtocolLayout(protocolAddress).witnessRequirements
            var matches: [Int] = []
            var unnamed: [Int] = []
            for (index, requirement) in requirements.enumerated() {
                let identities = type.resolver.swiftMethodDescriptorRequirements(
                    at: requirement.address,
                    in: protocolSymbol.image
                )
                if identities.contains(identity) {
                    guard identities.count == 1 else {
                        throw unavailable(
                            "Several declarations name the same requirement descriptor."
                        )
                    }
                    matches.append(index)
                } else if identities.isEmpty && (1...4).contains(requirement.kind) {
                    unnamed.append(index)
                }
            }
            // Nonresilient protocols need not export Tq aliases. Associate
            // their original table-pattern fixups with local witness symbols.
            // Folded witnesses cannot distinguish the declarations they serve.
            if matches.isEmpty {
                guard let pattern = ABISwiftConformanceWitnessTablePattern(conformance.descriptor)
                else { throw unavailable("The conformance has no witness table pattern.") }
                var names: [UInt64: Set<String>] = [:]
                for witness in type.resolver.swiftWitnesses(
                    ofConformanceAt: conformance.descriptor,
                    in: image
                ) {
                    guard let requirement = witness.record.requirement else { continue }
                    unsafe witness.symbol.withUnsafeAddress {
                        _ = names[UInt64(UInt(bitPattern: $0)), default: []].insert(requirement)
                    }
                }
                let original = try withRuntimeErrors {
                    try OriginalImageMetadata(image: image.runtimeValue)
                }
                let targets = try withRuntimeErrors { try original.pointerTargets() }
                for index in unnamed {
                    let slot =
                        UInt64(UInt(bitPattern: pattern))
                        + UInt64((index + 1) * MemoryLayout<UInt>.size)
                    guard var code = targets[slot] else { continue }
                    if requirements[index].isAsync {
                        code = try withRuntimeErrors { try original.relativeTarget(at: code) }
                    }
                    let identities = names[code] ?? []
                    guard identities.contains(identity) else { continue }
                    guard identities.count == 1 else {
                        throw unavailable(
                            "Original witness code is folded across requirements; the slot's declaration is ambiguous."
                        )
                    }
                    matches.append(index)
                }
            }
            guard matches.count == 1, let index = matches.first else {
                throw unavailable(
                    "A unique witness slot is not established by requirement descriptors or original conformance fixups and witness symbols."
                )
            }
            let requirement = requirements[index]
            guard (1...4).contains(requirement.kind) else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Witness hooks and replacements require methods, initializers, getters or setters, not yielding accessors."
                )
            }
            guard requirement.isAsync == asynchronous else {
                throw unavailable(
                    "The requirement descriptor's effect differs from the prepared call."
                )
            }
            let authentication: NativePointerAuthentication =
                NativePointerAuthentication.isEnabled
                ? .signed(
                    key: asynchronous ? .dataA : .instructionA,
                    discriminator: UInt(requirement.flags >> 16),
                    addressDiversity: true
                ) : .unsigned
            // Publish at the runtime's actual address point, which may be
            // shared. The descriptor's pattern supplies only identity evidence.
            return (
                UInt(bitPattern: conformance.table) + UInt((index + 1) * MemoryLayout<UInt>.size),
                authentication, image
            )
        }
        address = selected.0
        authentication = selected.1
        isAsync = asynchronous
        image = selected.2
        generation = image.identity.loadGeneration
    }
}
