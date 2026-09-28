import ABIBridgeCore

struct SwiftCall<Result, each Argument>: Sendable {
    let interface: SwiftCallInterface
    let errorPlan: SwiftErrorPlan?
    private let arguments: (repeat SwiftArgumentCodec<each Argument>)
    private let result: SwiftValueCodec<Result>
    private let hasTrailingValue: Bool
    private let consumedArguments: [Int]
    private let argumentCount: Int

    init(trailingType: CValueType? = nil, consumesArguments: Bool = false, errorPlan: SwiftErrorPlan? = nil) throws {
        self.errorPlan = errorPlan
        let arguments = (repeat try SwiftArgumentCodec<each Argument>(defaultConsuming: consumesArguments))
        let result = try SwiftValueCodec<Result>()
        var parameters: [CValueType] = []
        for argument in repeat each arguments { parameters.append(argument.type) }
        argumentCount = parameters.count
        if let trailingType { parameters.append(trailingType) }
        interface = try SwiftCallInterface(result: result.type, parameters: parameters, errorPlan: errorPlan)
        self.arguments = arguments
        self.result = result
        hasTrailingValue = trailingType != nil
        var consumed: [Int] = [], index = 0
        for argument in repeat each arguments {
            if argument.consumes { consumed.append(index) }
            index += 1
        }
        consumedArguments = consumed
    }

    @unsafe func unsafeInvoke(
        symbol: ResolvedSymbol, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil, implementation: SwiftImplementation? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        try unsafe symbol.withUnsafeAddress { address in
            try unsafe unsafeInvoke(
                function: implementation?.function ?? ABIUnsafeFunctionAtAddress(address),
                context: context, trailingValue: trailingValue, retaining: (owner ?? symbol, implementation),
                retainingCode: (symbol.image, implementation, codeOwner),
                didInvoke: didInvoke, repeat each values
            )
        }
    }

    @unsafe func unsafeInvoke(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil,
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
        let output = result.makeStorage()
        let nativeError = errorPlan?.makeStorage()
        var didThrow = false
        return try withExtendedLifetime((storage, trailingValue, owner)) {
            var failure: OpaquePointer?
            let success = addresses.withUnsafeBufferPointer { addresses in
                if let nativeError {
                    return ABIUnsafeInvokeSwiftThrowingCallInterface(
                        interface.handle, function, output.address, addresses.baseAddress, context,
                        nativeError.address, &didThrow, &failure
                    )
                }
                return ABIUnsafeInvokeSwiftCallInterface(
                    interface.handle, function, output.address, addresses.baseAddress, context, &failure
                )
            }
            guard success else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
            }
            for index in consumedArguments { storage[index].relinquishValue() }
            didInvoke?()
            if didThrow, let errorPlan, let nativeError {
                throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwner)
            }
            return try result.decode(output, retaining: owner, retainingCode: codeOwner)
        }
    }
}
