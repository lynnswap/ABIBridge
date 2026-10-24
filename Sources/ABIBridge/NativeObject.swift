import ABIBridgeObjCXX
import ABIBridgeCore
import Foundation
import ObjectiveC

/// Ownership overrides for Objective-C declarations with nonstandard annotations.
///
/// The default follows Objective-C method-family conventions. Set an override when the declaration uses an ownership attribute that runtime encodings omit.
public struct NativeMethodOptions: Sendable {
    /// Whether the method returns an object at +1 instead of +0 ownership.
    public var returnsRetainedObject: Bool?

    /// Whether the method consumes an additional reference to its receiver.
    ///
    /// Outgoing invocation supplies an additional reference so the caller's ownership remains valid when initialization returns another object or nil. Initializer hooks instead forward the incoming consumed reference once.
    public var consumesReceiver: Bool?

    /// Zero-based explicit arguments passed with an additional owned reference.
    ///
    /// These positions must have an Objective-C object, class, or block encoding and match the declaration's `ns_consumed` parameters. The receiver and selector are excluded. The bridge preserves the caller's references.
    public var consumedArguments: Set<Int>

    /// Creates ownership overrides; nil values use method-family conventions.
    public init(
        returnsRetainedObject: Bool? = nil,
        consumesReceiver: Bool? = nil,
        consumedArguments: Set<Int> = []
    ) {
        self.returnsRetainedObject = returnsRetainedObject
        self.consumesReceiver = consumesReceiver
        self.consumedArguments = consumedArguments
    }

