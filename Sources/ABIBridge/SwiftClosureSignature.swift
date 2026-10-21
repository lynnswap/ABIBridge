import ABIBridgeRuntime
import ABIBridgeCore
import Synchronization

// The SIL discriminator hashes formal value types, not their register widths.
// Class identity, isolation, and ownership qualifiers are intentionally erased.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenPointerAuth.cpp
func swiftClosureAuthType(_ type: Any.Type) throws -> String {
    guard !(type is any SwiftConventionArgument.Type) else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Inout and ownership-qualified callback parameters require a scoped native adapter."
        )
    }
    // An indirect parameter or result is hashed opaquely.
    if let value = type as? any ABIBridgeSwiftValue.Type {
        guard let components = value.swiftABIType.cType else { return "-indirect" }
        if withExtendedLifetime(components, { ABISwiftValueIsIndirect(components.handle) }) {
            return "-indirect"
        }
    }
    // A native Optional function keeps the function pair's storage.
    var payload = type
    while let optional = payload as? any NativeOptionalValue.Type { payload = optional.wrappedType }
    if type is any NativeOptionalValue.Type, !RuntimeFunctionMetadata.isSwiftFunction(payload) {
        func layout<Value>(_: Value.Type) throws -> CValueType { try SwiftValueCodec<Value>().type }
        let layout = try _openExistential(type, do: layout)
        if withExtendedLifetime(layout, { ABISwiftValueIsIndirect(layout.handle) }) {
            return "-indirect"
        }
    }
    return try swiftClosureTypeHash(type)
}

/// Swift's `hashStringForType`, which hashes a value type within any Optionals.
private func swiftClosureTypeHash(_ type: Any.Type) throws -> String {
    if let closure = type as? any SwiftClosureValue.Type, !closure.isOptional {
        return "("
            + (try SwiftFunctionSignature(closure.swiftFunctionType).closureAuthDescription()) + ")"
    }
    if RuntimeFunctionMetadata.isSwiftFunction(type) {
        return "(" + (try SwiftFunctionSignature(type).closureAuthDescription()) + ")"
    }
    if let optional = type as? any NativeOptionalValue.Type {
        let wrapped = optional.wrappedType
        // An Optional of a class-based value or a metatype hashes as the value.
        if let existential = SwiftExistentialRepresentation(wrapped) {
            return existential.closureAuthType(optional: true)
        }
        if let metatype = SwiftMetatypeMetadata(wrapped) {
            return metatype.isExistential ? "Optional<-metatype>" : "-metatype"
        }
        if wrapped is AnyClass || wrapped == AnyObject.self { return "-class" }
        return "Optional<" + (try swiftClosureTypeHash(wrapped)) + ">"
    }
    let managed = type is any ABIBridgeSwiftValue.Type
    guard !(type is any ABIBridgeValue.Type) || managed else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Closure signatures require built-in or explicitly described Swift values; foreign conversions are not supported."
        )
    }
    if type is AnyClass || type == AnyObject.self { return "-class" }
    if SwiftMetatypeMetadata(type) != nil { return "-metatype" }
    if let existential = SwiftExistentialRepresentation(type) {
        return existential.closureAuthType(optional: false)
    }
    // A tuple within an Optional is hashed opaquely; parameters expand tuples.
    if SwiftTupleMetadata(type) != nil { return "-" }
    guard var name = _mangledTypeName(type) else {
        throw ABIResolutionError.metadataUnavailable(
            "No Swift closure type identity for \(String(reflecting: type))."
        )
    }
    // SIL hashes these nominal declarations without their generic substitutions.
    if let collection = type as? any SwiftCollectionValue.Type {
        name = collection.mangledDeclaration
    }
    if (managed || type is any NativePointerValue.Type), name.hasSuffix("G") {
        name = try swiftNominalClosureName(name)
    }
    return "$s" + name
}

// A bound nominal mangling contains its declaration before the generic
// argument list. Let Swift's demangler validate candidate prefixes rather than
// interpreting identifier lengths, word substitutions, or nested contexts here.
private func swiftNominalClosureName(_ mangled: String) throws -> String {
    guard let fullName = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No generic Swift value identity.")
    }
    var nominalName = "", depth = 0
    for character in fullName {
        if character == "<" {
            depth += 1
        } else if character == ">" {
            depth -= 1
        } else if depth == 0 {
            nominalName.append(character)
        }
    }
    for index in mangled.indices where mangled[index] == "y" {
        let candidate = String(mangled[..<index])
        if DeclarationKey.demangle("$s" + candidate, language: .swift) == nominalName {
            return candidate
        }
    }
    throw ABIResolutionError.unsupportedDeclaration(
        "Cannot establish the nominal closure identity for " + fullName + "."
    )
}

func swiftClosureAuthTypes(_ type: Any.Type) throws -> [String] {
    if let convention = type as? any SwiftConventionArgument.Type {
        if convention.convention == .inoutValue { return ["-indirect"] }
        return try swiftClosureAuthTypes(convention.wrappedType)
    }
    if let tuple = SwiftTupleMetadata(type) {
        return try tuple.elements.flatMap { try swiftClosureAuthTypes($0.type) }
    }
    return [try swiftClosureAuthType(type)]
}

