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
    let conformanceImages: [NativeImage]

    init(descriptor: ResolvedSymbol, arguments: [NativeSwiftGenericArgument]) throws {
        self.arguments = arguments
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
        defer { ABIReleaseSwiftTypeMetadata(result) }
        value = unsafeBitCast(ABISwiftTypeMetadataValue(result)!, to: Any.Type.self)
        var images: [NativeImage] = []
        for index in 0..<ABISwiftTypeMetadataConformanceCount(result) {
            if let address = ABISwiftTypeMetadataConformance(result, index),
               let image = try swiftImplementationImage(containing: address),
               !images.contains(where: { $0.identity == image.identity }) {
                images.append(image)
            }
        }
        conformanceImages = images
    }
}
