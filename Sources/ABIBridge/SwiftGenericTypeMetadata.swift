import ABIBridgeCore
import Darwin

func swiftImplementationImage(containing address: UnsafeRawPointer) throws -> NativeImage? {
    var info = Dl_info()
    guard dladdr(address, &info) != 0, let path = info.dli_fname else { return nil }
    return try NativeImage.opening(path: String(cString: path), loading: .loadedOnly)
}

/// Complete nominal metadata together with the dependencies used to form it.
struct SwiftGenericTypeMetadata: Sendable {
    let value: Any.Type
    let arguments: [NativeSwiftGenericArgument]
    let images: [NativeImage]

    init(descriptor: ResolvedSymbol, arguments: [NativeSwiftGenericArgument]) throws {
        try self.init(descriptor: SwiftNominalDescriptor(descriptor), arguments: arguments)
    }

    init(descriptor: SwiftNominalDescriptor, arguments: [NativeSwiftGenericArgument]) throws {
        func scalar(_ argument: NativeSwiftGenericArgument) throws -> UnsafeRawPointer {
            guard case .type(let type, _) = argument.storage else {
                throw ABIResolutionError.signatureMismatch(.init(
                    expected: "Scalar elements in a Swift type pack", found: ["A nested pack"]))
            }
            return unsafeBitCast(type, to: UnsafeRawPointer.self)
        }
        let pointers: [UnsafeRawPointer?] = try arguments.map { argument in
            switch argument.storage {
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
            let error = consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
            throw ABIResolutionError.metadataUnavailable(error.localizedDescription)
        }
        try self.init(adopting: result, arguments: arguments, images: descriptor.image.map { [$0] } ?? [])
    }

    init(metadata: Any.Type, retaining images: [NativeImage] = []) throws {
        var failure: OpaquePointer?
        guard let result = ABICopySwiftTypeMetadata(unsafeBitCast(metadata, to: UnsafeRawPointer.self), &failure) else {
            let error = consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
            throw ABIResolutionError.metadataUnavailable(error.localizedDescription)
        }
        let arguments: [NativeSwiftGenericArgument] = (0..<ABISwiftTypeMetadataArgumentCount(result)).map { index in
            let elements: [NativeSwiftGenericArgument] = (0..<ABISwiftTypeMetadataArgumentElementCount(result, index)).map { element in
                .type(unsafeBitCast(ABISwiftTypeMetadataArgumentElement(result, index, element)!, to: Any.Type.self))
            }
            return ABISwiftTypeMetadataArgumentIsPack(result, index) ? .pack(elements) : elements[0]
        }
        try self.init(adopting: result, arguments: arguments, images: images)
    }

    private init(adopting result: OpaquePointer, arguments: [NativeSwiftGenericArgument], images owners: [NativeImage] = []) throws {
        defer { ABIReleaseSwiftTypeMetadata(result) }
        value = unsafeBitCast(ABISwiftTypeMetadataValue(result)!, to: Any.Type.self)
        self.arguments = arguments
        var images = owners
        func retainImage(at address: UnsafeRawPointer?) throws {
            if let address, let image = try swiftImplementationImage(containing: address),
               !images.contains(where: { $0.identity == image.identity }) {
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
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
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
            if let tuple = SwiftTupleMetadata(type) {
                for element in tuple.elements { try retainType(element.type) }
            }
        }
        func retainArgument(_ argument: NativeSwiftGenericArgument) throws {
            switch argument.storage {
            case .type(let type, _): try retainType(type)
            case .pack(let elements): try elements.forEach(retainArgument)
            }
        }
        try retainType(value)
        try arguments.forEach(retainArgument)
        self.images = images
    }
}
