package enum RuntimeGenericArgument: Sendable {
    case type(Any.Type)
    case pack([RuntimeGenericArgument])
}

import ABIBridgeCore
import Darwin

package func runtimeImplementationImage(
    containing address: UnsafeRawPointer
) throws -> RuntimeImage? {
    var info = Dl_info()
    guard dladdr(address, &info) != 0, let path = info.dli_fname else { return nil }
    return try RuntimeImage.opening(path: String(cString: path), loading: .loadedOnly)
}

/// Complete nominal metadata together with the dependencies used to form it.
package struct RuntimeGenericTypeMetadata: Sendable {
    package let value: Any.Type
    package let arguments: [RuntimeGenericArgument]
    package let images: [RuntimeImage]

    package init(descriptor: RuntimeSymbol, arguments: [RuntimeGenericArgument]) throws {
        try self.init(descriptor: RuntimeNominalDescriptor(descriptor), arguments: arguments)
    }

    package init(descriptor: RuntimeNominalDescriptor, arguments: [RuntimeGenericArgument]) throws {
        func scalar(_ argument: RuntimeGenericArgument) throws -> UnsafeRawPointer {
            guard case .type(let type) = argument else {
                throw RuntimeResolutionError.signatureMismatch(
                    .init(
                        expected: "Scalar elements in a Swift type pack",
                        found: ["A nested pack"]
                    )
                )
            }
            return unsafeBitCast(type, to: UnsafeRawPointer.self)
        }
        let pointers: [UnsafeRawPointer?] = try arguments.map { argument in
            switch argument {
            case .type:
                return try scalar(argument)
            case .pack(let elements):
                let pointers = try elements.map { Optional(try scalar($0)) }
                return pointers.withUnsafeBufferPointer {
                    ABISwiftMetadataPack($0.baseAddress, $0.count)
                }
            }
        }
        var failure: OpaquePointer?
        let result = unsafe descriptor.withUnsafeAddress { address in
            pointers.withUnsafeBufferPointer {
                ABICreateSwiftTypeMetadata(address, $0.baseAddress, $0.count, &failure)
            }
        }
        guard let result else {
            let error = consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
            throw RuntimeResolutionError.metadataUnavailable(error.localizedDescription)
        }
        try self.init(
            adopting: result,
            arguments: arguments,
            images: descriptor.image.map { [$0] } ?? []
        )
    }

    package init(metadata: Any.Type, retaining images: [RuntimeImage] = []) throws {
        var failure: OpaquePointer?
        guard
            let result = ABICopySwiftTypeMetadata(
                unsafeBitCast(metadata, to: UnsafeRawPointer.self),
                &failure
            )
        else {
            let error = consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
            throw RuntimeResolutionError.metadataUnavailable(error.localizedDescription)
        }
        let arguments: [RuntimeGenericArgument] = (0..<ABISwiftTypeMetadataArgumentCount(result))
            .map { index in
                let elements: [RuntimeGenericArgument] =
                    (0..<ABISwiftTypeMetadataArgumentElementCount(result, index)).map { element in
                        .type(
                            unsafeBitCast(
                                ABISwiftTypeMetadataArgumentElement(result, index, element)!,
                                to: Any.Type.self
                            )
                        )
                    }
                return ABISwiftTypeMetadataArgumentIsPack(result, index)
                    ? .pack(elements) : elements[0]
            }
        try self.init(adopting: result, arguments: arguments, images: images)
    }

    private init(
        adopting result: OpaquePointer,
        arguments: [RuntimeGenericArgument],
        images owners: [RuntimeImage] = []
    ) throws {
        defer { ABIReleaseSwiftTypeMetadata(result) }
        value = unsafeBitCast(ABISwiftTypeMetadataValue(result)!, to: Any.Type.self)
        self.arguments = arguments
        var images = owners
        func retainImage(at address: UnsafeRawPointer?) throws {
            if let address, let image = try runtimeImplementationImage(containing: address),
                !images.contains(where: { $0.identity == image.identity })
            {
                images.append(image)
            }
        }
        for index in 0..<ABISwiftTypeMetadataConformanceCount(result) {
            try retainImage(at: ABISwiftTypeMetadataConformance(result, index))
        }
        var visited: Set<ObjectIdentifier> = []
        func retainType(_ type: Any.Type) throws {
            guard visited.insert(ObjectIdentifier(type)).inserted else { return }
            let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
            try retainImage(at: ABISwiftTypeDescriptor(metadata))
            if metadata.load(as: UInt.self) == 0x307 {
                try retainImage(at: ABISwiftExtendedExistentialShape(metadata))
            }
            var failure: OpaquePointer?
            guard let nested = ABICopySwiftTypeMetadata(metadata, &failure) else {
                throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
            }
            defer { ABIReleaseSwiftTypeMetadata(nested) }
            for index in 0..<ABISwiftTypeMetadataConformanceCount(nested) {
                try retainImage(at: ABISwiftTypeMetadataConformance(nested, index))
            }
            for index in 0..<ABISwiftTypeMetadataArgumentCount(nested) {
                for element in 0..<ABISwiftTypeMetadataArgumentElementCount(nested, index) {
                    let pointer = ABISwiftTypeMetadataArgumentElement(nested, index, element)!
                    try retainType(unsafeBitCast(pointer, to: Any.Type.self))
                }
            }
            if let tuple = RuntimeTupleMetadata(type) {
                for element in tuple.elements { try retainType(element.type) }
            }
        }
        func retainArgument(_ argument: RuntimeGenericArgument) throws {
            switch argument {
            case .type(let type): try retainType(type)
            case .pack(let elements): try elements.forEach(retainArgument)
            }
        }
        try retainType(value)
        try arguments.forEach(retainArgument)
        self.images = images
    }
}