// ABI-stable SipHash-2-4, with LLVM's fixed ptrauth key and nonzero 16-bit range.
// https://github.com/llvm/llvm-project/blob/main/llvm/lib/Support/SipHash.cpp

protocol SwiftClosureValue: SendableMetatype {
    static var swiftFunctionType: Any.Type { get }
    /// Whether the host value is an Optional of a closure, whose formal type
    /// is an Optional of `swiftFunctionType`.
    static var isOptional: Bool { get }
    static func makeClosureCodec() throws -> SwiftClosureCodec
    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec
    func encodeGenericClosure(
        plan: SwiftGenericClosurePlan,
        retainingCode owner: Any?,
        asynchronous: Bool,
        consuming: Bool
    ) throws -> NativeValueStorage
    func encodeClosure(consuming: Bool) throws -> NativeValueStorage
    func encodeClosureResult() throws -> NativeValueStorage
    func retainingAsynchronousArgument(consuming: Bool) throws -> Any
}

extension SwiftClosureValue {
    static var isOptional: Bool { false }
    func encodeClosureResult() throws -> NativeValueStorage { try encodeClosure(consuming: false) }
}

// Swift represents a nil closure with a null function pointer, so an Optional
// closure has the closure's storage and calling convention, and its other
// word is unspecified.
extension Optional: SwiftClosureValue where Wrapped: SwiftClosureValue {
    static var swiftFunctionType: Any.Type { Wrapped.swiftFunctionType }
    static var isOptional: Bool { true }

    static func makeClosureCodec() throws -> SwiftClosureCodec {
        try requireSingleLevel()
        return try Wrapped.makeClosureCodec().optional(Self.self)
    }

    static func makeGenericClosureCodec(plan: SwiftGenericClosurePlan) throws -> SwiftClosureCodec {
        try requireSingleLevel()
        return try Wrapped.makeGenericClosureCodec(plan: plan).optional(Self.self)
    }

    // Each Optional level of a closure uses another extra inhabitant of its
    // function pointer, which only a null pointer represents here.
    static func requireSingleLevel() throws {
        guard !Wrapped.isOptional else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Nested Optional closures are unsupported: \(String(reflecting: Self.self))."
            )
        }
    }

    func encodeGenericClosure(
        plan: SwiftGenericClosurePlan,
        retainingCode owner: Any?,
        asynchronous: Bool,
        consuming: Bool
    ) throws -> NativeValueStorage {
        guard let self else { return SwiftClosureStorage.null() }
        return try self.encodeGenericClosure(
            plan: plan,
            retainingCode: owner,
            asynchronous: asynchronous,
            consuming: consuming
        )
    }

    func encodeClosure(consuming: Bool) throws -> NativeValueStorage {
        guard let self else { return SwiftClosureStorage.null() }
        return try self.encodeClosure(consuming: consuming)
    }

    func encodeClosureResult() throws -> NativeValueStorage {
        guard let self else { return SwiftClosureStorage.null() }
        return try self.encodeClosureResult()
    }

    func retainingAsynchronousArgument(consuming: Bool) throws -> Any {
        guard let self else { return Self.none as Any }
        return Self.some(try self.retainingAsynchronousArgument(consuming: consuming) as! Wrapped)
            as Any
    }
}

// Cold host calls suspend while their ABI is prepared. Acquire callback borrows
// before that suspension, and pass the same access to the later argument encoder.
// Tuple copies and closure/context ownership stay in the caller's isolation domain.
func swiftRetainingAsynchronousClosureArgument<Value>(
    _ value: Value,
    consuming: Bool = false
) throws -> Value {
    if let closure = value as? any SwiftClosureValue {
        return try closure.retainingAsynchronousArgument(consuming: consuming) as! Value
    }
    if let convention = value as? any SwiftConventionArgument {
        return try convention.retainingAsynchronousClosureArgument() as! Value
    }
    guard let tuple = SwiftTupleMetadata(Value.self) else { return value }
    var retained = value
    try withUnsafeMutablePointer(to: &retained) { pointer in
        let address = UnsafeMutableRawPointer(pointer)
        for element in tuple.elements {
            func retain<Element>(_ type: Element.Type) throws {
                let field = address.advanced(by: element.offset).assumingMemoryBound(to: type)
                field.pointee = try swiftRetainingAsynchronousClosureArgument(
                    field.pointee,
                    consuming: consuming
                )
            }
            try _openExistential(element.type, do: retain)
        }
    }
    return retained
}