    func withConsumedArguments<Result>(
        _ body: (UnsafeBufferPointer<Int>) throws -> Result
    ) rethrows -> Result {
        try consumedArguments.sorted().withUnsafeBufferPointer(body)
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
/// The receiver and its handles remain in the caller's isolation domain. This type does not make an object safe to use from another actor or thread.
public final class NativeObject {
    private(set) var receiver: AnyObject?
    private let runtime: ABIRuntime

    init(_ receiver: AnyObject, runtime: ABIRuntime) {
        self.receiver = receiver
        self.runtime = runtime
    }

    deinit { withExtendedLifetime(runtime) { receiver = nil } }

    private nonisolated func swiftType() throws -> NativeSwiftType {
        try Self.swiftType(for: Swift.type(of: receiver!), in: runtime)
    }

    private nonisolated static func swiftType(
        for objectType: AnyClass,
        in runtime: ABIRuntime
    ) throws -> NativeSwiftType {
        var type: AnyClass? = objectType
        var missing: (any Error)?
        while let current = type {
            do {
                return try runtime.swiftType(for: current)
            } catch let error as ABIResolutionError {
                guard case .declarationNotFound = error else { throw error }
                missing = error
                type = class_getSuperclass(current)
            }
        }
        throw missing
            ?? ABIResolutionError.metadataUnavailable("No Swift declaring type for this object.")
    }

    /// Reads an Objective-C object or class ivar by its runtime name.
    ///
    /// Lookup includes inherited ivars and runs synchronously on the caller's executor. Conversion follows Objective-C method-result rules. The isa field returns the runtime-decoded class. A nil value requires an optional result; a missing ivar throws `ABIResolutionError.ivarNotFound`.
    ///
    /// The result owns its reference independently of this receiver. Weak ivars use the runtime's weak load. Keep unsafe-unretained pointees alive during the read, synchronize with writers, and honor the object's thread or actor requirements.
    ///
    /// Scalar, pointer, and aggregate ivars are unsupported, and lookup does not infer Swift stored-property layouts. Block results require a correct `@convention(block)` signature, which ivar encodings cannot validate.
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
            throw ABIResolutionError.unsupportedDeclaration(
                "An ivar name cannot contain a NUL byte."
            )
        }
        guard let ivar = class_getInstanceVariable(type, name) else {
            throw ABIResolutionError.ivarNotFound(name: name, className: NSStringFromClass(type))
        }
        guard let encoding = ivar_getTypeEncoding(ivar) else {
            throw ABIResolutionError.metadataUnavailable(
                "The ivar has no Objective-C type encoding."
            )
        }
        let codec = try ObjCValueCodec<Value>(
            encoding: String(cString: encoding),
            size: MemoryLayout<UnsafeRawPointer>.size
        )
        switch codec.kind {
        case .object, .classObject, .block: break
        default:
            throw ABIResolutionError.unsupportedDeclaration(
                "Only Objective-C object and class ivars can be read."
            )
        }
        // The first word is isa, which may contain packed or authenticated bits.
        // Decode it through the runtime instead of retaining the stored word.
        let value: AnyObject? =
            ivar_getOffset(ivar) == 0
            ? type as AnyObject : object_getIvar(object, ivar) as AnyObject?
        let storage = NativeValueStorage(size: codec.size, alignment: codec.alignment)
        // The shared decoder consumes one owned reference, including on conversion failure.
        storage.store(value.map { UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque()) })
        return try codec.decode(storage)
    }

    /// Resolves an instance member of this object's Swift type and binds this
    /// object as its receiver.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// The object's class supplies the lookup type: the nearest class in its
    /// hierarchy that has Swift metadata, including an imported Objective-C
    /// class with Swift extension members. Existing generic class instances
    /// supply their enclosing type arguments. The request's options apply as
    /// they do on a ``NativeSwiftType``; a class receiver passes as a
    /// reference. The handle retains the receiver and the member's
    /// implementation images, and calls the implementation selected during
    /// lookup.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable method bound to this object.
    /// - Throws: A lookup, representation, or preparation error.
    public func resolveAndWait<Signature>(
        _ request: NativeRequest<NativeSwiftInstanceMemberRequest<Signature>>
    ) throws -> NativeBoundSwiftMethod<Signature> {
        let object = receiver!
        let method = try swiftType().resolveAndWait(request)
        return NativeBoundSwiftMethod(method: method, receiver: object)
    }

    /// Resolves an instance member of this object's Swift type without
    /// blocking the caller's executor, and binds this object.
    ///
    /// Lookup and preparation run on a worker. The receiver and bound handle
    /// stay in the caller's isolation domain; lookup does not invoke the
    /// member.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable method bound to this object.
    /// - Throws: The same lookup, representation, and preparation errors as
    ///   synchronous resolution.
    public nonisolated(nonsending) func resolve<Signature>(
        _ request: NativeRequest<NativeSwiftInstanceMemberRequest<Signature>>
    ) async throws -> NativeBoundSwiftMethod<Signature> {
        let objectType: AnyClass = Swift.type(of: receiver!)
        let method = try await runtime.prepare { runtime in
            try Self.swiftType(for: objectType, in: runtime).resolveAndWait(request)
        }
        return NativeBoundSwiftMethod(method: method, receiver: receiver!)
    }

    /// Resolves an initializer, or a static or class member, of this object's
    /// Swift type.
    ///
    /// Search and preparation run synchronously on the caller's thread. The
    /// lookup type is the one that instance member requests use, and its
    /// metadata is the member's `self`. The result retains no receiver.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable function retaining the type and the member's
    ///   implementation images.
    /// - Throws: A lookup, representation, or preparation error.
    public func resolveAndWait<Signature>(
        _ request: NativeRequest<NativeSwiftTypeMemberRequest<Signature>>
    ) throws -> NativeSwiftFunction<Signature> {
        try swiftType().resolveAndWait(request)
    }

    /// Resolves an initializer, or a static or class member, of this object's
    /// Swift type without blocking the caller's executor.
    ///
    /// - Parameter request: The member and its lookup options.
    /// - Returns: A reusable function retaining the type and the member's
    ///   implementation images.
    /// - Throws: The same lookup, representation, and preparation errors as
    ///   synchronous resolution.
    public nonisolated(nonsending) func resolve<Signature>(
        _ request: NativeRequest<NativeSwiftTypeMemberRequest<Signature>>
    ) async throws -> NativeSwiftFunction<Signature> {
        let objectType: AnyClass = Swift.type(of: receiver!)
        return try await runtime.prepare { runtime in
            try Self.swiftType(for: objectType, in: runtime).resolveAndWait(request)
        }
    }

    /// Resolves an Objective-C message for this receiver.
    ///
    /// Search and preparation run synchronously on the caller's thread. The
    /// receiver and selector are supplied automatically, and calls use normal
    /// Objective-C dispatch. Lookup uses this receiver, so its dynamic method
    /// resolution and forwarding signature apply, and validates the argument
    /// count and supported runtime encodings. A class object receives class
    /// messages.
    ///
    /// - Parameter request: The message and its ownership options.
    /// - Returns: A method retaining this receiver.
    /// - Throws: A resolution error for a missing selector or incompatible
    ///   signature.
    public func resolveAndWait<Result, each Argument>(
        _ request: NativeObjCMessageRequest<Result, repeat each Argument>
    ) throws -> NativeBoundObjCMethod<Result, repeat each Argument> {
        let binding = try objcInvocationBinding(
            selector: request.query.selector,
            options: request.query.options,
            prepareImages: true
        )
        return try NativeBoundObjCMethod(
            binding: binding,
            variadicFrom: request.query.variadicFrom,
            reportsErrors: request.query.reportsErrors
        )
    }

    /// Resolves an Objective-C message for this receiver, preparing its image
    /// and call ABI away from the caller's executor.
    ///
    /// Receiver-specific dynamic resolution and forwarding-signature callbacks
    /// stay on the caller's executor to honor its isolation. The receiver and
    /// returned bound handle never move to the worker. Image acquisition and
    /// signature decoding run on the worker; shared call interfaces join any
    /// preparation already in progress. Invocation remains an explicit
    /// operation on the caller's executor.
    ///
    /// - Parameter request: The message and its ownership options.
    /// - Returns: A method retaining this receiver.
    /// - Throws: The same resolution errors as synchronous resolution.
    public nonisolated(nonsending) func resolve<Result, each Argument>(
        _ request: NativeObjCMessageRequest<Result, repeat each Argument>
    ) async throws -> NativeBoundObjCMethod<Result, repeat each Argument> {
        let query = request.query
        let binding = try objcInvocationBinding(
            selector: query.selector,
            options: query.options,
            prepareImages: false
        )
        let plan = ObjCInvocationPlan(
            ABICopyObjCInvocationPlan(binding.handle),
            declaration: binding.declaration
        )
        let prepared: ObjCCallSignature<Result, repeat each Argument> =
            try await NativePreparation.run {
                var error: NSError?
                guard ABIObjCPrepareInvocationPlan(plan.handle, &error) else {
                    throw objcResolutionError(error, declaration: plan.declaration)
                }
                return try ObjCCallSignature(
                    handle: plan.handle,
                    declaration: plan.declaration,
                    variadicFrom: query.variadicFrom,
                    reportsErrors: query.reportsErrors
                )
            }
        return NativeBoundObjCMethod(binding: binding, signature: prepared)
    }

    private func objcInvocationBinding(
        selector: String,
        options: NativeMethodOptions,
        prepareImages: Bool
    ) throws -> ObjCInvocationBinding {
        let receiverType = object_getClass(receiver!)!
        let declaration = objcMethodDeclaration(
            on: receiverType,
            selector: selector,
            classMethod: class_isMetaClass(receiverType)
        )
        var error: NSError?
        let handle = options.withConsumedArguments { consumed in
            let copy = prepareImages ? ABICopyObjCInvocation : ABICopyObjCInvocationMetadata
            return copy(
                receiver!,
                NSSelectorFromString(selector),
                options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
                options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1,
                consumed.baseAddress,
                consumed.count,
                &error
            )
        }
        guard let handle else {
            throw objcResolutionError(error, declaration: declaration)
        }
        return ObjCInvocationBinding(handle, declaration: declaration)
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
    let declaration: NativeDeclaration
    let owner: Any?
    init(_ handle: OpaquePointer, declaration: NativeDeclaration, retaining owner: Any? = nil) {
        self.handle = handle
        self.declaration = declaration
        self.owner = owner
    }
    convenience init(plan: ObjCInvocationPlan, retaining owner: Any? = nil) {
        ABIRetainObjCInvocation(plan.handle)
        self.init(plan.handle, declaration: plan.declaration, retaining: owner)
    }
    deinit { withExtendedLifetime(owner) { ABIReleaseObjCInvocation(handle) } }
}

