import ABIBridgeCore
import ABIBridgeCore.Backend
import Synchronization

/// One requirement's physical arguments, result channel and receiver ownership.
package struct RuntimeSwiftProtocolWitness: Sendable {
    package let interface: RuntimeSwiftCallInterface
    package let consumesReceiver: Bool

    package init(interface: RuntimeSwiftCallInterface, consumesReceiver: Bool = false) {
        self.interface = interface
        self.consumesReceiver = consumesReceiver
    }
}

/// The process-lifetime runtime identity of one generated conforming class.
/// No callback bodies, public adapters or symbol resolvers belong to this owner.
package final class RuntimeSwiftProtocolClass: @unchecked Sendable {
    private static let classes = Mutex<[UInt64: RuntimeSwiftProtocolClass]>([:])
    package let descriptor: RuntimeSwiftProtocolDescriptor
    package let metadata: Any.Type
    private let handle: UnsafeRawPointer
    private let registration = Mutex<RuntimeSwiftProtocolConformance?>(nil)

    private init(descriptor: RuntimeSwiftProtocolDescriptor) throws {
        self.descriptor = descriptor
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftProtocolClass(&failure) else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftProtocol")
        }
        self.handle = handle
        metadata = unsafeBitCast(ABISwiftProtocolClassMetadata(handle)!, to: Any.Type.self)
    }

    package static func prepare(
        descriptor: RuntimeSwiftProtocolDescriptor
    ) throws -> RuntimeSwiftProtocolClass {
        try classes.withLock { classes in
            if let existing = classes[descriptor.symbol.address] { return existing }
            let prepared = try RuntimeSwiftProtocolClass(descriptor: descriptor)
            classes[descriptor.symbol.address] = prepared
            return prepared
        }
    }

    /// Registration already established these identities from the provider's
    /// descriptors or original file fixups; generated witnesses have no symbols.
    package static func requirement(
        for metadata: Any.Type,
        protocolAddress: UnsafeRawPointer,
        identity: String
    ) -> RuntimeSwiftProtocolDescriptor.Requirement? {
        classes.withLock { classes in
            guard let type = classes[UInt64(UInt(bitPattern: protocolAddress))],
                type.metadata == metadata
            else { return nil }
            return type.descriptor.requirements.first { $0.identity == identity }
        }
    }

    package func register(
        witnesses: [RuntimeSwiftProtocolWitness],
        retaining images: [RuntimeImage]
    ) throws -> RuntimeSwiftProtocolConformance {
        guard witnesses.count == descriptor.requirements.count else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                descriptor.protocolName + ": every protocol requirement needs a witness interface."
            )
        }
        let cached: RuntimeSwiftProtocolConformance? = try registration.withLock { registration in
            if let existing = registration {
                guard existing.hasSameABI(as: witnesses) else {
                    throw RuntimeResolutionError.unsupportedDeclaration(
                        descriptor.protocolName
                            + ": these method ABIs or receiver conventions conflict with the protocol's existing runtime registration."
                    )
                }
                return existing
            }
            return nil
        }
        if let cached {
            cached.retain(images: images)
            return cached
        }
        let entries = try RuntimeSwiftProtocolConformance.prepareEntries(witnesses: witnesses)
        // Entries own executable pages and code leases. A concurrent winner or
        // failed registration releases these candidates after the lock ends.
        let conformance = try withExtendedLifetime(entries) {
            try registration.withLock { registration in
                if let existing = registration {
                    guard existing.hasSameABI(as: witnesses) else {
                        throw RuntimeResolutionError.unsupportedDeclaration(
                            descriptor.protocolName
                                + ": these method ABIs or receiver conventions conflict with the protocol's existing runtime registration."
                        )
                    }
                    return existing
                }
                let prepared = try RuntimeSwiftProtocolConformance(
                    nativeClass: handle,
                    descriptor: descriptor,
                    witnesses: witnesses,
                    entries: entries
                )
                registration = prepared
                return prepared
            }
        }
        conformance.retain(images: images)
        return conformance
    }
}

/// Runtime registration pins only physical call interfaces, generated entries,
/// descriptors and code images. Instances independently own their callbacks.
package final class RuntimeSwiftProtocolConformance: @unchecked Sendable {
    package let handle: OpaquePointer
    package let metadata: Any.Type
    private let witnesses: [RuntimeSwiftProtocolWitness]
    private let entries: [RuntimeSwiftClosureCallbackOwner]
    private let images = Mutex<[RuntimeImageIdentity: RuntimeImage]>([:])

    fileprivate init(
        nativeClass: UnsafeRawPointer,
        descriptor: RuntimeSwiftProtocolDescriptor,
        witnesses: [RuntimeSwiftProtocolWitness],
        entries: [RuntimeSwiftClosureCallbackOwner]
    ) throws {
        self.witnesses = witnesses
        self.entries = entries
        let functions = entries.map { Optional($0.function) }
        let discriminators = descriptor.requirements.map {
            UInt16(truncatingIfNeeded: $0.flags >> 16)
        }
        var failure: OpaquePointer?
        guard
            let handle = unsafe descriptor.symbol.withUnsafeAddress({ address in
                functions.withUnsafeBufferPointer { functions in
                    discriminators.withUnsafeBufferPointer { discriminators in
                        ABICreateSwiftProtocolConformance(
                            nativeClass,
                            address,
                            functions.baseAddress,
                            discriminators.baseAddress,
                            functions.count,
                            &failure
                        )
                    }
                }
            })
        else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftProtocol")
        }
        self.handle = handle
        // This lookup caches the descriptor in the Swift runtime. The class's
        // process owner already pins its defining image before this point.
        metadata = unsafe descriptor.symbol.withUnsafeAddress {
            unsafeBitCast(ABISwiftProtocolTypeMetadata($0)!, to: Any.Type.self)
        }
        retain(images: [descriptor.symbol.image])
    }

    fileprivate static func prepareEntries(
        witnesses: [RuntimeSwiftProtocolWitness]
    ) throws -> [RuntimeSwiftClosureCallbackOwner] {
        try witnesses.enumerated().map { slot, witness in
            var failure: OpaquePointer?
            guard
                let callback = ABICreateSwiftProtocolWitnessCallback(
                    witness.interface.handle,
                    slot,
                    witness.consumesReceiver,
                    &failure
                )
            else {
                throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftProtocol")
            }
            return try RuntimeSwiftClosureCallbackOwner(handle: callback)
        }
    }

    fileprivate func hasSameABI(as other: [RuntimeSwiftProtocolWitness]) -> Bool {
        witnesses.count == other.count
            && zip(witnesses, other).allSatisfy {
                $0.consumesReceiver == $1.consumesReceiver
                    && $0.interface.hasSameABI(as: $1.interface)
            }
    }

    fileprivate func retain(images incoming: [RuntimeImage]) {
        // Duplicate leases may close images when released. Keep the incoming
        // array alive until the cache lock has been released.
        withExtendedLifetime(incoming) {
            images.withLock { images in
                for image in incoming where images[image.identity] == nil {
                    images[image.identity] = image
                }
            }
        }
    }
}