extension SwiftClosureCodec {
    /// A codec for an Optional of this codec's closures, which reads a null
    /// function pointer as nil.
    func optional<Wrapped>(_: Wrapped?.Type) -> SwiftClosureCodec {
        @Sendable func none() -> Any { Wrapped?.none as Any }
        @Sendable func some(_ value: Any) -> Any { Wrapped?.some(value as! Wrapped) as Any }
        var encoding: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
        if let encode = encodeValue {
            encoding = { value, owner in
                guard let wrapped = value as! Wrapped? else { return SwiftClosureStorage.null() }
                return try encode(wrapped, owner)
            }
        }
        var borrowing: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)?
        if let borrow = borrowValue {
            borrowing = { access, lifetime in
                // The callback decoder starts this borrow on the current
                // thread; a failed read leaves the error to the closure's use.
                let isNull = try? access.withAddress {
                    $0.load(as: ABISwiftClosureValue.self).function == nil
                }
                return isNull == true ? none() : some(borrow(access, lifetime))
            }
        }
        var taking: (@Sendable (ABISwiftClosureValue, SwiftValueCodeLifetime?) -> Any)?
        if let take = takeValue {
            taking = { value, lifetime in
                value.function == nil ? none() : some(take(value, lifetime))
            }
        }
        let makeValue = self.makeValue
        return SwiftClosureCodec(
            type: type,
            nativePlan: nativePlan,
            encoding: encoding,
            borrowing: borrowing,
            taking: taking
        ) { value, owner, taking, lifetime in
            value.function == nil ? none() : some(try makeValue(value, owner, taking, lifetime))
        }
    }
}

struct SwiftClosureCodec: Sendable {
    let type: CValueType
    let nativePlan: SwiftGenericClosurePlan?
    let encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)?
    let borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)?
    let takeValue: (@Sendable (ABISwiftClosureValue, SwiftValueCodeLifetime?) -> Any)?
    let makeValue:
        @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any

    init(
        type: CValueType,
        nativePlan: SwiftGenericClosurePlan? = nil,
        encoding encodeValue: (@Sendable (Any, Any?) throws -> NativeValueStorage)? = nil,
        borrowing borrowValue: (@Sendable (SwiftValueBorrow, SwiftValueCodeLifetime?) -> Any)? =
            nil,
        taking takeValue: (@Sendable (ABISwiftClosureValue, SwiftValueCodeLifetime?) -> Any)? = nil,
        makeValue:
            @escaping @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws
            -> Any
    ) {
        self.type = type
        self.nativePlan = nativePlan
        self.encodeValue = encodeValue
        self.borrowValue = borrowValue
        self.takeValue = takeValue
        self.makeValue = makeValue
    }
}

final class SwiftClosureStorage {
    let value: ABISwiftClosureValue
    private let ownsContext: Bool
    let callbackFactory: SwiftClosureBodyFactory?
    let implementation: SwiftImplementation
    let codeOwner: Any?
    let codeLifetime: SwiftValueCodeLifetime?

    // Consumes one native context reference, including on preparation failure.
    init(
        adopting value: ABISwiftClosureValue,
        discriminator: UInt16,
        retaining owner: Any?,
        codeLifetime: SwiftValueCodeLifetime? = nil,
        ownsContext: Bool = true,
        implementation prepared: SwiftImplementation? = nil
    ) throws {
        self.ownsContext = ownsContext
        do {
            guard let function = ABIAuthenticateSwiftClosureFunction(value.function, discriminator)
            else {
                throw ABIInvocationError.unexpectedNilResult(expected: "a Swift closure")
            }
            implementation = try prepared ?? SwiftImplementation(function: function, retaining: nil)
        } catch {
            withExtendedLifetime(owner) {
                if ownsContext { ABIReleaseSwiftClosureContext(value.context) }
            }
            throw error
        }
        self.value = value
        let callbackOwner = ABICopySwiftClosureCallbackCodeOwner(
            implementation.function,
            value.context
        ).map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        callbackFactory = ABICopySwiftClosureCallbackBodyOwner(
            implementation.function,
            value.context
        ).map {
            Unmanaged<SwiftClosureBodyFactory>.fromOpaque($0).takeRetainedValue()
        }
        codeOwner = (owner, implementation, callbackOwner)
        let callbackLifetime = (callbackOwner as? SwiftClosureCodeOwner)?.codeLifetime
        let images = implementation.image.map { [$0] } ?? []
        let lifetime =
            codeLifetime ?? callbackLifetime
            ?? (images.isEmpty ? nil : SwiftValueCodeLifetime(images))
        self.codeLifetime = SwiftValueCodeLifetime.connect(
            [lifetime, callbackLifetime].compactMap { $0 },
            retaining: images
        )
    }

    deinit {
        withExtendedLifetime((implementation, codeOwner)) {
            if ownsContext { ABIReleaseSwiftClosureContext(value.context) }
        }
    }

    func encoded(codeLifetime: SwiftValueCodeLifetime? = nil) -> NativeValueStorage {
        if ownsContext {
            return Self.copy(
                value,
                retaining: self,
                codeLifetime: codeLifetime ?? self.codeLifetime
            )
        }
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            owner: self,
            codeLifetime: self.codeLifetime
        )
        storage.store(value)
        return storage
    }

    static func copy(
        _ value: ABISwiftClosureValue,
        retaining owner: AnyObject,
        codeLifetime: SwiftValueCodeLifetime? = nil
    ) -> NativeValueStorage {
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            owner: owner,
            codeLifetime: codeLifetime,
            destroyingWith: destroy
        )
        ABIRetainSwiftClosureContext(value.ownedContext)
        storage.store(value)
        return storage
    }

    static func destroy(_ address: UnsafeMutableRawPointer) {
        ABIReleaseSwiftClosureContext(address.load(as: ABISwiftClosureValue.self).ownedContext)
    }

    /// The zeroed storage of a nil Optional closure. An inout callee can
    /// store an owned closure in it, which its destruction releases.
    static func null() -> NativeValueStorage {
        NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            destroyingWith: destroy
        )
    }
}

