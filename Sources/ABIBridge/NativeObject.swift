import ABIBridgeObjCXX
import ABIBridgeCore
import Foundation
import ObjectiveC

/// Ownership overrides for Objective-C declarations with nonstandard annotations.
///
/// The default follows Objective-C method-family conventions. Set an override
/// when the declaration uses an ownership attribute that runtime encodings omit.
public struct NativeMethodOptions: Sendable {
    /// Whether the method returns an object at +1 instead of +0 ownership.
    public var returnsRetainedObject: Bool?

    /// Whether the method consumes an additional reference to its receiver.
    ///
    /// Invocation supplies an additional reference so the caller's ownership
    /// remains valid even when an initializer returns a replacement object or nil.
    public var consumesReceiver: Bool?

    /// Creates ownership overrides; nil values use method-family conventions.
    public init(returnsRetainedObject: Bool? = nil, consumesReceiver: Bool? = nil) {
        self.returnsRetainedObject = returnsRetainedObject
        self.consumesReceiver = consumesReceiver
    }
}

/// A failure converting values at a native invocation boundary.
public enum ABIInvocationError: Error, Sendable, Equatable {
    /// An argument or returned value cannot be converted to its required type.
    case incompatibleValue(expected: String, actual: String)
    /// A native method returned nil for a nonoptional Swift result.
    case unexpectedNilResult(expected: String)
}

/// A retained object used to look up bound Objective-C or Swift methods.
///
/// The receiver and its handles remain in the caller's isolation domain. This
/// type does not make an object safe to use from another actor or thread.
public final class NativeObject {
    private var receiver: AnyObject?
    private let runtime: ABIRuntime

    init(_ receiver: AnyObject, runtime: ABIRuntime) {
        self.receiver = receiver
        self.runtime = runtime
    }

    deinit { withExtendedLifetime(runtime) { receiver = nil } }

    private nonisolated(nonsending) func swiftType() async throws -> NativeSwiftType {
        var type: AnyClass? = Swift.type(of: receiver!)
        var missing: (any Error)?
        while let current = type {
            do {
                return try await runtime.swiftType(for: current)
            } catch let error as ABIResolutionError {
                guard case .declarationNotFound = error else { throw error }
                missing = error
                type = class_getSuperclass(current)
            }
        }
        throw missing ?? ABIResolutionError.metadataUnavailable("No Swift declaring type for this object.")
    }

