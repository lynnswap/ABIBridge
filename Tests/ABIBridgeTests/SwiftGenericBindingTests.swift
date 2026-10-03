#if DEBUG
@testable import ABIBridge
import ABIBridgeCore
import Foundation
import ManagedSwiftFixtures
import Testing

private protocol GenericSwiftClassOnly: AnyObject {}

protocol GenericOrderingA {}
private protocol GenericOrderingZ {}
private struct GenericOrderingValue: GenericOrderingA, GenericOrderingZ {}
private struct GenericOrderingOwner<Value: GenericOrderingZ> {}

private final class RuntimeBorrowCopy: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<NativeSwiftValue, any Error>?
    func accept(_ value: NativeSwiftBorrowedValue) {
        lock.lock(); defer { lock.unlock() }
        result = Result { try value.copy() }
    }
    func take() throws -> NativeSwiftValue {
        lock.lock(); defer { result = nil; lock.unlock() }
        return try #require(result).get()
    }
}

struct SwiftGenericBindingTests {
    @Test func functionMetadataPreservesCompilerTypeIdentity() throws {
        typealias Borrowing = (borrowing Int64) -> Int64
        typealias Shared = (__shared Int64) -> Int64
        typealias Consuming = (consuming Int64) -> Int64
        typealias Caller = nonisolated(nonsending) (Int64) async -> Int64
        typealias Sending = (sending Int64) -> sending Int64
        let declaration = SwiftGenericDeclaration(parameters: [], requirements: [], arguments: [],
            result: .tuple([]), failure: nil, isAsync: false, consumesArguments: false)
        let binding = try SwiftGenericBinding(declaration: declaration, arguments: [],
            signature: SwiftFunctionSignature(((Int64, ScalarFailure, MainActor.Type) -> Void).self), resolver: .shared)
        let cases: [(String, Any.Type)] = [
            ("(Swift.Int64) -> Swift.Int64", ((Int64) -> Int64).self),
            ("(borrowing Swift.Int64) -> Swift.Int64", Borrowing.self),
            ("(__shared Swift.Int64) -> Swift.Int64", Shared.self),
            ("(inout Swift.Int64) -> Swift.Int64", ((inout Int64) -> Int64).self),
            ("(consuming Swift.Int64) -> Swift.Int64", Consuming.self),
            ("@Sendable (Swift.Int64) -> Swift.Int64", (@Sendable (Int64) -> Int64).self),
            ("@concurrent (Swift.Int64) async -> Swift.Int64", (@concurrent (Int64) async -> Int64).self),
            ("nonisolated(nonsending) (Swift.Int64) async -> Swift.Int64", Caller.self),
            ("(Swift.Int64) throws -> Swift.Int64", ((Int64) throws -> Int64).self),
            ("(Swift.Int64) throws(ManagedSwiftFixtures.ScalarFailure) -> Swift.Int64", ((Int64) throws(ScalarFailure) -> Int64).self),
            ("(Swift.Int64) throws(Swift.Never) -> Swift.Int64", ((Int64) throws(Never) -> Int64).self),
            ("(Swift.Int64) throws(any Error) -> Swift.Int64", ((Int64) throws(any Error) -> Int64).self),
            ("@Swift.MainActor (Swift.Int64) -> Swift.Int64", (@MainActor (Int64) -> Int64).self),
            ("@isolated(any) (Swift.Int64) async -> Swift.Int64", (@isolated(any) (Int64) async -> Int64).self),
            ("(sending Swift.Int64) -> sending Swift.Int64", Sending.self),
            ("@Sendable @Swift.MainActor (inout Swift.Int64) async throws(ManagedSwiftFixtures.ScalarFailure) -> Swift.Int64",
             (@Sendable @MainActor (inout Int64) async throws(ScalarFailure) -> Int64).self),
            ("((Swift.Int64) -> Swift.Int64) -> Swift.Int64", (((Int64) -> Int64) -> Int64).self),
            ("(@escaping (Swift.Int64) -> Swift.Int64) -> Swift.Int64", ((@escaping (Int64) -> Int64) -> Int64).self),
            ("(inout (Swift.Int64) -> Swift.Int64) -> Swift.Int64", ((inout (Int64) -> Int64) -> Int64).self),
        ]
        for (source, expected) in cases {
            #expect(try binding.types(SwiftFormalType(source))[0] == expected, "\(source)")
        }
    }

    @Test func nativeFunctionSyntaxRetainsMetadataAttributes() throws {
        typealias Caller = nonisolated(nonsending) (Int) async -> Int
        typealias Sending = (sending String) -> sending String
        let declaration = SwiftGenericDeclaration(parameters: [], requirements: [], arguments: [],
            result: .tuple([]), failure: nil, isAsync: false, consumesArguments: false)
        let binding = try SwiftGenericBinding(declaration: declaration, arguments: [],
            signature: SwiftFunctionSignature(((Int, String, MainActor.Type) -> Void).self), resolver: .shared)
        let cases: [(String, Any.Type)] = [
            ("$s13ABIAttributes8sendableyyS2iYbcF", (@Sendable (Int) -> Int).self),
            ("$s13ABIAttributes6calleryyS2iYaYCcF", Caller.self),
            ("$s13ABIAttributes10concurrentyyS2iYaYbcF", (@Sendable @concurrent (Int) async -> Int).self),
            ("$s13ABIAttributes6globalyyS2iYbScMYccF", (@MainActor (Int) -> Int).self),
            ("$s13ABIAttributes6erasedyyS2iYaYAcF", (@isolated(any) (Int) async -> Int).self),
            ("$s13ABIAttributes7sendingyyS2SnYuYTcF", Sending.self),
        ]
        for (symbol, expected) in cases {
            let function = try SwiftGenericDeclaration(linkageName: symbol).arguments[0]
            #expect(try binding.types(function)[0] == expected, "\(symbol)")
        }
    }