// A prepared entry is shared by individual native closure contexts. Preparing
// nested adapters can fail before publication; dispatch only moves valid native
// function pairs and uses the caller's ownership and lifetime guarantees.
final class SwiftNativeClosureAdapter: Sendable {
    private enum Entry: Sendable {
        case synchronous(SwiftClosureCallbackOwner)
        case asynchronous(SwiftAsyncClosureCallbackOwner)
    }
    private struct Field: Sendable {
        let offset: Int
        let adapter: SwiftNativeClosureAdapter
        let reverse: SwiftNativeClosureAdapter?
    }
    // A formal tuple carries leaf addresses; a generic T bound to the same
    // tuple still carries one contiguous native value.
    private struct TupleRepresentation: Sendable {
        let metadata: Any.Type
        let expanded: SwiftTupleValuePlan?
        let projections: [SwiftTupleValuePlan.NativeProjection]
        private let stride: Int
        private let alignment: Int
        private let constants: SwiftValueConstants

        init(metadata: Any.Type, expanded: SwiftTupleValuePlan?) {
            self.metadata = metadata; self.expanded = expanded
            let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
            stride = layout.stride; alignment = layout.alignment
            constants = SwiftValueConstants(metadata)
            func leaves(_ type: Any.Type, at offset: Int) -> [SwiftTupleValuePlan.NativeProjection]
            {
                if let tuple = SwiftTupleMetadata(type) {
                    return tuple.elements.flatMap { leaves($0.type, at: offset + $0.offset) }
                }
                let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
                return [.init(offset: offset, size: layout.size, metadata: type)]
            }
            projections = leaves(metadata, at: 0)
        }

        func makeResultStorage() -> NativeValueStorage {
            expanded?.makeResultStorage()
                ?? NativeValueStorage(
                    size: stride,
                    alignment: alignment,
                    codeLifetime: SwiftValueCodeLifetime.current
                )
        }

        func materializeArgument(
            from source: UnsafeMutableRawPointer,
            consuming: Bool
        ) -> NativeValueStorage {
            if let expanded {
                return expanded.materializeArgument(from: source, consuming: consuming)
            }
            let type = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
            let storage = NativeValueStorage(
                size: stride,
                alignment: alignment,
                codeLifetime: SwiftValueCodeLifetime.current,
                destroyingWith: { value in
                    if consuming {
                        ABISwiftTakeValue(type, source, value)
                    } else {
                        ABISwiftDestroyValue(type, value)
                    }
                }
            )
            if consuming {
                ABISwiftTakeValue(type, storage.address, source)
            } else {
                ABISwiftCopyValue(type, storage.address, source)
            }
            constants.initialize(at: storage.address)
            return storage
        }

        func closure(at offset: Int, result: Bool) throws -> SwiftGenericClosurePlan {
            for leaf in expanded?.leaves ?? [] where leaf.nativeOffset == offset {
                if let closure = leaf.nativeClosure { return closure }
                if result, case .closure(let codec) = leaf.result { return codec.nativePlan! }
                if !result, let closure = leaf.argument.closure { return closure }
            }
            let projection = projections.first {
                $0.offset == offset
                    && unsafeBitCast($0.metadata, to: UnsafeRawPointer.self).load(as: UInt.self)
                        == 0x302
            }!
            return try SwiftGenericClosurePlan.nativeValue(projection.metadata)
        }

        func closureOffsets(result: Bool) -> [Int] {
            expanded?.leaves.compactMap { leaf in
                if leaf.nativeClosure != nil { return leaf.nativeOffset }
                if result, case .closure = leaf.result { return leaf.nativeOffset }
                if !result, leaf.argument.closure != nil { return leaf.nativeOffset }
                return nil
            } ?? []
        }
    }
    private enum ValueConversion: Sendable {
        case closure(SwiftNativeClosureAdapter, reverse: SwiftNativeClosureAdapter?)
        case tuple(source: TupleRepresentation, target: TupleRepresentation, fields: [Field])
    }
    private struct Argument: Sendable {
        let index: Int
        let conversion: ValueConversion
        let convention: SwiftArgumentConvention
        let escaping: Bool
    }
    private struct Arguments {
        let encoded: SwiftGenericParameters.Encoded
        let storage: [NativeValueStorage]
        let consumed: [NativeValueStorage]
        let writebacks: [() -> Void]

        func finishInvocation() {
            encoded.finishInvocation()
            for value in consumed { value.relinquishValue() }
            for writeback in writebacks { writeback() }
        }
    }
    private let source: SwiftGenericClosurePlan
    private let target: SwiftGenericClosurePlan
    private let arguments: [Argument]
    private let result: ValueConversion?
    private let initializeNativeResult: SwiftResultInitializer
    private let entry: Entry