// The native parent contains immutable signature metadata and image leases, never
// a receiver or caller-owned code owner. Its reference count is atomic. A worker
// finishes image preparation before this wrapper is returned to the caller.
final class ObjCInvocationPlan: Sendable {
    private let address: UInt
    var handle: OpaquePointer { OpaquePointer(bitPattern: address)! }
    let declaration: NativeDeclaration

    init(_ handle: OpaquePointer, declaration: NativeDeclaration) {
        address = UInt(bitPattern: handle)
        self.declaration = declaration
    }

    deinit { ABIReleaseObjCInvocation(handle) }
}

/// A typed Objective-C method bound to a retained receiver.
///
/// The handle can be reused without repeating signature decoding. Invocation creates an independent argument frame for every call and has no fixed limit on the number of explicit arguments. See <doc:ObjectiveCInvocation>.
public struct NativeBoundObjCMethod<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let signature: ObjCCallSignature<Result, repeat each Argument>

    /// The prepared message, independent of this retained receiver binding.
    ///
    /// The returned handle shares the signature and code owner without repeating lookup or decoding. Calls on another compatible receiver use current message dispatch and validate that receiver's actual signature.
    public var method: NativeObjCMethod<Result, repeat each Argument> {
        NativeObjCMethod(
            binding: ObjCInvocationBinding(
                ABICopyObjCInvocationPlan(binding.handle),
                declaration: binding.declaration,
                retaining: binding.owner
            ),
            signature: signature
        )
    }

    init(
        binding: ObjCInvocationBinding,
        variadicFrom: Int? = nil,
        reportsErrors: Bool = false
    ) throws {
        self.binding = binding
        signature = try ObjCCallSignature(
            handle: binding.handle,
            declaration: binding.declaration,
            variadicFrom: variadicFrom,
            reportsErrors: reportsErrors
        )
    }

    init(
        binding: ObjCInvocationBinding,
        signature: ObjCCallSignature<Result, repeat each Argument>
    ) {
        self.binding = binding
        self.signature = signature
    }

    /// Calls the method using normal Objective-C dispatch.
    ///
    /// The caller honors the receiver's actor/thread requirements, pointer lifetimes, ownership annotations, block signatures, and nullability. Retainable arguments stay alive for the call and results use Swift ownership. An Objective-C exception is thrown as ``NativeObjCException``; a method prepared with a `throws` signature throws the `NSError` it reports.
    ///
    /// - Parameter values: Explicit arguments, excluding self and the selector.
    /// - Returns: The result converted to the requested Swift type.
    /// - Throws: A conversion or invocation error, including unexpected nil.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try signature.invoke(
            repeat each values,
            using: { addresses, output in
                var error: NSError?
                let success: Bool
                if let interface = signature.variadicInterface {
                    success = ABIInvokeVariadicObjCInvocation(
                        binding.handle,
                        interface.handle,
                        output,
                        addresses.baseAddress,
                        &error
                    )
                } else {
                    success = ABIInvokeObjCInvocation(
                        binding.handle,
                        output,
                        addresses.baseAddress,
                        &error
                    )
                }
                guard success else {
                    throw objcResolutionError(error, declaration: binding.declaration)
                }
            }
        )
    }
}