    @Test func nonescapableBorrowedValuesCannotBecomeOwnedCopies() async throws {
        let module = "ScopedValue_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(swiftModule: module, swiftSource: """
            public struct View: ~Escapable {
                public let number: Int64
                @_lifetime(immortal) public init(_ number: Int64) { self.number = number }
            }
            public func visit(_ body: (borrowing View) -> Void) { body(View(42)) }
            public func save<Value>(_ value: Value) -> Any { value }
            public func explicit<Value: Escapable>(_ value: Value) -> Any { value }
            public func inspect<Value: ~Copyable & ~Escapable>(_ value: borrowing Value) -> Int64 { 42 }
            """, linkArguments: ["-swift-version", "6", "-enable-library-evolution", "-enable-experimental-feature", "Lifetimes"])
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: module + ".View", in: .path(fixture.libraryURL))
        let metadata = await type.metadata
        #expect(SwiftCopyability.accepts(metadata))
        #expect(!SwiftEscapability.accepts(metadata))
        for name in ["save", "explicit"] {
            do {
                _ = try await runtime.swiftFunction(named: module + "." + name + "<A>(A) -> Any",
                    as: ((NativeSwiftBorrowedValue) -> Any).self,
                    genericArguments: [.type(type)], in: .path(fixture.libraryURL))
                Issue.record("A nonescapable borrow was accepted by an Escapable generic parameter")
            } catch ABIResolutionError.signatureMismatch { }
        }
        let inspect = try await runtime.swiftFunction(named: module + ".inspect<A where A: ~Swift.Copyable, A: ~Swift.Escapable>(A) -> Swift.Int64",
            as: ((NativeSwiftBorrowedValue) -> Int64).self,
            genericArguments: [.type(type)], in: .path(fixture.libraryURL))
        let copied = RuntimeBorrowCopy()
        let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void> {
            do { #expect(try unsafe inspect.unsafeInvoke($0) == 42) }
            catch { Issue.record(error) }
            copied.accept($0)
        }
        let visit = try await runtime.swiftFunction(named: module + ".visit((" + module + ".View) -> ()) -> ()",
            as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Void).self, valueABIs: [type: .opaque(named: type.name)], in: .path(fixture.libraryURL))
        try unsafe visit.unsafeInvoke(callback)
        do {
            _ = try copied.take()
            Issue.record("A nonescapable native borrow escaped into an owned runtime value")
        } catch ABIResolutionError.unsupportedDeclaration { }
        let plan = try SwiftRuntimeValuePlan(metadata: metadata, type: SwiftGenericParameters.storageType(metadata),
            resolver: .shared, retaining: [type.image])
        #expect(throws: ABIResolutionError.self) {
            _ = try SwiftResultCodec<NativeSwiftValue>(generic: .runtimeValue(plan))
        }
    }

    enum RuntimeDependencyOperation: CaseIterable {
        case copiedResult, asyncMovedResult, receiverResult, asyncReceiverResult
        case addressReceiverResult, asyncAddressReceiverResult
        case replacedInout, throwingInout, copiedAlias, nativeCopiedAlias
        case calleeMutation, throwingCalleeMutation, borrowedCallback, callbackMutation, asyncCallbackMutation
        case hostCallbackMutation, hostAsyncCallbackMutation, storedHostCallbackMutation, scopedCopyMutation
    }

    @Test(.serialized, arguments: RuntimeDependencyOperation.allCases)
    func runtimeValuesShareCodeDependenciesAcrossNativeOperations(_ operation: RuntimeDependencyOperation) async throws {
        let module = "RuntimeOwner_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let provider = try FixtureLibrary(load: false, swiftModule: module, swiftSource: """
            public final class Box {
                private var body: () -> Int64
                private var saved: ((AnyObject) throws -> Void)?
                public init(_ body: @escaping () -> Int64) { self.body = body }
                public func read() -> Int64 { body() }
                public consuming func opaqueSelf() -> some AnyObject { self }
                public nonisolated(nonsending) consuming func opaqueSelfAsync() async -> some AnyObject { self }
                public func update(from other: Box) { body = other.body }
                public func apply(_ callback: (AnyObject) -> Void) { callback(self) }
                public nonisolated(nonsending) func applyAsync(_ callback: nonisolated(nonsending) (AnyObject) async -> Void) async { await callback(self) }
                public func applyThrowing(_ callback: (AnyObject) throws -> Void) rethrows { try callback(self) }
                public nonisolated(nonsending) func applyAsyncThrowing(_ callback: nonisolated(nonsending) (AnyObject) async throws -> Void) async rethrows { try await callback(self) }
                public func store(_ callback: @escaping (AnyObject) throws -> Void) { saved = callback }
                public func clear() { saved = nil }
                public func fire() throws { try saved?(self) }
            }
            public func fire(_ object: AnyObject) throws { try (object as! Box).fire() }
            public protocol Reader { func read() -> Int64 }
            public struct Record: Reader {
                private let body: () -> Int64
                public init(_ body: @escaping () -> Int64) { self.body = body }
                public func read() -> Int64 { body() }
                public consuming func opaqueSelf() -> some Reader { self }
                public nonisolated(nonsending) consuming func opaqueSelfAsync() async -> some Reader { self }
            }
            public struct Failure: Error { public init() {} }
            public func replaceAndThrow<T: ~Copyable>(_ value: inout T, _ replacement: consuming T) throws {
                value = replacement
                throw Failure()
            }
            public func update<T>(_ value: T, _ other: T) {
                (value as AnyObject as! Box).update(from: other as AnyObject as! Box)
            }
            """, linkArguments: ["-swift-version", "6", "-emit-module", "-enable-library-evolution"])
        defer { provider.cleanup() }
        func factory(_ suffix: String, _ value: Int64) throws -> FixtureLibrary {
            try FixtureLibrary(load: false, swiftModule: module + suffix, swiftSource: """
                import \(module)
                @inline(never) private func number() -> Int64 { \(value) }
                public func make() -> some AnyObject { Box { number() } }
                public func makeRecord() -> some Reader { Record { number() } }
                public func visit(_ callback: (Record) -> Void) { callback(Record { number() }) }
                public func callback() -> (AnyObject) -> Void { { ($0 as! Box).update(from: Box { number() }) } }
                public func asyncCallback() -> nonisolated(nonsending) (AnyObject) async -> Void {
                    { object in await Task.yield(); (object as! Box).update(from: Box { number() }) }
                }
                public func update<T>(_ value: T) {
                    (value as AnyObject as! Box).update(from: Box { number() })
                }
                public func updateAndThrow<T>(_ value: T) throws {
                    update(value)
                    throw Failure()
                }
                """, linkArguments: ["-swift-version", "6", "-I", provider.directory.path, provider.libraryURL.path])
        }
        let first = try factory("First", 41), second = try factory("Second", 42)
        defer { first.cleanup(); second.cleanup() }
        try first.load(); try second.load()
        weak var argumentLease: ImageLease?
        let runtime = ABIRuntime()
        var preparedCopy: NativeSwiftFunction<(NativeSwiftValue) -> NativeSwiftValue>?
        func produce() async throws -> NativeSwiftValue {
            let factoryName = operation == .addressReceiverResult || operation == .asyncAddressReceiverResult || operation == .borrowedCallback ? "makeRecord()" : "make()"
            let makeFirst = try await runtime.swiftFunction(named: module + "First." + factoryName, as: (() -> NativeSwiftValue).self,
                in: .path(first.libraryURL))
            let makeSecond = try await runtime.swiftFunction(named: module + "Second." + factoryName, as: (() -> NativeSwiftValue).self,
                in: .path(second.libraryURL))
            let binding = try unsafe makeFirst.unsafeInvoke()
            let argument = try unsafe makeSecond.unsafeInvoke()
            let images = argument.type.codeImages
            argumentLease = try #require(images.first { $0.identity == makeSecond.symbol.image.identity }?.lease)
            if operation == .asyncMovedResult {
                let move = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.moveRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A) async -> A",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self, genericArguments: [.type(binding.type)])
                return try unsafe await move.unsafeInvoke(NativeSwiftConsuming(argument))
            }
            let receiverABI: NativeType? = factoryName == "makeRecord()" ? try .opaque(named: argument.type.name) : nil
            switch operation {
            case .hostCallbackMutation, .hostAsyncCallbackMutation, .storedHostCallbackMutation, .scopedCopyMutation:
                let update = try await runtime.swiftFunction(named: module + "Second.update<A>(A) -> ()",
                    as: ((AnyObject) -> Void).self, genericArguments: [.type(AnyObject.self)], in: .path(second.libraryURL))
                argumentLease = update.symbol.image.lease
                if operation == .scopedCopyMutation {
                    try binding.withCopy { try unsafe update.unsafeInvoke($0 as AnyObject) }
                } else if operation == .hostAsyncCallbackMutation {
                    let body: nonisolated(nonsending) @Sendable (AnyObject) async throws -> Void = { object in
                        await Task.yield()
                        try unsafe update.unsafeInvoke(object)
                    }
                    let callback = try NativeSwiftClosure<nonisolated(nonsending) (AnyObject) async throws -> Void>(body)
                    let apply = try await binding.type.method(named: "applyAsyncThrowing(_:)",
                        as: (nonisolated(nonsending) (NativeSwiftClosure<nonisolated(nonsending) (AnyObject) async throws -> Void>) async throws -> Void).self)
                    try unsafe await apply.unsafeInvoke(on: binding, callback)
                } else {
                    let body: @Sendable (AnyObject) throws -> Void = { object in
                        try unsafe update.unsafeInvoke(object)
                    }
                    let callback = try NativeSwiftClosure<(AnyObject) throws -> Void>(body)
                    if operation == .storedHostCallbackMutation {
                        let store = try await binding.type.method(named: "store(_:)",
                            as: ((NativeSwiftClosure<(AnyObject) throws -> Void>) -> Void).self)
                        try unsafe store.unsafeInvoke(on: binding, callback)
                        let fire = try await runtime.swiftFunction(named: module + ".fire(_:)",
                            as: ((AnyObject) throws -> Void).self, in: .path(provider.libraryURL))
                        let object = try binding.withCopy { $0 as AnyObject }
                        try unsafe fire.unsafeInvoke(object)
                        let clear = try await binding.type.method(named: "clear()", as: (() -> Void).self)
                        try unsafe clear.unsafeInvoke(on: binding)
                    } else {
                        let apply = try await binding.type.method(named: "applyThrowing(_:)",
                            as: ((NativeSwiftClosure<(AnyObject) throws -> Void>) throws -> Void).self)
                        try unsafe apply.unsafeInvoke(on: binding, callback)
                    }
                }
                return binding
            case .callbackMutation:
                let make = try await runtime.swiftFunction(named: module + "Second.callback()",
                    as: (() -> NativeSwiftClosure<(AnyObject) -> Void>).self, in: .path(second.libraryURL))
                argumentLease = make.symbol.image.lease
                let callback = try unsafe make.unsafeInvoke()
                let apply = try await binding.type.method(named: "apply(_:)",
                    as: ((NativeSwiftClosure<(AnyObject) -> Void>) -> Void).self)
                try unsafe apply.unsafeInvoke(on: binding, callback)
                return binding
            case .asyncCallbackMutation:
                let make = try await runtime.swiftFunction(named: module + "Second.asyncCallback()",
                    as: (() -> NativeSwiftClosure<nonisolated(nonsending) (AnyObject) async -> Void>).self,
                    in: .path(second.libraryURL))
                argumentLease = make.symbol.image.lease
                let callback = try unsafe make.unsafeInvoke()
                let apply = try await binding.type.method(named: "applyAsync(_:)",
                    as: (nonisolated(nonsending) (NativeSwiftClosure<nonisolated(nonsending) (AnyObject) async -> Void>) async -> Void).self)
                try unsafe await apply.unsafeInvoke(on: binding, callback)
                return binding
            case .receiverResult, .addressReceiverResult:
                let method = try await argument.type.method(named: "opaqueSelf()", as: (() -> NativeSwiftValue).self, receiverABI: receiverABI, consuming: true)
                return try unsafe method.unsafeInvoke(on: argument)
            case .asyncReceiverResult, .asyncAddressReceiverResult:
                let method = try await argument.type.method(named: "opaqueSelfAsync()", as: (() async -> NativeSwiftValue).self, receiverABI: receiverABI, consuming: true)
                return try unsafe await method.unsafeInvoke(on: argument)
            case .replacedInout, .throwingInout:
                let buffer = try NativeSwiftInout(binding)
                if operation == .throwingInout {
                    let replace = try await runtime.swiftFunction(named: module + ".replaceAndThrow<A where A: ~Swift.Copyable>(inout A, __owned A) throws -> ()",
                        as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>) throws -> Void).self,
                        genericArguments: [.type(binding.type)], in: .path(provider.libraryURL))
                    do {
                        try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(argument))
                        Issue.record("The replacement must report its native error")
                    } catch is NativeSwiftError {}
                } else {
                    let replace = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
                        as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>) -> Void).self,
                        genericArguments: [.type(binding.type)])
                    try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(argument))
                }
                return binding
            case .borrowedCallback:
                let copied = RuntimeBorrowCopy()
                let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void> { copied.accept($0) }
                let visit = try await runtime.swiftFunction(named: module + "Second.visit((" + module + ".Record) -> ()) -> ()",
                    as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Void).self, valueABIs: [binding.type: .opaque(named: binding.type.name)], in: .path(second.libraryURL))
                argumentLease = visit.symbol.image.lease
                try unsafe visit.unsafeInvoke(callback)
                return try copied.take()
            case .calleeMutation, .throwingCalleeMutation:
                if operation == .throwingCalleeMutation {
                    let update = try await runtime.swiftFunction(named: module + "Second.updateAndThrow<A>(A) throws -> ()",
                        as: ((NativeSwiftValue) throws -> Void).self,
                        genericArguments: [.type(binding.type)], in: .path(second.libraryURL))
                    argumentLease = update.symbol.image.lease
                    do {
                        try unsafe update.unsafeInvoke(binding)
                        Issue.record("The update must report its native error")
                    } catch is NativeSwiftError {}
                } else {
                    let update = try await runtime.swiftFunction(named: module + "Second.update<A>(A) -> ()",
                        as: ((NativeSwiftValue) -> Void).self,
                        genericArguments: [.type(binding.type)], in: .path(second.libraryURL))
                    argumentLease = update.symbol.image.lease
                    try unsafe update.unsafeInvoke(binding)
                }
                return binding
            case .copiedAlias, .nativeCopiedAlias:
                let alias: NativeSwiftValue
                if operation == .copiedAlias { alias = try binding.copy() }
                else {
                    let copy = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                        as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(binding.type)])
                    alias = try unsafe copy.unsafeInvoke(binding)
                }
                let update = try await runtime.swiftFunction(named: module + ".update<A>(A, A) -> ()",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> Void).self,
                    genericArguments: [.type(binding.type)], in: .path(provider.libraryURL))
                try unsafe update.unsafeInvoke(binding, argument)
                // Connect the same families in both directions; dropping all
                // native handles must still release the image leases.
                try unsafe update.unsafeInvoke(argument, binding)
                return alias
            case .copiedResult, .asyncMovedResult:
                let copy = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(binding.type)])
                preparedCopy = copy
                return try unsafe copy.unsafeInvoke(argument)
            }
        }
        var result: NativeSwiftValue? = try await produce()
        await runtime.removeCachedResults()
        first.close(); second.close()
        // Check the actual image lease before invoking code that would be unloaded.
        guard argumentLease != nil else {
            Issue.record("The runtime result discarded its argument's closure implementation image")
            return
        }
        func inspect() async throws {
            let receiverABI: NativeType? = operation == .addressReceiverResult || operation == .asyncAddressReceiverResult || operation == .borrowedCallback
                ? try .opaque(named: result!.type.name) : nil
            let read = try await result!.type.method(named: "read()", as: (() -> Int64).self, receiverABI: receiverABI)
            #expect(try unsafe read.unsafeInvoke(on: result!) == 42)
        }
        try await inspect()
        result = nil
        await runtime.removeCachedResults()
        withExtendedLifetime(preparedCopy) { #expect(argumentLease == nil) }
    }
    @Test func objectConstraintMetadataFollowsSwiftSelfConformanceRules() throws {
        #expect(SwiftObjectType(AnyObject.self) != nil)
        #expect(SwiftObjectType((any NSObjectProtocol).self) != nil)
        let object = try #require(SwiftObjectType((any NSCopying & NSObject).self))
        #expect(object.isSubclass(of: NSObject.self))
        #expect(!object.isSubclass(of: NSString.self))
        #expect(object.conforms(to: try #require(NSProtocolFromString("NSCopying"))))
        #expect(object.conforms(to: try #require(NSProtocolFromString("NSObject"))))
        for type: Any.Type in [String.self, AnyObject.Type.self, AnyObject.Protocol.self,
                              (any GenericSwiftClassOnly).self, (@convention(block) () -> Void).self] {
            #expect(SwiftObjectType(type) == nil)
        }
    }

    @Test func privateProtocolIdentityDoesNotChangeWitnessOrdering() throws {
        let name = try swiftNativeTypeName((any GenericOrderingA).self)
        let context = try SwiftGenericTypeContext(metadata: GenericOrderingOwner<GenericOrderingValue>.self)
        let parameter = SwiftFormalType.named("A", [])
        let declaration = SwiftGenericDeclaration(parameters: context.parameters,
            requirements: context.requirements + [.conformance(parameter, name)],
            arguments: [], result: .tuple([]), failure: nil, isAsync: false, consumesArguments: false)
        let binding = try SwiftGenericBinding(declaration: declaration, arguments: [.type(GenericOrderingValue.self)],
            signature: SwiftFunctionSignature((() -> Void).self), resolver: .shared, enclosing: context)
        let first = SwiftProtocolDescriptor(try SymbolResolver.shared.resolve(
            .init(name: "protocol descriptor for " + name, language: .swift, kind: .data), in: .automatic, loading: .loadedOnly))
        let second = try #require(context.conformances.first?.descriptor)
        let witnesses = try [first, second].map { descriptor in
            let witness = unsafe descriptor.withUnsafeAddress {
                ABISwiftConformance(unsafeBitCast(GenericOrderingValue.self, to: UnsafeRawPointer.self), $0)
            }
            return UInt(bitPattern: try #require(witness))
        }
        #expect(binding.metadataArguments == [unsafeBitCast(GenericOrderingValue.self, to: UInt.self)] + witnesses)
    }

    @Test func existentialMetatypesKeepTheirRuntimeRepresentation() throws {
        let binding = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures10runGenericyxyxXElF"),
            arguments: [.type((any CustomStringConvertible).self)],
            signature: SwiftFunctionSignature((() -> Void).self), resolver: .shared)
        let parameter = SwiftFormalType.named("A", [])
        let ordinary = try binding.types(.metatype(parameter))
        let existential = try binding.types(.existentialMetatype(parameter))
        let nested = try binding.types(.existentialMetatype(.existentialMetatype(parameter)))
        #expect(ObjectIdentifier(ordinary[0]) == ObjectIdentifier((any CustomStringConvertible).Type.self))
        #expect(ObjectIdentifier(existential[0]) == ObjectIdentifier((any CustomStringConvertible.Type).self))
        #expect(ObjectIdentifier(nested[0]) == ObjectIdentifier((any CustomStringConvertible.Type.Type).self))
        #expect(try binding.spelling(.metatype(parameter)) == "Swift.CustomStringConvertible.Protocol")
        #expect(try binding.spelling(.existentialMetatype(parameter)) == "Swift.CustomStringConvertible.Type")
    }

    @Test func associatedWitnessesPreserveFormalSubstitutions() throws {
        let binding = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures10runGenericyxyxXElF"),
            arguments: [.type(Int64.self)], signature: SwiftFunctionSignature((() -> Void).self), resolver: .shared)
        let parameter = SwiftFormalType.named("A", [])
        let array = SwiftFormalType.nominal("Swift.Array", [parameter])
        let element = SwiftFormalType.associated(array, "Element", protocolName: "Swift.Sequence")
        #expect(try binding.canonicalType(of: element) == parameter)
        let nested = SwiftFormalType.associated(.nominal("Swift.Array", [array]), "Element", protocolName: "Swift.Sequence")
        #expect(try binding.canonicalType(of: nested) == array)
        #expect(try SwiftGenericValueLayout.isIndirect(GenericElementStorage<[Int64]>.self,
            arguments: [array], binding: binding))
        #expect(try !SwiftGenericValueLayout.isIndirect(GenericElementStorage<[[Int64]]>.self,
            arguments: [.nominal("Swift.Array", [array])], binding: binding))
    }
    @Test func nominalPackFulfillmentsKeepTransformedAndPrefixedArguments() throws {
        let cases: [(String, Any.Type, Int)] = [
            ("$s20ManagedSwiftFixtures22packClassSourceGenericys5Int64VAA0gF4PackCyxxQp_QPG_xxQptRvzSQRzlF",
             ((GenericSourcePack<Int64, String>, Int64, String) -> Int64).self, 0),
            ("$s20ManagedSwiftFixtures25packMetatypeSourceGenericys5Int64VAA0gF4PackCyxxQp_QPGm_xxQptRvzSQRzlF",
             ((GenericSourcePack<Int64, String>.Type, Int64, String) -> Int64).self, 0),
            ("$s20ManagedSwiftFixtures24packValueMetatypeGenericys5Int64VAA0G8TypePackVyxxQp_QPGm_xxQptRvzSQRzlF",
             ((GenericTypePack<Int64, String>.Type, Int64, String) -> Int64).self, 3),
            ("$s20ManagedSwiftFixtures25prefixedPackSourceGenericys5Int64VAA0gfE0CyAD_xxQpQPG_xxQptRvzSQRzlF",
             ((GenericSourcePack<Int64, Int64, String>, Int64, String) -> Int64).self, 3),
            ("$s20ManagedSwiftFixtures22arrayPackSourceGenericys5Int64VAA0gfE0CySayxGxQp_QPG_xxQptRvzSQRzlF",
             ((GenericSourcePack<[Int64], [String]>, Int64, String) -> Int64).self, 3)
        ]
        for (symbol, signature, count) in cases {
            let binding = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName: symbol),
                arguments: [.pack([.type(Int64.self), .type(String.self)])],
                signature: SwiftFunctionSignature(signature), resolver: .shared)
            #expect(binding.metadataArguments.count == count)
        }
    }

    @Test func compositePackElementsConstructCanonicalMetadata() throws {
        let binding = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures22constrainedPackGenericyxxQp_txxQpRvzSQRzlF"),
            arguments: [.pack([.type(Int.self), .type(String.self)])],
            signature: SwiftFunctionSignature((() -> Void).self), resolver: .shared)
        let element = SwiftFormalType.named("A", [])
        let arrays = try binding.types(.pack(.nominal("Swift.Array", [element]), shape: element))
        #expect(arrays.count == 2 && arrays[0] == [Int].self && arrays[1] == [String].self)
        let tuples = try binding.types(.pack(.tuple([element, .nominal("Swift.Int64", [])]), shape: element))
        #expect(tuples.count == 2 && tuples[0] == (Int, Int64).self && tuples[1] == (String, Int64).self)
        let labeled = try binding.types(.tuple([
            .nominal("Swift.Int64", []), .pack(element, shape: element), .nominal("Swift.Bool", [])
        ], labels: ["head", "", "tail"]))
        #expect(labeled.count == 1 && labeled[0] == (head: Int64, Int, String, tail: Bool).self)
        let selected = binding.selectingPackElement(at: 1)
        #expect(try selected.types(element).first == String.self)
        #expect(try selected.types(.tuple([.pack(element, shape: element)])).first == (Int, String).self)
        let metatype = try binding.types(.metatype(.tuple([.pack(element, shape: element)])))
        #expect(metatype.count == 1 && metatype[0] == (Int, String).Type.self)
        let pack = try binding.types(.nominal("ManagedSwiftFixtures.GenericTypePack", [
            .packValue([.nominal("Swift.Int64", []), .pack(element, shape: element)])]))
        #expect(pack.count == 1 && pack[0] == GenericTypePack<Int64, Int, String>.self)
        let empty = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures22constrainedPackGenericyxxQp_txxQpRvzSQRzlF"),
            arguments: [.pack([])], signature: SwiftFunctionSignature((() -> Void).self), resolver: .shared)
        let singleton = try empty.types(.tuple([.nominal("Swift.Int64", []), .pack(element, shape: element)],
            labels: ["head", ""]))
        #expect(singleton.count == 1 && singleton[0] == Int64.self)
    }

    @Test func explicitNominalSourcesRemoveOnlyFulfilledMetadataWords() throws {
        let mixed = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures18classSourceGenericys5Int64V_q_tAA0fE3BoxCyxG_q_tAA0fE5ChildRzr0_lF"),
            arguments: [.type(GenericSourceValue.self), .type(String.self)],
            signature: SwiftFunctionSignature(((GenericSourceBox<GenericSourceValue>, String) -> (Int64, String)).self),
            resolver: .shared)
        #expect(mixed.metadataArguments == [unsafeBitCast(String.self, to: UInt.self)])
        let metatype = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures21metatypeSourceGenericys5Int64VAA0fE3BoxCyxGmAA0fE5ChildRzlF"),
            arguments: [.type(GenericSourceValue.self)],
            signature: SwiftFunctionSignature(((GenericSourceBox<GenericSourceValue>.Type) -> Int64).self), resolver: .shared)
        #expect(metatype.metadataArguments.isEmpty)
        let nested = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures19nestedSourceGenericyxAA0fE6NestedCySayxGGlF"),
            arguments: [.type(String.self)], signature: SwiftFunctionSignature(((GenericSourceNested<[String]>) -> String).self),
            resolver: .shared)
        #expect(nested.metadataArguments.isEmpty)
        let superclass = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures23superclassSourceGenericys5Int64Vq_AA0fE5ChildRzAA0fE3BoxCyxGRb_r0_lF"),
            arguments: [.type(GenericSourceValue.self), .type(GenericSourceLeaf.self)],
            signature: SwiftFunctionSignature(((GenericSourceLeaf) -> Int64).self), resolver: .shared)
        #expect(superclass.metadataArguments == [unsafeBitCast(GenericSourceLeaf.self, to: UInt.self)])
    }

    @Test func declarationSyntaxSeparatesNominalNamesAndGenericParameters() throws {
        // Swift 6.3: module A, collide<T>(_: T, _: Marker) -> (T, Marker).
        let collision = try SwiftGenericDeclaration(linkageName: "$s1A7collideyx_AA6MarkerVtx_ADtlF")
        #expect(collision.parameters.map(\.name) == ["A"])
        #expect(collision.arguments == [.named("A", []), .nominal("A.Marker", [])])
        #expect(collision.result == .tuple(collision.arguments))

        let context = try SwiftGenericTypeContext(metadata: GenericValueBox<String>.self)
        let member = try SwiftGenericDeclaration(
            linkageName: "$s20ManagedSwiftFixtures15GenericValueBoxV7checked_4failxqd___Sbtqd__YKs5ErrorRd__lF",
            enclosing: context)
        #expect(member.parameters.map(\.name) == ["A", "A1"])
        #expect(member.arguments == [.named("A1", []), .nominal("Swift.Bool", [])])
        #expect(member.failure == .named("A1", []))
        let getter = try SwiftGenericDeclaration(
            linkageName: "$s20ManagedSwiftFixtures15GenericValueBoxV5valuexvg", enclosing: context)
        #expect(getter.arguments.isEmpty && getter.result == .named("A", []))
        let setter = try SwiftGenericDeclaration(
            linkageName: "$s20ManagedSwiftFixtures15GenericValueBoxV5valuexvs", enclosing: context)
        #expect(setter.arguments == [.named("A", [])] && setter.result == .tuple([]))
    }

    @Test func declarationSyntaxPreservesNestedNominalArgumentsAndPackMarkers() throws {
        let nested = try SwiftGenericDeclaration(
            linkageName: "$s20ManagedSwiftFixtures16GenericTypeOuterV5InnerVAEyx_qd__GycfC",
            enclosing: SwiftGenericTypeContext(metadata: GenericTypeOuter<String>.Inner<Bool>.self))
        #expect(nested.result == .nested(.nominal("ManagedSwiftFixtures.GenericTypeOuter", [.named("A", [])]),
            "Inner", [.named("A1", [])]))
        #expect(nested.result.nominalDeclaration?.name == "ManagedSwiftFixtures.GenericTypeOuter.Inner")
        #expect(nested.result.nominalDeclaration?.arguments == [.named("A", []), .named("A1", [])])
        let packs = try SwiftGenericDeclaration(
            linkageName: "$s20ManagedSwiftFixtures17pairedPackGenericyq__xtxQp_tx_q_txQpRvzRv_q_Rhzr0_lF")
        #expect(packs.parameters.count == 2 && packs.parameters.allSatisfy(\.isPack))
        #expect(packs.arguments == [.pack(.tuple([.named("A", []), .named("B", [])]), shape: .named("A", []))])
        #expect(packs.requirements == [.sameShape(.named("A", []), .named("B", []))])
    }

    @Test func syntaxPreservesGenericDepthWithoutPrintedParameterNames() throws {
        let node: SwiftSyntax.Node
        do {
            let syntax = try SwiftSyntax(symbol: "$s20ManagedSwiftFixtures15GenericValueBoxV7checked_4failxqd___Sbtqd__YKs5ErrorRd__lF")
            node = try #require(syntax.root.child(kind: "Function")?.child(kind: "Type")?
                .child(kind: "DependentGenericType")?.child(kind: "Type")?
                .child(kind: "FunctionType")?.child(kind: "TypedThrowsAnnotation")?
                .child(kind: "DependentGenericParamType"))
        }
        #expect(node.children().compactMap(\.index) == [1, 0])
        #expect(try node.name() == "A1")
        #expect(throws: ABIResolutionError.self) { try SwiftSyntax(symbol: "not a Swift symbol") }
    }

    @Test func syntaxReadsSymbolicNominalFieldReferencesAtTheirOriginalAddress() throws {
        let metadata = unsafeBitCast(ResilientRecord.self, to: UnsafeRawPointer.self)
        let handle = try #require(ABICopySwiftTypeFieldSyntax(metadata, 0))
        let syntax = SwiftSyntax(adopting: handle)
        let reference = try #require(syntax.root.child(kind: "TypeSymbolicReference"))
        let descriptor = try #require(ABISwiftTypeDescriptor(unsafeBitCast(ManagedRecord.self, to: UnsafeRawPointer.self)))
        #expect(reference.index == UInt64(UInt(bitPattern: descriptor)))
    }

    @Test func genericClassInitializersPropertiesAndMethodsShareBinding() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericTypeClass",
            genericArguments: [.type(String.self)])
        let initialize = try await type.initializer(
            named: "init(_:)",
            as: ((String) -> GenericTypeClass<String>).self)
        let receiver = try unsafe initialize.unsafeInvoke(String(repeating: "initial", count: 20))
        let erasedInitialize = try await type.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
        let erasedReceiver = try unsafe erasedInitialize.unsafeInvoke("erased")
        #expect((erasedReceiver as? GenericTypeClass<String>)?.value == "erased")
        let get = try await type.getter(named: "value", as: (() -> String).self)
        let set = try await type.setter(named: "value", as: String.self)
        let identity = try await type.staticMethod(named: "identity(_:)", as: ((String) -> String).self)
        let compare = try await type.method(named: "compare(_:)",
            as: ((Int) -> (String, Int, Bool)).self, genericArguments: [.type(Int.self)])
        #expect(try unsafe get.unsafeInvoke(on: receiver) == receiver.value)
        try unsafe set.unsafeInvoke(on: receiver, String(repeating: "updated", count: 20))
        #expect(receiver.value == String(repeating: "updated", count: 20))
        #expect(try unsafe identity.unsafeInvoke("static") == "static")
        let result = try unsafe compare.unsafeInvoke(on: receiver, 42)
        #expect(result.0 == receiver.value && result.1 == 42 && result.2)
    }

    @Test func nominalContextsPreserveParameterDepthAndAssociatedConstraints() throws {
        let collection = try SwiftGenericTypeContext(metadata: GenericTypeCollection<[String]>.self)
        #expect(collection.parameters.map(\.name) == ["A"])
        #expect(collection.keyParameters == ["A"])
        #expect(collection.conformances.map { $0.subject.spelling + ": " + $0.name }.sorted()
            == ["A.Element: Swift.Equatable", "A: Swift.Collection"])
        let nested = try SwiftGenericTypeContext(
            metadata: GenericTypeOuter<[String]>.Inner<String>.Constrained<Bool>.self)
        #expect(nested.parameters.map(\.name) == ["A", "A1", "A2"])
        #expect(nested.keyParameters == ["A", "A1", "A2"])
        #expect(nested.conformances.contains { $0.subject.spelling == "A1" && $0.name == "Swift.Equatable" })
        let related = try SwiftGenericTypeContext(metadata: GenericTypeRelated<[String], String>.self)
        #expect(related.parameters.map(\.name) == ["A", "B"])
        #expect(related.keyParameters == ["A", "B"])
        let recursive = try SwiftGenericTypeContext(metadata: GenericRecursive<GenericLeaf>.self)
        #expect(recursive.conformances.map { $0.subject.spelling + ": " + $0.name }.sorted()
            == ["A.ManagedSwiftFixtures.GenericTree.Child.ManagedSwiftFixtures.GenericTree.Child: Swift.Equatable", "A: ManagedSwiftFixtures.GenericTree"])
        let pack = try SwiftGenericTypeContext(metadata: GenericTypePack<String, Int>.self)
        #expect(pack.parameters.count == 1 && pack.parameters[0].isPack)
        #expect(pack.conformances.first?.name == "Swift.Equatable")
    }
    @Test func nominalMetadataUsesRuntimeConstraintsAndCanonicalIdentity() async throws {
        let runtime = ABIRuntime()
        func packMetadata<each Value>(_ types: repeat (each Value).Type) -> Any.Type where repeat each Value: Equatable {
            GenericTypePack<repeat each Value>.self
        }
        let cases: [(String, [NativeSwiftGenericArgument], Any.Type)] = [
            ("Swift.Array", [.type(String.self)], [String].self),
            ("Swift.Dictionary", [.type(String.self), .type([Int].self)], [String: [Int]].self),
            ("ManagedSwiftFixtures.GenericRecord", [.type(ConditionalMetric<ManagedRecord>.self)],
             GenericRecord<ConditionalMetric<ManagedRecord>>.self),
            ("ManagedSwiftFixtures.GenericTypeClass", [.type([String].self)], GenericTypeClass<[String]>.self),
            ("ManagedSwiftFixtures.GenericTypeDerived", [.type(String.self)], GenericTypeDerived<String>.self),
            ("ManagedSwiftFixtures.GenericTypeEnum", [.type(String.self)], GenericTypeEnum<String>.self),
            ("ManagedSwiftFixtures.GenericTypeCollection", [.type([String].self)], GenericTypeCollection<[String]>.self),
            ("ManagedSwiftFixtures.GenericTypeRelated", [.type([String].self), .type(String.self)],
             GenericTypeRelated<[String], String>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.Inner", [.type(Bool.self), .type(Double.self)],
             GenericTypeOuter<Bool>.Inner<Double>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.FixedInner", [.type(Bool.self)],
             GenericTypeOuter<Bool>.FixedInner.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.InExtension", [.type(Bool.self), .type(Double.self)],
             GenericTypeOuter<Bool>.InExtension<Double>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.Inner.Constrained",
             [.type([String].self), .type(String.self), .type(Bool.self)],
             GenericTypeOuter<[String]>.Inner<String>.Constrained<Bool>.self),
            ("ManagedSwiftFixtures.GenericTypeNamespace.Member", [.type(String.self)],
             GenericTypeNamespace.Member<String>.self),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.type(String.self), .type(Int.self)])],
             GenericTypePack<String, Int>.self),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([])], packMetadata()),
            ("ManagedSwiftFixtures.GenericTypeMixedPack", [.type(Bool.self), .pack([.type(String.self), .type(Int.self)])],
             GenericTypeMixedPack<Bool, String, Int>.self)
        ]
        for (name, arguments, expected) in cases {
            let type = try await runtime.swiftType(named: name, genericArguments: arguments)
            let metadata = await type.metadata
            #expect(ObjectIdentifier(metadata) == ObjectIdentifier(expected), "\(name)")
            let again = try await runtime.swiftType(named: name, in: type.image, genericArguments: arguments)
            #expect(type === again)
            var failure: OpaquePointer?
            let copy = ABICopySwiftTypeMetadata(unsafeBitCast(expected, to: UnsafeRawPointer.self), &failure)
            defer { if let failure { ABIReleaseResolutionFailure(failure) } }
            let recovered = try #require(copy, "\(name)")
            defer { ABIReleaseSwiftTypeMetadata(recovered) }
            #expect(ABISwiftTypeMetadataArgumentCount(recovered) == arguments.count)
            for (index, argument) in arguments.enumerated() {
                let elements: [NativeSwiftGenericArgument]
                switch argument.storage {
                case .type:
                    #expect(!ABISwiftTypeMetadataArgumentIsPack(recovered, index))
                    elements = [argument]
                case .pack(let pack):
                    #expect(ABISwiftTypeMetadataArgumentIsPack(recovered, index))
                    elements = pack
                }
                #expect(ABISwiftTypeMetadataArgumentElementCount(recovered, index) == elements.count)
                for (element, expected) in elements.enumerated() {
                    guard case .type(let type, _) = expected.storage else { continue }
                    #expect(ABISwiftTypeMetadataArgumentElement(recovered, index, element)
                        == unsafeBitCast(type, to: UnsafeRawPointer.self))
                }
            }
        }
        let first = try await runtime.swiftType(named: "Swift.Array", genericArguments: [.type(String.self)])
        let second = try await runtime.swiftType(named: "Swift.Array", genericArguments: [.type(Int.self)])
        let firstMetadata = await first.metadata
        let secondMetadata = await second.metadata
        #expect(first !== second && firstMetadata != secondMetadata)
    }

    @Test func invalidNominalArgumentsFailWithoutEnteringAnInvalidAccessor() async throws {
        let runtime = ABIRuntime()
        let cases: [(String, [NativeSwiftGenericArgument])] = [
            ("Swift.Array", []),
            ("Swift.Array", [.pack([.type(String.self)])]),
            ("Swift.Array", [.type(Int.self), .type(String.self)]),
            ("Swift.Int", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypeCollection", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericRecord", [.type(String.self)]),
            ("ManagedSwiftFixtures.GenericTypeRelated", [.type([String].self), .type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypePack", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.type(LifetimeToken.self)])]),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.pack([])])])
        ]
        for (name, arguments) in cases {
            await #expect(throws: ABIResolutionError.self) {
                _ = try await runtime.swiftType(named: name, genericArguments: arguments)
            }
        }
    }

    @Test func cachedNominalMetadataRetainsIncomingRuntimeTypeOwners() async throws {
        let runtime = ABIRuntime()
        let name = "ManagedSwiftFixtures.GenericTypeEnum"
        let bare = try await runtime.swiftType(named: name, genericArguments: [.type(ManagedRecord.self)])
        var result: NativeSwiftType?
        weak var argumentOwner: NativeSwiftType?
        do {
            let argument = try await runtime.swiftType(named: "ManagedSwiftFixtures.ManagedRecord")
            argumentOwner = argument
            result = try await runtime.swiftType(named: name, genericArguments: [.type(argument)])
            let metadata = await result!.metadata
            let bareMetadata = await bare.metadata
            #expect(ObjectIdentifier(metadata) == ObjectIdentifier(bareMetadata))
            await runtime.removeCachedResults()
        }
        #expect(argumentOwner != nil)
        result = nil
        #expect(argumentOwner == nil)
    }

    @Test func tupleClosureAuthenticationMatchesCompilerLowering() throws {
        let signature = try SwiftFunctionSignature((((String, Int8)) -> (String, Int8, Int8)).self)
        #expect(try signature.closureDiscriminator() == 3335)
        #expect(swiftClosureDiscriminator(parameters: ["-indirect", "$ss4Int8V"],
            results: ["-indirect", "$ss4Int8V", "$ss4Int8V"]) == 8528)
        #expect(swiftClosureDiscriminator(parameters: ["-"], results: ["-indirect"]) == 47754)
        #expect(try swiftClosureDiscriminator(parameters: ["-indirect"],
            results: swiftClosureAuthTypes((Int64, Int64).self)) == 42045)
        let metatypes: [Any.Type] = [Int64.Type.self, Int64.Type?.self, (any CustomStringConvertible.Type).self]
        for type in metatypes {
            let auth = try swiftClosureAuthType(type)
            #expect(swiftClosureDiscriminator(parameters: [auth], results: [auth]) == 30738)
        }
        let optional = try swiftClosureAuthType((any CustomStringConvertible.Type)?.self)
        #expect(swiftClosureDiscriminator(parameters: [optional], results: [optional]) == 53055)
        #expect(try SwiftFunctionSignature(((LargeManagedValue) -> LargeManagedValue).self).closureDiscriminator() == 55683)
    }

    @Test func collectionSugarMatchesRuntimeAndToolchainDemanglers() {
        let nominal = "Example.map<A, B>(Swift.Array<A>, (A) -> B) -> Swift.Dictionary<Swift.String, Swift.Optional<B>>"
        let sugared = "Example.map<A, B>([A], (A) -> B) -> [Swift.String: B?]"
        #expect(DeclarationKey.make(nominal, language: .swift) == DeclarationKey.make(sugared, language: .swift))
        #expect(DeclarationKey.make(nominal, language: .cxx) != DeclarationKey.make(sugared, language: .cxx))
        #expect(DeclarationKey.make("Example.Swift.Array<A>", language: .swift) != DeclarationKey.make("Example.[A]", language: .swift))
    }

    @Test func multipleParametersAndConditionalConformancesBindWithoutAdapters() throws {
        let declaration = try SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures13selectGenericyxx_q_t7ElementQy_RszSlR_r0_lF")
        let signature = try SwiftFunctionSignature(((String, [String]) -> String).self)
        let binding = try SwiftGenericBinding(declaration: declaration,
            arguments: [.type(String.self), .type([String].self)],
            signature: signature, resolver: .shared)
        #expect(binding.metadataArguments.count == 3)
        #expect(try binding.types(.named("B.Element", []))[0] == String.self)
        try binding.validate([String].self, for: .named("Swift.Array", [.named("A", [])]))

        let conditional = try SwiftGenericBinding(
            declaration: SwiftGenericDeclaration(linkageName: "$s20ManagedSwiftFixtures12equalGenericySbx_xtSQRzlF"),
            arguments: [.type([String].self)],
            signature: SwiftFunctionSignature((([String], [String]) -> Bool).self), resolver: .shared)
        #expect(conditional.metadataArguments.count == 2)

        #expect(throws: ABIResolutionError.self) {
            try SwiftGenericBinding(declaration: declaration,
                arguments: [.type(Int.self), .type([String].self)],
                signature: signature, resolver: .shared)
        }
    }

    @Test func canonicalDeclarationsPreserveDependentTypesEffectsAndPacks() throws {
        let transform = try SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures16transformGenericySayq_GSayxG_q_xKXEtKr0_lF")
        #expect(transform.parameters.map(\.name) == ["A", "B"])
        #expect(transform.arguments[0] == .nominal("Swift.Array", [.named("A", [])]))
        #expect(transform.arguments[1] == .function([.named("A", [])], .named("B", []),
            failure: .nominal("Swift.Error", [])))
        #expect(transform.result == .nominal("Swift.Array", [.named("B", [])]))
        #expect(transform.failure == .nominal("Swift.Error", []))
        let suspended = try SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures23suspendedGenericFailureyxx_q_SbtYaq_YKs5ErrorR_r0_lF")
        #expect(suspended.parameters.map(\.name) == ["A", "B"])
        #expect(suspended.result == .named("A", []))
        #expect(suspended.failure == .named("B", []))
        #expect(suspended.isAsync)
        let pack = try SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures22constrainedPackGenericyxxQp_txxQpRvzSQRzlF")
        #expect(pack.parameters.count == 1 && pack.parameters[0].isPack)
        #expect(pack.arguments == [.pack(.named("A", []), shape: .named("A", []))])
        #expect(pack.result == .tuple([.pack(.named("A", []), shape: .named("A", []))]))
        #expect(pack.requirements == [.conformance(.named("A", []), "Swift.Equatable")])
    }

    @Test func bindingConstructsNestedNominalsAbsentFromTheConcreteSignature() throws {
        let binding = try SwiftGenericBinding(declaration: SwiftGenericDeclaration(linkageName:
            "$s20ManagedSwiftFixtures13selectGenericyxx_q_t7ElementQy_RszSlR_r0_lF"),
            arguments: [.type(String.self), .type([String].self)],
            signature: SwiftFunctionSignature(((String, [String]) -> String).self), resolver: .shared)
        let type = SwiftFormalType.nested(.nominal("ManagedSwiftFixtures.GenericTypeOuter", [.named("A", [])]),
            "Inner", [.nominal("Swift.Bool", [])])
        #expect(try binding.types(type)[0] == GenericTypeOuter<String>.Inner<Bool>.self)
        #expect(try binding.spelling(type) == "ManagedSwiftFixtures.GenericTypeOuter<Swift.String>.Inner<Swift.Bool>")
    }

    @Test func runtimeMetadataAndWitnessOperationsMatchCompilerTypes() async throws {
        let runtime = ABIRuntime.shared
        let array = try await runtime.resolve(.init(
            name: "nominal type descriptor for Swift.Array", language: .swift, kind: .data))
        let metadata = unsafeBitCast(String.self, to: UnsafeRawPointer.self)
        let actual = unsafe array.withUnsafeAddress { descriptor in
            [Optional(metadata)].withUnsafeBufferPointer {
                ABISwiftGenericTypeMetadata(descriptor, $0.baseAddress)
            }
        }
        #expect(try #require(actual) == unsafeBitCast([String].self, to: UnsafeRawPointer.self))

        let equatable = try await runtime.resolve(.init(
            name: "protocol descriptor for Swift.Equatable", language: .swift, kind: .data))
        let witness = unsafe equatable.withUnsafeAddress {
            ABISwiftConformance(metadata, $0)
        }
        #expect(witness != nil)
        #expect(ABISwiftConformanceDescriptor(try #require(witness)) != nil)

        let collection = try await runtime.resolve(.init(
            name: "protocol descriptor for Swift.Collection", language: .swift, kind: .data))
        let element = unsafe collection.withUnsafeAddress { descriptor in
            "Element".withCString {
                ABISwiftAssociatedType(unsafeBitCast([String].self, to: UnsafeRawPointer.self), descriptor, $0)
            }
        }
        #expect(element == metadata)
        let missing = unsafe collection.withUnsafeAddress { descriptor in
            "Missing".withCString {
                ABISwiftAssociatedType(unsafeBitCast([String].self, to: UnsafeRawPointer.self), descriptor, $0)
            }
        }
        #expect(missing == nil)
    }
}

#endif