    init(source: SwiftGenericClosurePlan, target: SwiftGenericClosurePlan) throws {
        try source.validateNativeValues(for: target)
        self.source = source; self.target = target
        let sourceResultTuple = source.result.tuple
        let resultTuple = target.result.tuple
        initializeNativeResult = swiftResultInitializer(
            nativeMetadata: target.nativeResult,
            generic: target.result,
            tuple: resultTuple
        )
        arguments = try zip(source.parameters.arguments, target.parameters.arguments).enumerated()
            .compactMap { index, pair in
                let convention = pair.1.convention
                if pair.0.tuple != nil || pair.1.tuple != nil {
                    let expected = TupleRepresentation(
                        metadata: source.nativeParameters[index],
                        expanded: pair.0.tuple
                    )
                    let incoming = TupleRepresentation(
                        metadata: target.nativeParameters[index],
                        expanded: pair.1.tuple
                    )
                    let fields = try Self.argumentFields(
                        source: incoming,
                        target: expected,
                        mutable: convention == .inoutValue
                    )
                    return Argument(
                        index: index,
                        conversion: .tuple(source: incoming, target: expected, fields: fields),
                        convention: convention,
                        escaping: true
                    )
                }
                guard let expected = source.nativeArgumentClosures[index],
                    let incoming = target.nativeArgumentClosures[index]
                else { return nil }
                let adapter = try SwiftNativeClosureAdapter(source: incoming, target: expected)
                let reverse =
                    try convention == .inoutValue
                    ? SwiftNativeClosureAdapter(source: expected, target: incoming) : nil
                return Argument(
                    index: index,
                    conversion: .closure(adapter, reverse: reverse),
                    convention: convention,
                    escaping: incoming.isEscaping
                )
            }
        if let produced = source.nativeResultClosure, let expected = target.nativeResultClosure {
            result = .closure(
                try SwiftNativeClosureAdapter(source: produced, target: expected),
                reverse: nil
            )
        } else if sourceResultTuple != nil || resultTuple != nil {
            let expected = TupleRepresentation(metadata: target.nativeResult, expanded: resultTuple)
            let produced = TupleRepresentation(
                metadata: source.nativeResult,
                expanded: sourceResultTuple
            )
            result = .tuple(
                source: produced,
                target: expected,
                fields: try Self.resultFields(source: produced, target: expected)
            )
        } else {
            result = nil
        }
        var failure: OpaquePointer?
        switch target.transport {
        case .synchronous(let interface):
            var functions = ABISwiftThrowingClosureCallbackFunctions()
            functions.usesNativeContext = true
            functions.invoke = { context, arguments, result, error in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue()
                return value.adapter.invoke(
                    value,
                    arguments: arguments,
                    result: result!,
                    error: error
                )
            }
            functions.initializeResult = { context, offset, size, destination, source in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue()
                SwiftValueCodeLifetime.withCurrent(value.codeLifetime) {
                    value.adapter.initializeNativeResult(offset, size, destination!, source!)
                }
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard
                let handle = ABICreateSwiftThrowingClosureCallback(
                    interface.handle,
                    functions,
                    nil,
                    &failure
                )
            else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
            }
            entry = .synchronous(try SwiftClosureCallbackOwner(handle: handle))
        case .asynchronous(let interface, _):
            var functions = ABISwiftAsyncClosureCallbackFunctions()
            functions.usesNativeContext = true
            functions.createBody = { context, arguments, result, error, didThrow in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue()
                let body = SwiftAsyncClosureBody(
                    inheritsCallerIsolation: value.adapter.inheritsCallerIsolation,
                    codeLifetime: value.codeLifetime
                ) { arguments, result, error in
                    await value.adapter.invokeAsync(
                        value,
                        arguments: arguments,
                        result: result,
                        error: error
                    )
                }
                let invocation = SwiftAsyncClosureInvocation(
                    body,
                    arguments,
                    result!,
                    error,
                    didThrow!
                )
                if body.inheritsCallerIsolation {
                    let operation: nonisolated(nonsending) @Sendable () async -> Void = {
                        await invocation.run()
                    }
                    return retainedValue(operation)
                }
                let operation: @Sendable @concurrent () async -> Void = { await invocation.run() }
                return retainedValue(operation)
            }
            functions.initializeResult = { context, offset, size, destination, source in
                let value = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue()
                SwiftValueCodeLifetime.withCurrent(value.codeLifetime) {
                    value.adapter.initializeNativeResult(offset, size, destination!, source!)
                }
            }
            functions.copyCodeOwner = { context in
                let owner = Unmanaged<SwiftNativeClosureContext>.fromOpaque(context!)
                    .takeUnretainedValue().codeOwner
                return Unmanaged.passRetained(owner).toOpaque()
            }
            guard
                let handle = ABICreateSwiftAsyncClosureCallback(
                    interface.handle,
                    functions,
                    nil,
                    &failure
                )
            else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
            }
            entry = .asynchronous(try SwiftAsyncClosureCallbackOwner(handle: handle))
        }
    }

    private static func argumentFields(
        source: TupleRepresentation,
        target: TupleRepresentation,
        mutable: Bool
    ) throws -> [Field] {
        let offsets = Set(
            source.closureOffsets(result: false) + target.closureOffsets(result: false)
        ).sorted()
        return try offsets.map { offset in
            let incoming = try source.closure(at: offset, result: false)
            let expected = try target.closure(at: offset, result: false)
            return Field(
                offset: offset,
                adapter: try SwiftNativeClosureAdapter(source: incoming, target: expected),
                reverse: try mutable
                    ? SwiftNativeClosureAdapter(source: expected, target: incoming) : nil
            )
        }
    }

    private static func resultFields(
        source: TupleRepresentation,
        target: TupleRepresentation
    ) throws -> [Field] {
        let offsets = Set(source.closureOffsets(result: true) + target.closureOffsets(result: true))
            .sorted()
        return try offsets.map { offset in
            Field(
                offset: offset,
                adapter: try SwiftNativeClosureAdapter(
                    source: source.closure(at: offset, result: true),
                    target: target.closure(at: offset, result: true)
                ),
                reverse: nil
            )
        }
    }

    private var inheritsCallerIsolation: Bool {
        if case .asynchronous(_, let isolation) = target.transport { return isolation }
        return false
    }

    func encode(
        _ value: ABISwiftClosureValue,
        taking: Bool,
        escaping: Bool,
        retainingValue valueOwner: AnyObject? = nil,
        retainingCode owner: Any?,
        codeLifetime: SwiftValueCodeLifetime?
    ) -> NativeValueStorage {
        let context = SwiftNativeClosureContext(
            adapter: self,
            value: value,
            taking: taking,
            escaping: escaping,
            retainingValue: valueOwner,
            retainingCode: owner,
            codeLifetime: codeLifetime
        )
        let function: UnsafeRawPointer?
        switch entry {
        case .synchronous(let entry):
            function = ABISignSwiftClosureFunction(entry.function, target.discriminator)
        case .asynchronous(let entry):
            function = ABISignSwiftAsyncClosureDescriptor(
                ABISwiftAsyncClosureCallbackDescriptor(entry.handle),
                target.discriminator
            )
        }
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            codeLifetime: codeLifetime,
            destroyingWith: SwiftClosureStorage.destroy
        )
        storage.store(
            ABISwiftClosureValue(
                function: function,
                context: Unmanaged.passRetained(context).toOpaque()
            )
        )
        return storage
    }

    private func convertArguments(
        _ incoming: UnsafePointer<UnsafeMutableRawPointer?>?,
        context: SwiftNativeClosureContext
    )
        -> Arguments
    {
        let unpacked = target.parameters.unpack(incoming)
        var addresses = unpacked.addresses
        var storage = unpacked.storage
        var consumed: [NativeValueStorage] = []
        var writebacks: [() -> Void] = []
        for argument in arguments {
            let address = addresses[argument.index]!
            switch argument.conversion {
            case .closure(let adapter, let reverse):
                let mutable = argument.convention == .inoutValue
                let source = mutable ? address.load(as: UnsafeMutableRawPointer.self) : address
                let encoded = adapter.encode(
                    source.load(as: ABISwiftClosureValue.self),
                    taking: argument.convention == .consuming,
                    escaping: mutable || argument.escaping,
                    retainingCode: context.codeOwner,
                    codeLifetime: context.codeLifetime
                )
                storage.append(encoded)
                if argument.convention == .consuming { consumed.append(encoded) }
                if let reverse {
                    let pointer = NativeValueStorage(
                        size: MemoryLayout<UnsafeMutableRawPointer>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment,
                        owner: encoded
                    )
                    pointer.store(encoded.address)
                    storage.append(pointer)
                    addresses[argument.index] = pointer.address
                    writebacks.append {
                        let replacement = reverse.encode(
                            encoded.address.load(as: ABISwiftClosureValue.self),
                            taking: true,
                            escaping: true,
                            retainingCode: context.codeOwner,
                            codeLifetime: context.codeLifetime
                        )
                        encoded.relinquishValue()
                        let previous = source.load(as: ABISwiftClosureValue.self)
                        source.storeBytes(
                            of: replacement.address.load(as: ABISwiftClosureValue.self),
                            as: ABISwiftClosureValue.self
                        )
                        replacement.relinquishValue()
                        ABIReleaseSwiftClosureContext(previous.ownedContext)
                    }
                } else {
                    addresses[argument.index] = encoded.address
                }
            case .tuple(let incoming, let expected, let fields):
                let mutable = argument.convention == .inoutValue
                let native: NativeValueStorage
                if mutable {
                    native = incoming.makeResultStorage()
                    let source = address.load(as: UnsafeMutableRawPointer.self)
                    let metadata = unsafeBitCast(incoming.metadata, to: UnsafeRawPointer.self)
                    ABISwiftCopyValue(metadata, native.address, source)
                    native.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
                    let previous = incoming.makeResultStorage()
                    writebacks.append {
                        Self.reabstractFields(
                            fields,
                            at: native.address,
                            reverse: true,
                            context: context
                        )
                        ABISwiftTakeValue(metadata, previous.address, source)
                        previous.assumeInitialized { ABISwiftDestroyValue(metadata, $0) }
                        ABISwiftTakeValue(metadata, source, native.address)
                        native.relinquishValue()
                    }
                } else {
                    native = incoming.materializeArgument(
                        from: address,
                        consuming: argument.convention == .consuming
                    )
                    if argument.convention == .consuming { consumed.append(native) }
                }
                Self.reabstractFields(fields, at: native.address, reverse: false, context: context)
                storage.append(native)
                if mutable {
                    let pointer = NativeValueStorage(
                        size: MemoryLayout<UnsafeMutableRawPointer>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment,
                        owner: native
                    )
                    pointer.store(native.address)
                    storage.append(pointer)
                    addresses[argument.index] = pointer.address
                } else if let expanded = expected.expanded {
                    let vector = NativeValueStorage(
                        size: expanded.leaves.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                        alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment,
                        owner: native
                    )
                    for (index, address) in expanded.nativeArgumentAddresses(native.address)
                        .enumerated()
                    {
                        vector.address.storeBytes(
                            of: address,
                            toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                            as: UnsafeMutableRawPointer?.self
                        )
                    }
                    storage.append(vector)
                    addresses[argument.index] = vector.address
                } else {
                    addresses[argument.index] = native.address
                }
            }
        }
        return Arguments(
            encoded: source.parameters.encode(addresses),
            storage: storage,
            consumed: consumed,
            writebacks: writebacks
        )
    }

    private static func reabstractFields(
        _ fields: [Field],
        at address: UnsafeMutableRawPointer,
        reverse: Bool,
        context: SwiftNativeClosureContext
    ) {
        for field in fields {
            let location = address.advanced(by: field.offset)
            let adapter = reverse ? field.reverse! : field.adapter
            let replacement = adapter.encode(
                location.load(as: ABISwiftClosureValue.self),
                taking: true,
                escaping: true,
                retainingCode: context.codeOwner,
                codeLifetime: context.codeLifetime
            )
            location.storeBytes(
                of: replacement.address.load(as: ABISwiftClosureValue.self),
                as: ABISwiftClosureValue.self
            )
            replacement.relinquishValue()
        }
    }

    private func initializeResult(
        _ storage: NativeValueStorage?,
        at output: UnsafeMutableRawPointer,
        context: SwiftNativeClosureContext
    ) {
        if let result, let storage {
            switch result {
            case .closure(let adapter, _):
                let encoded = adapter.encode(
                    storage.address.load(as: ABISwiftClosureValue.self),
                    taking: true,
                    escaping: true,
                    retainingCode: context.codeOwner,
                    codeLifetime: context.codeLifetime
                )
                output.copyMemory(
                    from: encoded.address,
                    byteCount: MemoryLayout<ABISwiftClosureValue>.size
                )
                encoded.relinquishValue()
            case .tuple(_, let target, let fields):
                source.resultConstants.initialize(at: storage.address)
                Self.reabstractFields(fields, at: storage.address, reverse: false, context: context)
                ABISwiftTakeValue(
                    unsafeBitCast(target.metadata, to: UnsafeRawPointer.self),
                    output,
                    storage.address
                )
            }
        }
        target.resultConstants.initialize(at: output)
    }

    private func resultStorage() -> NativeValueStorage? {
        switch result {
        case .none: nil
        case .closure:
            NativeValueStorage(
                size: MemoryLayout<ABISwiftClosureValue>.stride,
                alignment: MemoryLayout<ABISwiftClosureValue>.alignment
            )
        case .tuple(let source, _, _): source.makeResultStorage()
        }
    }

    private func invoke(
        _ context: SwiftNativeClosureContext,
        arguments: UnsafePointer<UnsafeMutableRawPointer?>?,
        result output: UnsafeMutableRawPointer,
        error: UnsafeMutableRawPointer?
    ) -> Bool {
        guard case .synchronous(let interface) = source.transport else {
            preconditionFailure("A native reabstraction preserves its synchronous convention.")
        }
        let arguments = convertArguments(arguments, context: context)
        let result = resultStorage()
        let unusedError = target.errorPlan == nil ? source.errorPlan?.makeStorage() : nil
        let function = ABIAuthenticateSwiftClosureFunction(
            context.value.function,
            source.discriminator
        )!
        var didThrow = false
        let success = arguments.encoded.addresses.withUnsafeBufferPointer { arguments in
            if source.errorPlan != nil {
                return ABIUnsafeInvokeSwiftThrowingCallInterface(
                    interface.handle,
                    function,
                    result?.address ?? output,
                    arguments.baseAddress,
                    context.value.context,
                    error ?? unusedError?.address,
                    &didThrow,
                    nil
                )
            }
            return ABIUnsafeInvokeSwiftCallInterface(
                interface.handle,
                function,
                result?.address ?? output,
                arguments.baseAddress,
                context.value.context,
                nil
            )
        }
        defer { withExtendedLifetime((context, arguments, unusedError)) {} }
        precondition(success, "A prepared native reabstraction has a valid call frame.")
        arguments.finishInvocation()
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }

    private nonisolated(nonsending) func invokeAsync(
        _ context: SwiftNativeClosureContext,
        arguments: UnsafePointer<UnsafeMutableRawPointer?>?,
        result output: UnsafeMutableRawPointer,
        error: UnsafeMutableRawPointer?
    ) async -> Bool {
        guard case .asynchronous(let interface, _) = source.transport else {
            preconditionFailure("A native reabstraction preserves its asynchronous convention.")
        }
        let arguments = convertArguments(arguments, context: context)
        let pointers = SwiftGenericArgumentBuffer(
            arguments.encoded.addresses.map { UInt(bitPattern: $0) }
        )
        let forwarded = UnsafeRawPointer(bitPattern: pointers.address)!.assumingMemoryBound(
            to: UnsafeMutableRawPointer?.self
        )
        let result = resultStorage()
        let unusedError = target.errorPlan == nil ? source.errorPlan?.makeStorage() : nil
        // The native caller supplies a live descriptor under the prepared ABI.
        // Its code lifetime is inherited from the active native call, so dispatch
        // does not reopen images or perform fallible public-handle preparation.
        let descriptor = ABIAuthenticateSwiftAsyncClosureDescriptor(
            context.value.function,
            source.discriminator
        )!
        let (function, contextSize) = runtimeAsyncDescriptorComponents(descriptor)
        let invocation = ABICreateSwiftAsyncInvocation(
            interface.handle,
            function,
            contextSize,
            result?.address ?? output,
            forwarded,
            context.value.context,
            error ?? unusedError?.address,
            nil
        )
        precondition(
            invocation != nil,
            "A prepared native async reabstraction has a valid call frame."
        )
        defer {
            withExtendedLifetime((context, arguments, pointers, unusedError)) {
                ABIReleaseSwiftAsyncInvocation(invocation!)
            }
        }
        await invokeSwiftAsync(invocation!)
        arguments.finishInvocation()
        let didThrow = ABISwiftAsyncInvocationDidThrow(invocation!)
        if !didThrow { initializeResult(result, at: output, context: context) }
        return didThrow
    }
}

