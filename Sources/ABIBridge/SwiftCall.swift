import ABIBridgeCore

struct SwiftCall<Result, each Argument>: Sendable {
    let interface: SwiftCallInterface
    private let arguments: (repeat SwiftValueCodec<each Argument>)
    private let result: SwiftValueCodec<Result>
    private let hasTrailingValue: Bool
    private let consumesArguments: Bool
    private let argumentCount: Int

    init(trailingType: CValueType? = nil, consumesArguments: Bool = false) throws {
        let arguments = (repeat try SwiftValueCodec<each Argument>())
        let result = try SwiftValueCodec<Result>()
        var parameters: [CValueType] = []
        for argument in repeat each arguments { parameters.append(argument.type) }
        argumentCount = parameters.count
        if let trailingType { parameters.append(trailingType) }
        interface = try SwiftCallInterface(result: result.type, parameters: parameters)
        self.arguments = arguments
        self.result = result
        hasTrailingValue = trailingType != nil
        self.consumesArguments = consumesArguments
    }

    @unsafe func unsafeInvoke(
        symbol: ResolvedSymbol, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        didInvoke: (() -> Void)? = nil, implementation: SwiftImplementation? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        try unsafe symbol.withUnsafeAddress { address in
            try unsafe unsafeInvoke(
                function: implementation?.function ?? ABIUnsafeFunctionAtAddress(address),
                context: context, trailingValue: trailingValue, retaining: (owner ?? symbol, implementation),
                didInvoke: didInvoke, repeat each values
            )
        }
    }

    @unsafe func unsafeInvoke(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any?,
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        var storage: [NativeValueStorage] = []
        storage.reserveCapacity(argumentCount)
        for (codec, value) in repeat (each arguments, each values) {
            storage.append(try codec.encode(value))
        }
        var addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        if let trailingValue { addresses.append(trailingValue.address) }
        let output = NativeValueStorage(size: result.type.size, alignment: result.type.alignment)
        return try withExtendedLifetime((storage, trailingValue, owner)) {
            var failure: OpaquePointer?
            let success = addresses.withUnsafeBufferPointer {
                ABIUnsafeInvokeSwiftCallInterface(
                    interface.handle, function, output.address, $0.baseAddress, context, &failure
                )
            }
            guard success else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
            }
            if consumesArguments {
                for value in storage { value.relinquishValue() }
            }
            didInvoke?()
            return try result.decode(output, retaining: owner)
        }
    }
}
