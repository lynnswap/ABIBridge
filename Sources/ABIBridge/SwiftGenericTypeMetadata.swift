import ABIBridgeRuntime

func swiftImplementationImage(containing address: UnsafeRawPointer) throws -> NativeImage? {
    try withRuntimeErrors {
        try runtimeImplementationImage(containing: address).map(NativeImage.init)
    }
}

extension NativeSwiftGenericArgument {
    var runtimeValue: RuntimeGenericArgument {
        switch storage {
        case .type(let type, _): .type(type)
        case .pack(let elements): .pack(elements.map(\.runtimeValue))
        }
    }
    init(_ argument: RuntimeGenericArgument) {
        self =
            switch argument {
            case .type(let type): .type(type)
            case .pack(let elements): .pack(elements.map(Self.init))
            }
    }
}

struct SwiftGenericTypeMetadata: Sendable {
    let runtime: RuntimeGenericTypeMetadata
    let arguments: [NativeSwiftGenericArgument]
    var value: Any.Type { runtime.value }
    var images: [NativeImage] { runtime.images.map(NativeImage.init) }

    init(descriptor: ResolvedSymbol, arguments: [NativeSwiftGenericArgument]) throws {
        try self.init(descriptor: SwiftNominalDescriptor(descriptor), arguments: arguments)
    }
    init(descriptor: SwiftNominalDescriptor, arguments: [NativeSwiftGenericArgument]) throws {
        self.arguments = arguments
        runtime = try withExtendedLifetime(arguments) {
            try withRuntimeErrors {
                try RuntimeGenericTypeMetadata(
                    descriptor: descriptor.runtime,
                    arguments: arguments.map(\.runtimeValue)
                )
            }
        }
    }
    init(metadata: Any.Type, retaining images: [NativeImage] = []) throws {
        runtime = try withRuntimeErrors {
            try RuntimeGenericTypeMetadata(
                metadata: metadata,
                retaining: images.map(\.runtimeValue)
            )
        }
        arguments = runtime.arguments.map(NativeSwiftGenericArgument.init)
    }
}