struct SwiftRuntimeClosureConversions: Sendable {
    private struct Field: Sendable {
        let offset: Int
        let toStorage: SwiftNativeClosureAdapter
        let toNative: SwiftNativeClosureAdapter
        let ownsContext: Bool
    }
    private let fields: [Field]
    var isEmpty: Bool { fields.isEmpty }

    init(metadata: Any.Type, tuple: SwiftTupleValuePlan?, closure: SwiftGenericClosurePlan?) throws
    {
        var functions: [(Int, Any.Type, SwiftGenericClosurePlan)] = []
        if let closure { functions.append((0, metadata, closure)) }
        if let tuple {
            functions += tuple.leaves.compactMap { leaf in
                leaf.nativeClosure.map { (leaf.nativeOffset, leaf.nativeType, $0) }
            }
        }
        try self.init(functions: functions)
    }

    init(functions: [(Int, Any.Type, SwiftGenericClosurePlan)]) throws {
        fields = try functions.compactMap { offset, metadata, native in
            let storage = try SwiftGenericClosurePlan.nativeValue(metadata)
            guard !native.hasSameNativeABI(as: storage) else { return nil }
            return Field(
                offset: offset,
                toStorage: try SwiftNativeClosureAdapter(source: native, target: storage),
                toNative: try SwiftNativeClosureAdapter(source: storage, target: native),
                ownsContext: storage.isEscaping
            )
        }
    }

