import ABIBridgeObjCXX
import Foundation

/// Ownership overrides for Objective-C declarations with nonstandard annotations.
///
/// The default follows Objective-C method-family conventions. Set an override
/// when the declaration uses an ownership attribute that runtime encodings omit.
public struct NativeMethodOptions: Sendable {
    /// Whether the method returns an object at +1 instead of +0 ownership.
    public var returnsRetainedObject: Bool?

    /// Whether the method consumes an additional reference to its receiver.
    ///
    /// The method handle continues to retain the original receiver even when an
    /// initializer returns a replacement object or nil.
    public var consumesReceiver: Bool?

    /// Creates ownership overrides; nil values use method-family conventions.
    public init(returnsRetainedObject: Bool? = nil, consumesReceiver: Bool? = nil) {
        self.returnsRetainedObject = returnsRetainedObject
        self.consumesReceiver = consumesReceiver
    }
}

/// A failure converting values at a native invocation boundary.
public enum ABIInvocationError: Error, Sendable, Equatable {
    /// A returned object cannot be converted to the requested Swift type.
    case incompatibleValue(expected: String, actual: String)
    /// A native method returned nil for a nonoptional Swift result.
    case unexpectedNilResult(expected: String)
}

/// A retained Objective-C receiver used to look up bound methods.
///
/// The receiver and its handles remain in the caller's isolation domain. This
/// type does not make an object safe to use from another actor or thread.
public final class NativeObject {
    private let receiver: AnyObject

    init(_ receiver: AnyObject) { self.receiver = receiver }

    /// Resolves a selector using an ordinary Swift function type.
    ///
    /// The signature includes only explicit arguments; the receiver and selector
    /// are supplied automatically. Each call uses normal Objective-C dispatch.
    /// Lookup validates argument count and supported runtime type encodings.
    ///
    /// - Parameters:
    ///   - selector: The Objective-C selector, including argument colons.
    ///   - signature: A fixed, synchronous Swift function type.
    ///   - options: Overrides for ownership annotations absent from runtime metadata.
    /// - Returns: A method retaining this receiver.
    /// - Throws: A resolution error for a missing selector or incompatible signature.
    public nonisolated(nonsending) func method<Result, each Argument>(
        selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init()
    ) async throws -> NativeMethod<Result, repeat each Argument> {
        var error: NSError?
        guard let handle = ABICopyObjCInvocation(
            receiver, NSSelectorFromString(selector),
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error
        ) else {
            if let error { throw error }
            throw ABIResolutionError.metadataUnavailable(selector)
        }
        return try NativeMethod(binding: ObjCInvocationBinding(handle))
    }
}

extension ABIRuntime {
    /// Binds an existing Objective-C instance without searching or loading images.
    ///
    /// - Parameter receiver: An object whose Objective-C methods will be called.
    /// - Returns: A handle retaining the receiver in the caller's isolation domain.
    public nonisolated func object(_ receiver: AnyObject) -> NativeObject {
        NativeObject(receiver)
    }
}

final class ObjCInvocationBinding {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ABIReleaseObjCInvocation(handle) }
}

/// A typed Objective-C method bound to a retained receiver.
///
/// The handle can be reused without repeating signature decoding. Invocation
/// creates an independent argument frame for every call and has no fixed limit on
/// the number of explicit arguments. See <doc:ObjectiveCInvocation>.
public struct NativeMethod<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let arguments: (repeat ObjCValueCodec<each Argument>)
    private let result: ObjCValueCodec<Result>

    init(binding: ObjCInvocationBinding) throws {
        self.binding = binding
        let handle = binding.handle
        var count = 0
        for _ in repeat (each Argument).self { count += 1 }
        guard count == ABIObjCInvocationParameterCount(handle) else {
            throw ABIResolutionError.signatureMismatch(
                expected: "\(count) arguments",
                found: ["\(ABIObjCInvocationParameterCount(handle)) arguments"]
            )
        }
        var index = 0
        func makeCodec<Value>(_ type: Value.Type) throws -> ObjCValueCodec<Value> {
            defer { index += 1 }
            return try .init(
                encoding: String(cString: ABIObjCInvocationParameterType(handle, index)),
                size: ABIObjCInvocationParameterSize(handle, index)
            )
        }
        arguments = (repeat try makeCodec((each Argument).self))
        result = try .init(
            encoding: String(cString: ABIObjCInvocationResultType(handle)),
            size: ABIObjCInvocationResultSize(handle)
        )
    }

    /// Calls the method with ordinary Swift values.
    ///
    /// The caller must honor the receiver's actor and thread requirements, pointer
    /// lifetimes, and ownership annotations. Object arguments are kept alive for
    /// the call; returned objects are managed by ARC. Runtime encodings cannot
    /// validate class constraints, nullability, consumed arguments, or variadic
    /// tails. Such contracts remain the caller's responsibility.
    ///
    /// - Parameter values: The explicit method arguments, in declaration order.
    /// - Returns: The result converted to the requested Swift type.
    /// - Throws: An invocation error for a failed object conversion or unexpected
    ///   nil result. Objective-C and C++ exceptions are not translated.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        var storage: [ObjCValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) {
            storage.append(try codec.encode(value))
        }
        let addresses = storage.map { UnsafeRawPointer($0.address) }
        let output = ObjCValueStorage(size: result.size, alignment: result.alignment)
        return try withExtendedLifetime(storage) {
            var error: NSError?
            let success = addresses.withUnsafeBufferPointer {
                ABIInvokeObjCInvocation(binding.handle, output.address, $0.baseAddress, &error)
            }
            guard success else {
                if let error { throw error }
                throw ABIResolutionError.invalidAddress
            }
            return try result.decode(output)
        }
    }
}
