import ABIBridgeCore

// The backend owns all types and permits concurrent use of a prepared interface.
// Each invocation supplies independent argument and result storage.
final class CCallInterface: @unchecked Sendable {
    let handle: OpaquePointer

    init(result: CValueType, parameters: [CValueType]) throws {
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        guard let handle = handles.withUnsafeBufferPointer({
            ABICreateCCallInterface(result.handle, $0.baseAddress, $0.count, &failure)
        }) else { throw consumeNativeCallFailure(failure) }
        self.handle = handle
    }

    deinit { ABIReleaseCallInterface(handle) }
}

// Shares the typed marshalling path between free functions and bound methods.
// Hidden pointers are ABI-supplied arguments such as this and an adapter target.
struct CFunctionCall<Result, each Argument>: Sendable {
    private let interface: CCallInterface
    private let arguments: (repeat CValueCodec<each Argument>)
    private let result: CValueCodec<Result>
    private let hiddenPointerCount: Int

    init(hiddenPointerCount: Int = 0) throws {
        self.hiddenPointerCount = hiddenPointerCount
        let arguments = (repeat try CValueCodec<each Argument>())
        let result = try CValueCodec<Result>()
        var types: [CValueType] = []
        if hiddenPointerCount > 0 {
            types = Array(repeating: try CValueType(scalar: ABIValuePointer), count: hiddenPointerCount)
        }
        for codec in repeat each arguments { types.append(codec.type) }
        interface = try CCallInterface(result: result.type, parameters: types)
        self.arguments = arguments
        self.result = result
    }

    @unsafe func unsafeInvoke(
        _ function: ABIUnmanagedFunction?,
        hiddenPointers: [UnsafeRawPointer] = [],
        retainingResultOwner owner: Any? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        precondition(hiddenPointers.count == hiddenPointerCount)
        var storage = hiddenPointers.map { pointer in
            let value = NativeValueStorage(
                size: MemoryLayout<UnsafeRawPointer>.size,
                alignment: MemoryLayout<UnsafeRawPointer>.alignment
            )
            value.store(pointer)
            return value
        }
        for (codec, value) in repeat (each arguments, each values) {
            storage.append(try codec.encode(value))
        }
        let addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        let output = NativeValueStorage(size: result.type.size, alignment: result.type.alignment)
        return try withExtendedLifetime(storage) {
            var failure: OpaquePointer?
            let success = addresses.withUnsafeBufferPointer {
                ABIUnsafeInvokeCCallInterface(
                    interface.handle, function, output.address, $0.baseAddress, &failure
                )
            }
            guard success else { throw consumeNativeCallFailure(failure) }
            return try result.decode(output, retaining: owner)
        }
    }
}

/// A typed C or C-compatible C++ function that retains its containing image.
///
/// A function handle reuses its prepared signature across calls. The handle is
/// Sendable because it owns immutable call metadata, but the function itself may
/// impose thread or actor requirements. See <doc:CFunctionInvocation>.
public struct NativeFunction<Result, each Argument>: Sendable {
    /// The resolved symbol and image retained for this function.
    public let symbol: ResolvedSymbol

    private let call: CFunctionCall<Result, repeat each Argument>

    init(symbol: ResolvedSymbol) throws {
        self.symbol = symbol
        call = try CFunctionCall()
    }

    /// Calls the function using the prepared platform C calling convention.
    ///
    /// The caller must ensure the signature matches the native declaration,
    /// pointers remain valid, and any thread or ownership requirements are met.
    /// Pointer values remain borrowed; the handle does not retain pointees.
    /// Variadic declarations, native exceptions, and nontrivial C++ values require
    /// separate adapters and must not be passed through this entry point.
    ///
    /// - Parameter values: Fixed arguments in declaration order.
    /// - Returns: The result converted to the requested Swift type.
    /// - Throws: An invocation error for a null nonoptional pointer result, or a
    ///   native call-interface error. ABI mismatches are not recoverable errors.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe symbol.withUnsafeAddress {
            try unsafe call.unsafeInvoke(ABIUnsafeFunctionAtAddress($0), repeat each values)
        }
    }
}

extension ABIRuntime {
    /// Resolves a C function with an ordinary Swift function-type metatype.
    ///
    /// Integer widths must match the C declaration; for example, use Int32 for
    /// C int. Lookup does not infer a C signature from its linker name.
    ///
    /// - Parameters:
    ///   - name: A C linker name without the Mach-O underscore.
    ///   - signature: A synchronous, fixed function type using supported C representations.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public func cFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in scope: ImageSelector = .automatic
    ) throws -> NativeFunction<Result, repeat each Argument> {
        try NativeFunction(symbol: resolve(.init(name: name, language: .c), in: scope))
    }

    /// Resolves a C function in an already retained image.
    ///
    /// - Parameters:
    ///   - name: A C linker name without the Mach-O underscore.
    ///   - signature: A synchronous, fixed function type using supported C representations.
    ///   - image: The retained image whose symbol index can be reused.
    /// - Returns: A reusable typed function retaining the image.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public func cFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in image: NativeImage
    ) throws -> NativeFunction<Result, repeat each Argument> {
        try NativeFunction(symbol: resolve(.init(name: name, language: .c), in: image))
    }

    /// Resolves a C++ free or static function with C-compatible value representations.
    ///
    /// The complete demangled declaration selects an overload. It does not
    /// establish that the supplied Swift function type matches the native ABI.
    ///
    /// - Parameters:
    ///   - name: A complete demangled C++ declaration.
    ///   - signature: A synchronous, fixed function type using supported C representations.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public func cxxFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in scope: ImageSelector = .automatic
    ) throws -> NativeFunction<Result, repeat each Argument> {
        try NativeFunction(symbol: resolve(.init(name: name, language: .cxx), in: scope))
    }

    /// Resolves a C-compatible C++ function in an already retained image.
    ///
    /// - Parameters:
    ///   - name: A complete demangled C++ declaration.
    ///   - signature: A synchronous, fixed function type using supported C representations.
    ///   - image: The retained image whose symbol index can be reused.
    /// - Returns: A reusable typed function retaining the image.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public func cxxFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in image: NativeImage
    ) throws -> NativeFunction<Result, repeat each Argument> {
        try NativeFunction(symbol: resolve(.init(name: name, language: .cxx), in: image))
    }
}