struct ObjCMethodSignature<Result, each Argument>: Sendable {
    let arguments: (repeat ObjCValueCodec<each Argument>)
    let result: ObjCValueCodec<Result>
    private let storageLayout: NativeCallStorageLayout
    let variadicInterface: CCallInterface?
    /// Whether the native method has a trailing `NSError **` parameter that
    /// the Swift arguments omit.
    let hasErrorSlot: Bool

    init(
        handle: OpaquePointer,
        declaration: NativeDeclaration,
        variadicFrom: Int? = nil,
        errorSlot: Bool = false
    ) throws {
        var count = 0
        for _ in repeat (each Argument).self { count += 1 }
        let fixedCount = ABIObjCInvocationParameterCount(handle) - (errorSlot ? 1 : 0)
        guard variadicFrom.map({ $0 == fixedCount && count >= $0 }) ?? (count == fixedCount) else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    declaration: declaration,
                    position: .argumentCount,
                    expected: "\(count) arguments",
                    found: ["\(fixedCount) arguments"]
                )
            )
        }
        var index = 0
        func makeCodec<Value>(_ type: Value.Type) throws -> ObjCValueCodec<Value> {
            defer { index += 1 }
            do {
                if let variadicFrom, index >= variadicFrom {
                    return try .init(anonymousParameter: type)
                }
                return try .init(
                    encoding: String(cString: ABIObjCInvocationParameterType(handle, index)),
                    size: ABIObjCInvocationParameterSize(handle, index)
                )
            } catch let ABIResolutionError.signatureMismatch(mismatch) {
                throw ABIResolutionError.signatureMismatch(
                    mismatch.inContext(declaration, at: .argument(index))
                )
            }
        }
        // Swift 6.3 IRGen cannot clean up an incompletely initialized stored
        // parameter pack when the result codec throws. Prepare both locally.
        let arguments = (repeat try makeCodec((each Argument).self))
        let result: ObjCValueCodec<Result>
        do {
            result = try .init(
                encoding: String(cString: ABIObjCInvocationResultType(handle)),
                size: ABIObjCInvocationResultSize(handle)
            )
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            throw ABIResolutionError.signatureMismatch(mismatch.inContext(declaration, at: .result))
        }
        let variadicInterface: CCallInterface?
        if let variadicFrom {
            var parameters = [
                try CValueType(scalar: ABIValuePointer), try CValueType(scalar: ABIValuePointer),
            ]
            for codec in repeat each arguments { parameters.append(try codec.cType()) }
            variadicInterface = try CCallInterface(
                result: result.cType(),
                parameters: parameters,
                fixedParameterCount: variadicFrom + 2
            )
        } else {
            variadicInterface = nil
        }
        var layouts: [(size: Int, alignment: Int)] = []
        for codec in repeat each arguments { layouts.append((codec.size, codec.alignment)) }
        if errorSlot {
            layouts.append(
                (MemoryLayout<UnsafeRawPointer>.size, MemoryLayout<UnsafeRawPointer>.alignment)
            )
        }
        storageLayout = try NativeCallStorageLayout(
            result: (result.size, result.alignment),
            parameters: layouts
        )
        self.arguments = arguments
        self.result = result
        self.variadicInterface = variadicInterface
        hasErrorSlot = errorSlot
    }

    func callInterface() throws -> CCallInterface {
        if let variadicInterface { return variadicInterface }
        var parameters = [
            try CValueType(scalar: ABIValuePointer), try CValueType(scalar: ABIValuePointer),
        ]
        for codec in repeat each arguments { parameters.append(try codec.cType()) }
        if hasErrorSlot { parameters.append(try CValueType(scalar: ABIValuePointer)) }
        return try CCallInterface(result: result.cType(), parameters: parameters)
    }

    /// - Parameter errorSlot: The `NSError **` argument, for a signature with an error slot.
    func invoke(
        _ values: repeat each Argument,
        errorSlot: UnsafeMutableRawPointer? = nil,
        using body: (UnsafeBufferPointer<UnsafeRawPointer>, UnsafeMutableRawPointer) throws -> Void
    ) throws -> Result {
        try storageLayout.withStorage { addresses, output in
            var owners: [AnyObject] = []
            var index = 0
            for (codec, value) in repeat (each arguments, each values) {
                if let owner = try codec.encode(value, into: addresses[index]!) {
                    owners.append(owner)
                }
                index += 1
            }
            if hasErrorSlot {
                addresses[index]!.storeBytes(of: errorSlot, as: UnsafeMutableRawPointer?.self)
            }
            return try withExtendedLifetime(owners) {
                try addresses.withMemoryRebound(to: UnsafeRawPointer.self) { addresses in
                    try body(UnsafeBufferPointer(addresses), output)
                    return try result.decode(output)
                }
            }
        }
    }
}

extension NativeObject {

}