    func apply(
        to storage: NativeValueStorage,
        native: Bool,
        retainingCode owner: Any?,
        codeLifetime: SwiftValueCodeLifetime?
    ) {
        for field in fields {
            let location = storage.address.advanced(by: field.offset)
            let adapter = native ? field.toNative : field.toStorage
            let replacement = adapter.encode(
                location.load(as: ABISwiftClosureValue.self),
                taking: field.ownsContext,
                escaping: field.ownsContext,
                retainingCode: owner,
                codeLifetime: codeLifetime
            )
            location.storeBytes(
                of: replacement.address.load(as: ABISwiftClosureValue.self),
                as: ABISwiftClosureValue.self
            )
            if field.ownsContext {
                replacement.relinquishValue()
            } else {
                storage.retainResource(replacement)
            }
        }
    }
}

private final class SwiftNativeClosureContext {
    let adapter: SwiftNativeClosureAdapter
    let value: ABISwiftClosureValue
    let codeOwner: SwiftClosureCodeOwner
    let codeLifetime: SwiftValueCodeLifetime?
    private let ownsContext: Bool
    private let valueOwner: AnyObject?

    init(
        adapter: SwiftNativeClosureAdapter,
        value: ABISwiftClosureValue,
        taking: Bool,
        escaping: Bool,
        retainingValue valueOwner: AnyObject?,
        retainingCode owner: Any?,
        codeLifetime: SwiftValueCodeLifetime?
    ) {
        self.adapter = adapter; self.value = value; self.codeLifetime = codeLifetime;
        self.valueOwner = valueOwner
        codeOwner = SwiftClosureCodeOwner((adapter, owner), codeLifetime: codeLifetime)!
        ownsContext = taking || escaping
        if escaping && !taking { ABIRetainSwiftClosureContext(value.context) }
    }
    deinit {
        withExtendedLifetime((codeOwner, valueOwner)) {
            if ownsContext { ABIReleaseSwiftClosureContext(value.context) }
        }
    }
}

extension ABISwiftClosureValue {
    /// The context this value holds a reference to. A nil Optional closure
    /// has a null function and an unspecified context.
    var ownedContext: UnsafeMutableRawPointer? { function == nil ? nil : context }
}
