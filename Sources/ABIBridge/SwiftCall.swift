import ABIBridgeCore

struct SwiftCall<Result, each Argument>: Sendable {
    private let interface: SwiftCallInterface
    private let arguments: (repeat SwiftValueCodec<each Argument>)
    private let result: SwiftValueCodec<Result>
    private let hasTrailingValue: Bool
    private let consumesArguments: Bool

    init(trailingType: CValueType? = nil, consumesArguments: Bool = false) throws {
        let arguments = (repeat try SwiftValueCodec<each Argument>())
        let result = try SwiftValueCodec<Result>()
        var parameters: [CValueType] = []
        for argument in repeat each arguments { parameters.append(argument.type) }
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
        _ values: repeat each Argument
    ) throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        var storage: [NativeValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) {
            storage.append(try codec.encode(value))
        }
        var addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        if let trailingValue { addresses.append(trailingValue.address) }
        let output = NativeValueStorage(size: result.type.size, alignment: result.type.alignment)
        return try withExtendedLifetime((storage, trailingValue, owner)) {
            var failure: OpaquePointer?
            let success = unsafe symbol.withUnsafeAddress { address in
                addresses.withUnsafeBufferPointer {
                    ABIUnsafeInvokeSwiftCallInterface(
                        interface.handle, ABIUnsafeFunctionAtAddress(address), output.address,
                        $0.baseAddress, context, &failure
                    )
                }
            }
            guard success else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
            }
            if consumesArguments {
                for value in storage { value.relinquishValue() }
            }
            return try result.decode(output, retaining: owner ?? symbol)
        }
    }
}
