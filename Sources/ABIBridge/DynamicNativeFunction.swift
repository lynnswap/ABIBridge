import ABIBridgeCore

/// A C-compatible function whose value layouts are described at runtime.
///
/// Prefer NativeFunction and function-type metatypes when Swift types are known.
/// This handle retains its image and prepared signature; input and output values
/// retain their own storage and pointee owners.
public struct DynamicNativeFunction: Sendable {
    /// The resolved symbol and retained image.
    public let symbol: ResolvedSymbol
    /// The fixed parameter and result layouts.
    public let signature: NativeSignature
    private let interface: CCallInterface

    init(symbol: ResolvedSymbol, signature: NativeSignature) throws {
        self.symbol = symbol
        self.signature = signature
        interface = try CCallInterface(
            result: signature.result.requireCType(),
            parameters: signature.parameters.map { try $0.requireCType() }
        )
    }

    /// Invokes the native function with values matching the runtime signature.
    ///
    /// Count and layout compatibility are checked before dispatch. Each argument
    /// is copied to aligned call storage while its owner stays alive. Results own
    /// their byte allocation; ownership of resources referenced by returned
    /// pointers must be established by the adapter. Nontrivial values, consumed
    /// arguments, variadic declarations, and foreign exceptions need native adapters.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: Native result storage that can be cast to a user-defined wrapper.
    /// - Throws: A count/layout mismatch or native call-interface error.
    @unsafe public func unsafeInvoke(with values: [NativeValue]) throws -> NativeValue {
        guard values.count == signature.parameters.count else {
            throw ABIResolutionError.signatureMismatch(
                expected: "\(signature.parameters.count) arguments", found: ["\(values.count) arguments"]
            )
        }
        var storage: [NativeValueStorage] = []
        for (value, expected) in zip(values, signature.parameters) {
            try value.requireLayout(expected)
            let copy = NativeValueStorage(size: expected.size, alignment: expected.alignment, owner: value)
            unsafe value.withUnsafeBytes {
                if let base = $0.baseAddress, !$0.isEmpty {
                    copy.address.copyMemory(from: base, byteCount: $0.count)
                }
            }
            storage.append(copy)
        }
        let addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        return try withExtendedLifetime(storage) {
            try NativeValue(type: signature.result) { output in
                var failure: OpaquePointer?
                let success = unsafe symbol.withUnsafeAddress { address in
                    addresses.withUnsafeBufferPointer {
                        ABIUnsafeInvokeCCallInterface(
                            interface.handle, ABIUnsafeFunctionAtAddress(address),
                            output.baseAddress, $0.baseAddress, &failure
                        )
                    }
                }
                guard success else { throw consumeNativeCallFailure(failure) }
            }
        }
    }
}

extension ABIRuntime {
    /// Resolves a C function using runtime-known native layouts.
    ///
    /// - Parameters:
    ///   - name: A C linker name without the Mach-O underscore.
    ///   - signature: The explicit C-compatible parameter and result layouts.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A reusable function retaining the image and call interface.
    /// - Throws: A resolution error or unsupported call layout.
    public func cFunction(
        named name: String, signature: NativeSignature, in scope: ImageSelector = .automatic
    ) throws -> DynamicNativeFunction {
        try .init(symbol: resolve(.init(name: name, language: .c), in: scope), signature: signature)
    }

    /// Resolves a C function in a retained image using runtime-known layouts.
    ///
    /// - Parameters:
    ///   - name: A C linker name without the Mach-O underscore.
    ///   - signature: The explicit C-compatible parameter and result layouts.
    ///   - image: The retained image whose symbol index can be reused.
    /// - Returns: A reusable function retaining the image and call interface.
    /// - Throws: A resolution error or unsupported call layout.
    public func cFunction(
        named name: String, signature: NativeSignature, in image: NativeImage
    ) throws -> DynamicNativeFunction {
        try .init(symbol: resolve(.init(name: name, language: .c), in: image), signature: signature)
    }

    /// Resolves a C-compatible C++ function using runtime-known native layouts.
    ///
    /// - Parameters:
    ///   - name: A complete demangled C++ declaration.
    ///   - signature: The explicit C-compatible parameter and result layouts.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A reusable function retaining the image and call interface.
    /// - Throws: A resolution error or unsupported call layout.
    public func cxxFunction(
        named name: String, signature: NativeSignature, in scope: ImageSelector = .automatic
    ) throws -> DynamicNativeFunction {
        try .init(symbol: resolve(.init(name: name, language: .cxx), in: scope), signature: signature)
    }

    /// Resolves a C-compatible C++ function in a retained image using runtime layouts.
    ///
    /// - Parameters:
    ///   - name: A complete demangled C++ declaration.
    ///   - signature: The explicit C-compatible parameter and result layouts.
    ///   - image: The retained image whose symbol index can be reused.
    /// - Returns: A reusable function retaining the image and call interface.
    /// - Throws: A resolution error or unsupported call layout.
    public func cxxFunction(
        named name: String, signature: NativeSignature, in image: NativeImage
    ) throws -> DynamicNativeFunction {
        try .init(symbol: resolve(.init(name: name, language: .cxx), in: image), signature: signature)
    }
}