    /// Reads an Objective-C object or class ivar by its runtime name.
    ///
    /// Lookup includes inherited ivars and runs synchronously on the caller's
    /// executor. The requested type uses the same object bridging and optional
    /// conversions as Objective-C method results. The isa field returns the
    /// runtime-decoded class. A present nil value requires
    /// an optional result; a missing ivar throws `ABIResolutionError.ivarNotFound`.
    ///
    /// The returned value owns its reference independently of this receiver.
    /// Weak ivars use the runtime's weak load; unsafe-unretained pointees must
    /// remain alive throughout the read. The caller must synchronize access with
    /// writers and honor the object's thread or actor requirements.
    ///
    /// Scalar, pointer, and aggregate ivars are unsupported. This does not infer
    /// Swift stored-property layouts. Block results require the correct
    /// `@convention(block)` signature, which ivar encodings cannot validate.
    ///
    /// - Parameters:
    ///   - name: The literal runtime ivar name, including any leading underscore.
    ///   - valueType: The desired Swift object, bridgeable value, class, or block type.
    /// - Returns: The converted value, or nil for an optional result with a nil ivar.
    /// - Throws: A missing-ivar, unsupported-storage, metadata, or conversion error.
    public func value<Value>(forIvar name: String, as valueType: Value.Type) throws -> Value {
        let object = receiver!
        let type: AnyClass = object_getClass(object)!
        guard !name.utf8.contains(0) else {
            throw ABIResolutionError.unsupportedDeclaration("An ivar name cannot contain a NUL byte.")
        }
        guard let ivar = class_getInstanceVariable(type, name) else {
            throw ABIResolutionError.ivarNotFound(name: name, className: NSStringFromClass(type))
        }
        guard let encoding = ivar_getTypeEncoding(ivar) else {
            throw ABIResolutionError.metadataUnavailable("The ivar has no Objective-C type encoding.")
        }
        let codec = try ObjCValueCodec<Value>(
            encoding: String(cString: encoding), size: MemoryLayout<UnsafeRawPointer>.size
        )
        switch codec.kind {
        case .object, .classObject, .block: break
        default:
            throw ABIResolutionError.unsupportedDeclaration("Only Objective-C object and class ivars can be read.")
        }
        // The first word is isa, which may contain packed or authenticated bits.
        // Decode it through the runtime instead of retaining the stored word.
        let value: AnyObject? = ivar_getOffset(ivar) == 0
            ? type as AnyObject : object_getIvar(object, ivar) as AnyObject?
        let storage = NativeValueStorage(size: codec.size, alignment: codec.alignment)
        // The shared decoder consumes one owned reference, including on conversion failure.
        storage.store(value.map { UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque()) })
        return try codec.decode(storage)
    }

    /// Resolves a Swift implementation for this object's concrete type.
    ///
    /// The method retains the receiver and implementation image. Invocation
    /// remains on the caller's executor and calls the captured implementation.
    /// - Parameters:
    ///   - name: A relative Swift member name and argument labels.
    ///   - signature: Explicit arguments and result, excluding self.
    ///   - isConsuming: Whether the Swift member consumes its receiver copy.
    /// - Returns: A reusable method bound to this receiver.
    /// - Throws: A lookup or unsupported-representation error.
    public nonisolated(nonsending) func method<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type,
        consuming isConsuming: Bool = false
    ) async throws -> NativeBoundSwiftMethod<Result, repeat each Argument> {
        let object = receiver!
        let type = try await swiftType()
        let method = try await type.method(named: name, as: signature, consuming: isConsuming)
        return NativeBoundSwiftMethod(method: method, receiver: object)
    }

    /// Resolves a synchronous, nonthrowing Swift getter bound to this object.
    ///
    /// - Parameters:
    ///   - name: The Swift property name or complete relative getter declaration.
    ///   - valueType: The result representation.
    ///   - isConsuming: Whether the getter consumes a receiver copy.
    /// - Returns: A zero-argument bound method.
    /// - Throws: A lookup or representation error.
    public nonisolated(nonsending) func getter<Value>(
        named name: String, as valueType: Value.Type, consuming isConsuming: Bool = false
    ) async throws -> NativeBoundSwiftMethod<Value> {
        let method = try await swiftType().getter(named: name, as: valueType, consuming: isConsuming)
        return NativeBoundSwiftMethod(method: method, receiver: receiver!)
    }

    /// Resolves a Swift setter bound to this object.
    ///
    /// The setter receives ownership of its ordinary incoming value.
    /// - Parameters:
    ///   - name: The Swift property name or complete relative setter declaration.
    ///   - valueType: The incoming representation.
    ///   - isConsuming: Whether the setter also consumes a receiver copy.
    /// - Returns: A one-argument bound method.
    /// - Throws: A lookup or representation error.
    public nonisolated(nonsending) func setter<Value>(
        named name: String, as valueType: Value.Type, consuming isConsuming: Bool = false
    ) async throws -> NativeBoundSwiftMethod<Void, Value> {
        let method = try await swiftType().setter(named: name, as: valueType, consuming: isConsuming)
        return NativeBoundSwiftMethod(method: method, receiver: receiver!)
    }

    /// Resolves a selector using an ordinary Swift function type.
    ///
    /// The signature includes only explicit arguments; the receiver and selector
    /// are supplied automatically. Each call uses normal Objective-C dispatch.
    /// Lookup runs synchronously on the caller's executor and validates argument
    /// count and supported runtime type encodings. No task or actor hop is needed.
    ///
    /// - Parameters:
    ///   - selector: The Objective-C selector, including argument colons.
    ///   - signature: A fixed, synchronous Swift function type.
    ///   - options: Overrides for ownership annotations absent from runtime metadata.
    /// - Returns: A method retaining this receiver.
    /// - Throws: A resolution error for a missing selector or incompatible signature.
    public func method<Result, each Argument>(
        selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init()
    ) throws -> NativeMethod<Result, repeat each Argument> {
        var error: NSError?
        guard let handle = ABICopyObjCInvocation(
            receiver!, NSSelectorFromString(selector),
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
    /// Binds an existing object without searching or loading images.
    ///
    /// - Parameter receiver: An object whose Objective-C or Swift methods will be called.
    /// - Returns: A handle retaining the receiver in the caller's isolation domain.
    public nonisolated func object(_ receiver: AnyObject) -> NativeObject {
        NativeObject(receiver, runtime: self)
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
    private let signature: ObjCMethodSignature<Result, repeat each Argument>

    init(binding: ObjCInvocationBinding) throws {
        self.binding = binding
        signature = try ObjCMethodSignature(handle: binding.handle)
    }

    /// Calls the method using normal Objective-C dispatch.
    ///
    /// The caller honors the receiver's actor/thread requirements, pointer
    /// lifetimes, ownership annotations, block signatures, and nullability.
    /// Retainable arguments stay alive for the call and results use Swift
    /// ownership. Foreign exceptions are not translated.
    ///
    /// - Parameter values: Explicit arguments, excluding self and the selector.
    /// - Returns: The result converted to the requested Swift type.
    /// - Throws: A conversion or invocation error, including unexpected nil.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try signature.invoke(repeat each values, using: { addresses, output in
            var error: NSError?
            let success = addresses.withUnsafeBufferPointer {
                ABIInvokeObjCInvocation(binding.handle, output, $0.baseAddress, &error)
            }
            guard success else {
                if let error { throw error }
                throw ABIResolutionError.invalidAddress
            }
        })
    }
}

struct ObjCMethodSignature<Result, each Argument> {
    let arguments: (repeat ObjCValueCodec<each Argument>)
    let result: ObjCValueCodec<Result>

    init(handle: OpaquePointer) throws {
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

    func callInterface() throws -> CCallInterface {
        var parameters = [try CValueType(scalar: ABIValuePointer), try CValueType(scalar: ABIValuePointer)]
        for codec in repeat each arguments { parameters.append(try codec.cType()) }
        return try CCallInterface(result: result.cType(), parameters: parameters)
    }

    func invoke(
        _ values: repeat each Argument,
        using body: ([UnsafeRawPointer], UnsafeMutableRawPointer) throws -> Void
    ) throws -> Result {
        var storage: [NativeValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) {
            storage.append(try codec.encode(value))
        }
        let addresses = storage.map { UnsafeRawPointer($0.address) }
        let output = NativeValueStorage(size: result.size, alignment: result.alignment)
        return try withExtendedLifetime(storage) {
            try body(addresses, output.address)
            return try result.decode(output)
        }
    }
}
