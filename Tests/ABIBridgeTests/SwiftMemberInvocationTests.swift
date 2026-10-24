import ABIBridge
import ABIBridgeTestSupport
import Foundation
import Testing

public enum SwiftMemberFailure: Error { case rejected }

@inline(never) public func swiftMemberTypedFailure() throws(SwiftMemberFailure) -> Int {
    throw .rejected
}

public class SwiftMemberRenderer {
    public var text: String
    public var object: SwiftMemberRenderer?
    public var consumedText: String {
        consuming get { text }
        consuming set { text = newValue }
    }
    public nonisolated(unsafe) static var count: Int = 0
    public init(text: String) { self.text = text }
    public convenience init(child: SwiftMemberRenderer) {
        self.init(text: child.text)
        self.object = child
    }
    public convenience init?(nonemptyText: String) {
        guard !nonemptyText.isEmpty else { return nil }
        self.init(text: nonemptyText)
    }
    public convenience init(borrowedChild: borrowing SwiftMemberRenderer) {
        self.init(child: copy borrowedChild)
    }
    @inline(never) public consuming func consumeText() -> Int { text.count }
    @inline(never) public consuming func consumeReturningNil() -> UnsafeRawPointer? { nil }
    @inline(never) public func typedFailure() throws(SwiftMemberFailure) -> Int { throw .rejected }
    @inline(never) public func render(_ value: Int) -> Int { value + text.count }
    public static var standard: String { "standard" }
    @inline(never) public static func decorate(_ text: String) -> String { text + "!" }
    @inline(never) public static func answer() -> Int32 { 42 }
}

public final class SwiftMemberDerived: SwiftMemberRenderer {}

public final class SwiftMemberLookupReceiver: NSObject {}

prefix operator ~~~
postfix operator ~~~

@frozen public struct SwiftMemberPoint: BitwiseCopyable {
    public var value: Int64
    public nonisolated(unsafe) static var observedConsumedValue: Int64 = 0
    public var consumedValue: Int64 {
        consuming get { value }
        consuming set { Self.observedConsumedValue = value + newValue; value = newValue }
    }
    public init(value: Int64) { self.value = value }
    @inline(never) public func read(_ value: Int64) -> Int64 { self.value + value }
    @inline(never) public consuming func consumeValue() -> Int64 { value }
    @inline(never) public static func > (lhs: Self, rhs: Self) -> Bool { lhs.value > rhs.value }
    @inline(never) public static prefix func ~~~ (value: Self) -> Self {
        Self(value: value.value + 1)
    }
    @inline(never) public static postfix func ~~~ (value: Self) -> Self {
        Self(value: value.value - 1)
    }
    @inline(never) public mutating func change(_ value: Int64) { self.value = value }
    @inline(never) public mutating func changeReturningNil(_ value: Int64) -> UnsafeRawPointer? {
        self.value = value
        return nil
    }
}

@frozen public enum SwiftMemberMode: BitwiseCopyable {
    case first, second
    @inline(never) public func read(_ value: Int) -> Int { self == .first ? value : value + 1 }
}

extension SwiftMemberPoint: ABIBridgeValue {
    public static let abiType = NativeType.int64
    public init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}
extension SwiftMemberMode: ABIBridgeValue {
    public static let abiType = NativeType.uint8
    public init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

@frozen public struct SwiftMemberLarge: BitwiseCopyable, ABIBridgeValue {
    public var a, b, c, d, e: Int64
    public init(a: Int64, b: Int64, c: Int64, d: Int64, e: Int64) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e
    }
    public static let abiType = try! NativeType.structure(
        named: "Large",
        fields: Array(repeating: .int64, count: 5)
    )
    public init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
    @inline(never) public func sum(_ extra: Int64) -> Int64 { a + b + c + d + e + extra }
    @inline(never) public consuming func consumeAfterChanging(_ value: Int64) -> Int64 {
        a = value
        return sum(0)
    }
}

private enum SwiftWritebackRejection: Error { case rejected }
private struct RejectingSwiftPoint: ABIBridgeValue {
    static let abiType = NativeType.int64
    let value: Int64
    init(_ value: Int64) { self.value = value }
    init(nativeValue: NativeValue) throws { throw SwiftWritebackRejection.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value.value, as: abiType)
    }
}

@frozen public struct SwiftMemberPointer {
    public var pointer: UnsafeMutablePointer<Int64>
    @inline(never) public mutating func advance() { pointer += 1 }
}

public protocol SwiftMemberPointerProtocol {
    var pointer: UnsafeMutablePointer<Int64> { get set }
}

extension SwiftMemberPointer: SwiftMemberPointerProtocol {}

extension SwiftMemberPointerProtocol {
    @inline(never) public func pointedValue() -> Int64 { pointer.pointee }
    @inline(never) public mutating func advancePointer() { pointer += 1 }
}

private final class SwiftPointerAllocation {
    let pointer: UnsafeMutablePointer<Int64>
    private let count: Int
    init(count: Int = 2) {
        self.count = count
        pointer = .allocate(capacity: count)
        for index in 0..<count { pointer.advanced(by: index).initialize(to: Int64(index + 1) * 10) }
    }
    deinit {
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}
private struct SwiftPointerView: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.storage }
}

public struct SwiftMemberGeneric<Value> {
    public let value: Value
}

private final class WeakNativeValue {
    weak var value: NativeValue?
    init(_ value: NativeValue) { self.value = value }
}

// Declarations spell a private type with this file's private discriminator,
// while its runtime name spells the anonymous context that declares it.
private struct SwiftPrivateMemberPoint { var x: Double, y: Double }
// Unoptimized methods keep the entry points that ABIBridge resolves.
private final class SwiftPrivateMemberCaller {
    @inline(never) @_optimize(none)
    func apply(_ callback: (SwiftPrivateMemberPoint) -> Double) -> Double {
        callback(SwiftPrivateMemberPoint(x: 40, y: 2))
    }
    @inline(never) @_optimize(none) func make() -> SwiftPrivateMemberPoint {
        SwiftPrivateMemberPoint(x: 40, y: 2)
    }
    @inline(never) @_optimize(none)
    func sum(
        _ pairs: [(SwiftPrivateMemberPoint, SwiftPrivateMemberPoint)?],
        _ pair: (SwiftPrivateMemberPoint, Int)
    ) -> Double {
        pairs.reduce(pair.0.x + pair.0.y) { $0 + ($1.map { $0.0.x + $0.1.y } ?? 0) }
    }
}

extension NSObject {
    @inline(never) public func bridgeImportedExtension(_ value: Int) -> Int { value + 1 }
}

extension NativeValue {
    @inline(never) public func bridgeExtensionCount(_ value: Int) -> Int { type.size + value }
    @inline(never) public static func bridgeExtensionStatic(_ value: Int) -> Int { value + 1 }
    public var bridgeExtensionSize: Int { type.size }
}

struct SwiftMemberInvocationTests {
    #if os(macOS)
    @Test func protocolExtensionReceiversPassRepresentationsAsIndirectSelf() async throws {
        let module = "IndirectSelf_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public protocol Valued {
                    var value: Int64 { get }
                }
                extension Valued {
                    @inline(never) public func doubled() -> Int64 { value * 2 }
                }
                public struct Counter: Valued {
                    public var value: Int64
                }
                """,
            linkArguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let member = "(extension in \(module)):\(module).Valued.doubled() -> Swift.Int64"
        // The extension takes Self by address, so the representation's storage
        // stands for the resilient value.
        let counter = try await runtime.resolveSwiftType(
            named: module + ".Counter",
            as: Int64.self,
            in: .path(library.libraryURL)
        )
        let doubled = try await counter.resolve(.method(member, as: (() -> Int64).self))
        #expect(try unsafe doubled.unsafeInvoke(on: Int64(21)) == 42)
        // Storage smaller than the value cannot stand for it.
        let narrow = try await runtime.resolveSwiftType(
            named: module + ".Counter",
            as: Int32.self,
            in: .path(library.libraryURL)
        )
        do {
            _ = try await narrow.resolve(.method(member, as: (() -> Int64).self))
            Issue.record("Four bytes stood for an eight-byte Self")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .receiver)
        }
    }

    @Test func protocolRequirementGettersUseTheReceiversConformance() async throws {
        let module = "ProtocolGetter_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public struct Payload {
                    public let object: AnyObject
                    public let text: String
                }
                public protocol Provider {
                    var payload: Payload { get }
                }
                public protocol ObjectProviderProtocol: AnyObject {
                    var payload: Payload { get }
                }
                public struct ValueProvider: Provider {
                    let object: AnyObject
                    public var payload: Payload { Payload(object: object, text: "value") }
                }
                public final class ObjectProvider: Provider, ObjectProviderProtocol {
                    let object: AnyObject
                    init(_ object: AnyObject) { self.object = object }
                    public var payload: Payload { Payload(object: object, text: "object") }
                }
                public func makeValueProvider(_ object: AnyObject) -> ValueProvider {
                    ValueProvider(object: object)
                }
                public func makeObjectProvider(_ object: AnyObject) -> ObjectProvider {
                    ObjectProvider(object)
                }
                """,
            linkArguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let payloadType = try await runtime.resolveSwiftType(named: module + ".Payload")
        let payloadABI = try NativeType.opaque(named: payloadType.name)
        let declaration = module + ".Provider.payload.getter : " + payloadType.name
        let objectGetter = try await payloadType.resolve(
            .getter(
                "object",
                as: (() -> AnyObject).self,
                receiverABI: payloadABI
            )
        )
        let textGetter = try await payloadType.resolve(
            .getter(
                "text",
                as: (() -> String).self,
                receiverABI: payloadABI
            )
        )
        for (name, text, protocolName) in [
            ("ValueProvider", "value", "Provider"),
            ("ObjectProvider", "object", "Provider"),
            ("ObjectProvider", "object", "ObjectProviderProtocol"),
        ] {
            let type = try await runtime.resolveSwiftType(named: module + "." + name)
            let factory = try await runtime.resolve(
                .function(
                    module + ".make" + name + "(Swift.AnyObject) -> " + type.name,
                    as: ((AnyObject) -> NativeSwiftValue).self,
                    valueABIs: [
                        type: name == "ValueProvider" ? try .opaque(named: type.name) : .pointer
                    ]
                )
            )
            let getter = try await type.resolve(
                .getter(
                    module + "." + protocolName + ".payload.getter : " + payloadType.name,
                    as: (() -> NativeSwiftValue).self,
                    valueABIs: [payloadType: payloadABI]
                )
            )
            weak var observed: NSObject?
            var result: NativeSwiftValue?
            do {
                let object = NSObject()
                observed = object
                let receiver = try unsafe factory.unsafeInvoke(object)
                result = try unsafe getter.unsafeInvoke(on: receiver)
                #expect(try unsafe objectGetter.unsafeInvoke(on: #require(result)) === object)
                #expect(try unsafe textGetter.unsafeInvoke(on: #require(result)) == text)
            }
            runtime.removeCachedResults()
            #expect(observed != nil)
            result = nil
            #expect(observed == nil)
        }
        let unrelated = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        #expect {
            try unrelated.resolveAndWait(
                .getter(
                    declaration,
                    as: (() -> NativeSwiftValue).self,
                    valueABIs: [payloadType: payloadABI]
                )
            )
        } throws: { error in
            guard case ABIResolutionError.signatureMismatch = error else { return false }
            return true
        }
    }
    @Test func protocolRequirementMethodsBindAssociatedTypesAndIndirectSelf() async throws {
        let module = "ProtocolMethod_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public struct Payload {
                    public let object: AnyObject
                    public let number: Int64
                }
                public protocol RequestProtocol { associatedtype Output }
                public struct Request: RequestProtocol {
                    public typealias Output = Payload
                    let number: Int64
                }
                public struct Environment { let offset: Int64 }
                public final class Service {
                    let offset: Int64
                    init(_ offset: Int64) { self.offset = offset }
                }
                public final class Box<Value> {
                    public let value: Value
                    init(_ value: Value) { self.value = value }
                }
                public protocol Processor {
                    associatedtype Job: RequestProtocol
                    associatedtype Environment
                    func process(_ job: Job, in environment: Environment, using service: Service) -> Box<Job.Output>
                }
                public struct ValueProcessor: Processor {
                    let object: AnyObject
                    public func process(_ job: Request, in environment: Environment, using service: Service) -> Box<Payload> {
                        Box(Payload(object: object, number: job.number * 100 + environment.offset * 10 + service.offset))
                    }
                }
                public final class ObjectProcessor: Processor {
                    let object: AnyObject
                    init(_ object: AnyObject) { self.object = object }
                    public func process(_ job: Request, in environment: Environment, using service: Service) -> Box<Payload> {
                        Box(Payload(object: object, number: job.number * 100 + environment.offset * 10 + service.offset + 1))
                    }
                }
                public func makeValueProcessor(_ object: AnyObject) -> ValueProcessor { ValueProcessor(object: object) }
                public func makeObjectProcessor(_ object: AnyObject) -> ObjectProcessor { ObjectProcessor(object) }
                public func makeRequest() -> Request { Request(number: 30) }
                public func makeEnvironment() -> Environment { Environment(offset: 7) }
                public func makeService() -> Service { Service(5) }
                public func direct(_ object: AnyObject, _ useClass: Bool) -> Int64 {
                    func invoke<Value: Processor>(_ value: Value) -> Int64
                    where Value.Job == Request, Value.Environment == Environment {
                        value.process(makeRequest(), in: makeEnvironment(), using: makeService()).value.number
                    }
                    return useClass ? invoke(ObjectProcessor(object)) : invoke(ValueProcessor(object: object))
                }
                """,
            linkArguments: ["-O", "-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let payloadType = try await runtime.resolveSwiftType(named: module + ".Payload")
        let payloadABI = try NativeType.opaque(named: payloadType.name)
        let serviceType = try await runtime.resolveSwiftType(named: module + ".Service")
        let declaration =
            module + ".Processor.process(_: A.Job, in: A.Environment, using: "
            + serviceType.name + ") -> " + module + ".Box<A.Job.Output>"
        typealias Signature = (NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) ->
            NativeSwiftValue
        let objectGetter = try await payloadType.resolve(
            .getter(
                "object",
                as: (() -> AnyObject).self,
                receiverABI: payloadABI
            )
        )
        let numberGetter = try await payloadType.resolve(
            .getter(
                "number",
                as: (() -> Int64).self,
                receiverABI: payloadABI
            )
        )
        let direct = try await runtime.resolve(
            .function(
                module + ".direct(_:_:)",
                as: ((AnyObject, Bool) -> Int64).self
            )
        )
        var inputs: [NativeSwiftValue] = []
        for name in ["Request", "Environment", "Service"] {
            let type = try await runtime.resolveSwiftType(named: module + "." + name)
            let make = try await runtime.resolve(
                .function(
                    module + ".make" + name + "()",
                    as: (() -> NativeSwiftValue).self,
                    valueABIs: [type: name == "Service" ? .pointer : try .opaque(named: type.name)]
                )
            )
            inputs.append(try unsafe make.unsafeInvoke())
        }
        for name in ["ValueProcessor", "ObjectProcessor"] {
            let type = try await runtime.resolveSwiftType(named: module + "." + name)
            let factory = try await runtime.resolve(
                .function(
                    module + ".make" + name + "(_:)",
                    as: ((AnyObject) -> NativeSwiftValue).self,
                    valueABIs: [
                        type: name == "ValueProcessor" ? try .opaque(named: type.name) : .pointer
                    ]
                )
            )
            let method = try await type.resolve(
                .method(
                    declaration,
                    as: Signature.self
                )
            )
            #expect(method.symbol.declaration.name.hasPrefix("dispatch thunk of "))
            weak var observed: NSObject?
            var result: NativeSwiftValue?
            do {
                let object = NSObject()
                observed = object
                let receiver = try unsafe factory.unsafeInvoke(object)
                let expected = try unsafe direct.unsafeInvoke(object, name == "ObjectProcessor")
                result = try unsafe method.unsafeInvoke(
                    on: receiver,
                    inputs[0],
                    inputs[1],
                    inputs[2]
                )
                let valueGetter = try await #require(result).type.resolve(
                    .getter(
                        "value",
                        as: (() -> NativeSwiftValue).self
                    )
                )
                let payload = try unsafe valueGetter.unsafeInvoke(on: #require(result))
                #expect(try unsafe objectGetter.unsafeInvoke(on: payload) === object)
                #expect(try unsafe numberGetter.unsafeInvoke(on: payload) == expected)
                #expect(!receiver.isConsumed && inputs.allSatisfy { !$0.isConsumed })
            }
            runtime.removeCachedResults()
            #expect(observed != nil)
            result = nil
            #expect(observed == nil)
        }
        let unrelated = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        #expect {
            try unrelated.resolveAndWait(
                .method(
                    declaration,
                    as: Signature.self
                )
            )
        } throws: { error in
            guard case ABIResolutionError.signatureMismatch = error else { return false }
            return true
        }
    }
    @Test func protocolRequirementMethodsPreserveMethodGenericMetadataAndWitnesses() async throws {
        let module =
            "ProtocolGenericMethod_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public protocol Mapper {
                    func runtimeType<Value>(_ value: Value) -> Any.Type
                    func describe<Value: CustomStringConvertible>(_ value: Value) -> String
                    func withBoxes<Value>(_ value: Box<Value>, _ owner: Box<Self>) -> Any.Type
                }
                public final class Box<Value> {
                    let value: Value
                    init(_ value: Value) { self.value = value }
                }
                public final class ObjectMapper: Mapper {
                    public init() {}
                    public func runtimeType<Value>(_ value: Value) -> Any.Type { Value.self }
                    public func describe<Value: CustomStringConvertible>(_ value: Value) -> String { value.description }
                    public func withBoxes<Value>(_ value: Box<Value>, _ owner: Box<ObjectMapper>) -> Any.Type { Value.self }
                }
                public func makeMapper() -> ObjectMapper { ObjectMapper() }
                public func makeBox(_ value: ObjectMapper) -> Box<ObjectMapper> { Box(value) }
                public func makeValueBox(_ value: String) -> Box<String> { Box(value) }
                """,
            linkArguments: ["-O", "-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.resolve(
            .function(
                module + ".makeMapper()",
                as: (() -> NativeSwiftValue).self
            )
        )
        let receiver = try unsafe make.unsafeInvoke()
        let method = try await receiver.type.resolve(
            .method(
                module + ".Mapper.runtimeType<A>(A1) -> Any.Type",
                as: ((String) -> Any.Type).self,
                genericArguments: [.type(String.self)]
            )
        )
        let actual = try unsafe method.unsafeInvoke(on: receiver, "metadata")
        try #require(ObjectIdentifier(actual) == ObjectIdentifier(String.self))
        let describe = try await receiver.type.resolve(
            .method(
                module
                    + ".Mapper.describe<A where A1: Swift.CustomStringConvertible>(A1) -> Swift.String",
                as: ((Int64) -> String).self,
                genericArguments: [.type(Int64.self)]
            )
        )
        #expect(try unsafe describe.unsafeInvoke(on: receiver, 42) == "42")
        let makeBox = try await runtime.resolve(
            .function(
                module + ".makeBox(_:)",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self
            )
        )
        let owner = try unsafe makeBox.unsafeInvoke(receiver)
        let makeValueBox = try await runtime.resolve(
            .function(
                module + ".makeValueBox(_:)",
                as: ((String) -> NativeSwiftValue).self
            )
        )
        let input = try unsafe makeValueBox.unsafeInvoke("metadata")
        let withBoxes = try await receiver.type.resolve(
            .method(
                module + ".Mapper.withBoxes<A>(" + module + ".Box<A1>, " + module
                    + ".Box<A>) -> Any.Type",
                as: ((NativeSwiftValue, NativeSwiftValue) -> Any.Type).self,
                genericArguments: [.type(String.self)]
            )
        )
        let withBoxesType = try unsafe withBoxes.unsafeInvoke(on: receiver, input, owner)
        #expect(ObjectIdentifier(withBoxesType) == ObjectIdentifier(String.self))
        #expect(!receiver.isConsumed && !input.isConsumed && !owner.isConsumed)
    }

    @Test func protocolRequirementsWithoutDispatchThunksRunTheConformancesWitness() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let base = "Witnessed_" + suffix
        let other = "Conformers_" + suffix
        let last = "Stripped_" + suffix
        let protocols = try FixtureLibrary(
            swiftModule: base,
            swiftSource: """
                public protocol Shape {
                    init()
                    var name: String { get set }
                    func area() -> Int64
                    func scaled(_ factor: Int64) -> Int64
                }
                extension Shape {
                    @inline(never) public func area() -> Int64 { -1 }
                    @inline(never) public func scaled(_ text: String) -> String { "scaled " + text }
                    @inline(never) public func describe() -> String { "shape \\(area())" }
                }
                public final class Square: Shape {
                    public var name = "square"
                    let size: Int64
                    public init() { size = 0 }
                    public init(_ size: Int64) { self.size = size }
                    @inline(never) public func area() -> Int64 { size * size }
                    @inline(never) public func scaled(_ factor: Int64) -> Int64 { size * factor }
                }
                public final class Twin: Shape {
                    public var name = "twin"
                    let size: Int64
                    public init() { size = 0 }
                    public init(_ size: Int64) { self.size = size }
                    @inline(never) public func area() -> Int64 { size * size }
                    @inline(never) public func scaled(_ factor: Int64) -> Int64 { size * factor }
                }
                public final class Crate<Element> { public init() {} }
                extension Crate: Shape where Element: Equatable {
                    public var name: String {
                        get { "crate" }
                        set {}
                    }
                    @inline(never) public func area() -> Int64 { 21 }
                    @inline(never) public func scaled(_ factor: Int64) -> Int64 { 21 * factor }
                }
                public func makeSquare() -> AnyObject { Square(3) }
                public func makeTwin() -> AnyObject { Twin(4) }
                public func makeCrate() -> AnyObject { Crate<Int64>() }
                """,
            linkArguments: ["-O", "-emit-module"]
        )
        defer { protocols.cleanup() }
        // Another module's conformance mangles its witnesses in that module.
        let conformers = try FixtureLibrary(
            swiftModule: other,
            swiftSource: """
                import \(base)
                open class Plate: Shape {
                    public var name = "plate"
                    public required init() {}
                    @inline(never) public func area() -> Int64 { 11 }
                    @inline(never) public func scaled(_ factor: Int64) -> Int64 { 11 * factor }
                }
                public func makePlate() -> AnyObject { Plate() }
                """,
            linkArguments: [
                "-O", "-emit-module", "-I", protocols.directory.path, protocols.libraryURL.path,
            ]
        )
        defer { conformers.cleanup() }
        // Stripping removes the local witness symbols of Hidden's conformance.
        // Saucer inherits Plate's conformance from another module.
        let stripped = try FixtureLibrary(
            swiftModule: last,
            swiftSource: """
                import \(base)
                import \(other)
                public final class Hidden: Shape {
                    public var name = "hidden"
                    public init() {}
                    @inline(never) public func area() -> Int64 { 5 }
                    @inline(never) public func scaled(_ factor: Int64) -> Int64 { 5 * factor }
                }
                public final class Saucer: Plate {}
                public func makeHidden() -> AnyObject { Hidden() }
                public func makeSaucer() -> AnyObject { Saucer() }
                """,
            stripped: true,
            linkArguments: [
                "-O", "-I", protocols.directory.path, "-I", conformers.directory.path,
                protocols.libraryURL.path, conformers.libraryURL.path,
            ]
        )
        defer { stripped.cleanup() }
        let runtime = ABIRuntime()
        let libraries = [base: protocols, other: conformers, last: stripped]

        // The linker folds Square's and Twin's identical witnesses into one
        // address; each still serves only its own conformance.
        let witnesses = try ["Square", "Twin"].map { owner in
            let symbol = try runtime.resolveAndWait(
                NativeDeclaration(
                    name: "protocol witness for \(base).Shape.area() -> Swift.Int64"
                        + " in conformance \(base).\(owner) : \(base).Shape in \(base)",
                    language: .swift
                ),
                in: .path(protocols.libraryURL)
            )
            return unsafe symbol.withUnsafeAddress { UInt(bitPattern: $0) }
        }
        try #require(witnesses[0] == witnesses[1])
        func area(
            _ module: String,
            _ type: String,
            _ arguments: [NativeSwiftGenericArgument] = []
        ) async throws -> Int64 {
            let scope = ImageSelector.path(libraries[module]!.libraryURL)
            let make = try await runtime.resolve(
                .function(
                    module + ".make" + type + "()",
                    as: (() -> AnyObject).self
                ),
                in: scope
            )
            let owner = try await runtime.resolveSwiftType(
                named: module + "." + type,
                in: scope,
                genericArguments: arguments
            )
            let area = try await owner.resolve(
                .method(
                    base + ".Shape.area()",
                    as: (() -> Int64).self
                )
            )
            #expect(area.symbol.declaration.name.hasPrefix("protocol witness for "))
            return try unsafe area.unsafeInvoke(on: make.unsafeInvoke())
        }
        #expect(try await area(base, "Square") == 9)
        #expect(try await area(base, "Twin") == 16)
        // A conditional conformance's witness table is instantiated for the type.
        #expect(try await area(base, "Crate", [.type(Int64.self)]) == 21)
        #expect(try await area(other, "Plate") == 11)
        // A subclass finds its superclass's conformance in the superclass's module.
        #expect(try await area(last, "Saucer") == 11)

        // An initializer requirement runs the witness of the conformance that
        // Saucer inherits from another module, and constructs a Saucer.
        let saucer = try await runtime.resolveSwiftType(
            named: last + ".Saucer",
            in: .path(stripped.libraryURL)
        )
        let makeSaucer = try await saucer.resolve(
            .initializer(
                base + ".Shape.init()",
                as: (() -> AnyObject).self
            )
        )
        let made = try unsafe makeSaucer.unsafeInvoke()
        #expect(String(describing: type(of: made)) == "Saucer")

        // Other conformances' witnesses show that Shape declares area(), so
        // its default implementation does not stand in for Hidden's witness.
        let hidden = try await runtime.resolveSwiftType(
            named: last + ".Hidden",
            in: .path(stripped.libraryURL)
        )
        await #expect {
            _ = try await hidden.resolve(
                .method(
                    base + ".Shape.area()",
                    as: (() -> Int64).self
                )
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("witness of \(last).Hidden's conformance")
        }
        let makeHidden = try await runtime.resolve(
            .function(
                last + ".makeHidden()",
                as: (() -> AnyObject).self
            ),
            in: .path(stripped.libraryURL)
        )
        let defaultArea = try await hidden.resolve(
            .method(
                "(extension in \(base)):\(base).Shape.area() -> Swift.Int64",
                as: (() -> Int64).self
            )
        )
        #expect(try unsafe defaultArea.unsafeInvoke(on: makeHidden.unsafeInvoke()) == -1)

        // Shape requires scaled(Int64) and its extension declares
        // scaled(String). Hidden's missing witness rules out only the
        // requirement, which a request for String does not name.
        let scaledText = try await hidden.resolve(
            .method(
                base + ".Shape.scaled(Swift.String) -> Swift.String",
                as: ((String) -> String).self
            )
        )
        let receiver = try unsafe makeHidden.unsafeInvoke()
        #expect(try unsafe scaledText.unsafeInvoke(on: receiver, "a") == "scaled a")
        let scaledLabel = try await hidden.resolve(
            .method(
                base + ".Shape.scaled(_:)",
                as: ((String) -> String).self
            )
        )
        #expect(try unsafe scaledLabel.unsafeInvoke(on: receiver, "b") == "scaled b")
        await #expect {
            _ = try await hidden.resolve(
                .method(
                    base + ".Shape.scaled(_:)",
                    as: ((Int64) -> Int64).self
                )
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("witness of \(last).Hidden's conformance")
        }
        // The witnesses of a conformance in Shape's image name its method
        // requirements, so a method that only its extension declares applies.
        // The property's modify coroutine, which has a witness that the index
        // does not record, is not a method and does not need a name.
        let describe = try await hidden.resolve(
            .method(
                base + ".Shape.describe()",
                as: (() -> String).self
            )
        )
        #expect(try unsafe describe.unsafeInvoke(on: receiver) == "shape 5")
        // Square's own witness table names them as well.
        let square = try await runtime.resolveSwiftType(
            named: base + ".Square",
            in: .path(protocols.libraryURL)
        )
        let makeSquare = try await runtime.resolve(
            .function(
                base + ".makeSquare()",
                as: (() -> AnyObject).self
            ),
            in: .path(protocols.libraryURL)
        )
        let describeSquare = try await square.resolve(
            .method(
                base + ".Shape.describe()",
                as: (() -> String).self
            )
        )
        #expect(try unsafe describeSquare.unsafeInvoke(on: makeSquare.unsafeInvoke()) == "shape 9")

    }

    @Test func extensionMembersDoNotStandInForUnnamedRequirements() async throws {
        let module = "Gauges_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Stripping removes every witness, and the module exports no method
        // descriptors, so nothing names Gauge's requirement.
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public protocol Gauge { func read() -> Int64 }
                extension Gauge {
                    @inline(never) public func read() -> Int64 { -1 }
                    public var label: String { "gauge" }
                }
                public protocol Calibrated: Gauge {}
                extension Calibrated {
                    @inline(never) public func read() -> Int64 { -2 }
                }
                public protocol Tagged { associatedtype Tag }
                extension Tagged {
                    @inline(never) public func tagName() -> String { "tagged" }
                }
                public protocol Resettable { init() }
                extension Resettable {
                    public init(value: Int64) { self.init() }
                }
                extension Equatable {
                    @inline(never) public static func kindName() -> String { "equatable" }
                }
                public final class Meter: Calibrated, Tagged, Resettable, Equatable {
                    public typealias Tag = Int64
                    public static func == (lhs: Meter, rhs: Meter) -> Bool { lhs === rhs }
                    public init() {}
                    @inline(never) public func read() -> Int64 { 7 }
                }
                public func makeMeter() -> AnyObject { Meter() }
                """,
            stripped: true,
            linkArguments: ["-O"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(library.libraryURL)
        let meter = try await runtime.resolveSwiftType(named: module + ".Meter", in: scope)
        let make = try await runtime.resolve(
            .function(
                module + ".makeMeter()",
                as: (() -> AnyObject).self
            ),
            in: scope
        )
        await #expect {
            _ = try await meter.resolve(
                .method(
                    module + ".Gauge.read()",
                    as: (() -> Int64).self
                )
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("whether it is one of them is not established")
        }
        await #expect {
            _ = try await meter.resolve(
                .method(module + ".Calibrated.read()", as: (() -> Int64).self)
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains(module + ".Gauge")
                && message.contains("whether it is one of them is not established")
        }
        // Gauge has no getter requirement, so its extension's getter applies.
        let label = try await meter.resolve(
            .getter(
                module + ".Gauge.label",
                as: (() -> String).self
            )
        )
        #expect(try unsafe label.unsafeInvoke(on: make.unsafeInvoke()) == "gauge")
        // Tagged requires only an associated type, which no member names.
        let tagName = try await meter.resolve(
            .method(
                module + ".Tagged.tagName()",
                as: (() -> String).self
            )
        )
        #expect(try unsafe tagName.unsafeInvoke(on: make.unsafeInvoke()) == "tagged")
        // The standard library exports Equatable's method descriptors, which
        // name its static requirement ==.
        let kindName = try await meter.resolve(
            .staticMethod(
                "Swift.Equatable.kindName()",
                as: (() -> String).self
            )
        )
        #expect(try unsafe kindName.unsafeInvoke() == "equatable")
        // A complete declaration of a protocol extension's initializer.
        let reset = try await meter.resolve(
            .initializer(
                "(extension in \(module)):\(module).Resettable.init(value: Swift.Int64) -> A",
                as: ((Int64) -> AnyObject).self
            )
        )
        #expect(String(describing: type(of: try unsafe reset.unsafeInvoke(4))) == "Meter")
        // A complete extension declaration names the extension member.
        let read = try await meter.resolve(
            .method(
                "(extension in \(module)):\(module).Gauge.read() -> Swift.Int64",
                as: (() -> Int64).self
            )
        )
        #expect(try unsafe read.unsafeInvoke(on: make.unsafeInvoke()) == -1)
        let calibratedRead = try await meter.resolve(
            .method(
                "(extension in \(module)):\(module).Calibrated.read() -> Swift.Int64",
                as: (() -> Int64).self
            )
        )
        #expect(try unsafe calibratedRead.unsafeInvoke(on: make.unsafeInvoke()) == -2)
    }

    @Test(arguments: [false, true])
    func inheritedRequirementsDoNotResolveToExtensionMembers(libraryEvolution: Bool) async throws {
        let module = "Inherited_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public protocol Root {
                    func read(_ value: Int64) -> Int64
                    var value: Int64 { get }
                    static func code() -> Int64
                }
                public protocol Middle: Root {}
                public protocol Leaf: Middle {}
                extension Leaf {
                    @inline(never) public func read(_ value: Int64) -> Int64 { -value }
                    @inline(never) public func read(_ value: String) -> String { "leaf " + value }
                    public var value: Int64 { -1 }
                    @inline(never) public static func code() -> Int64 { -2 }
                    @inline(never) public func label() -> String { "leaf" }
                }
                public final class Meter: Leaf {
                    public init() {}
                    public func read(_ value: Int64) -> Int64 { value + 1 }
                    public var value: Int64 { 7 }
                    public static func code() -> Int64 { 8 }
                }
                public func makeMeter() -> AnyObject { Meter() }
                """,
            linkArguments: ["-O"] + (libraryEvolution ? ["-enable-library-evolution"] : [])
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(library.libraryURL)
        let type = try await runtime.resolveSwiftType(named: module + ".Meter", in: scope)
        let make = try await runtime.resolve(
            .function(module + ".makeMeter()", as: (() -> AnyObject).self),
            in: scope
        )
        let object = try unsafe make.unsafeInvoke()
        for name in [module + ".Leaf.read(_:)", module + ".Leaf.read(Swift.Int64) -> Swift.Int64"] {
            await #expect {
                _ = try await type.resolve(.method(name, as: ((Int64) -> Int64).self))
            } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains(module + ".Root.read") && message.contains("requirement")
            }
        }
        await #expect {
            _ = try await type.resolve(.getter(module + ".Leaf.value", as: (() -> Int64).self))
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains(module + ".Root")
        }
        await #expect {
            _ = try await type.resolve(
                .staticMethod(module + ".Leaf.code()", as: (() -> Int64).self)
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains(module + ".Root")
        }
        let read = try await type.resolve(
            .method(
                "(extension in \(module)):\(module).Leaf.read(Swift.Int64) -> Swift.Int64",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe read.unsafeInvoke(on: object, 4) == -4)
        for name in [
            module + ".Leaf.read(_:)", module + ".Leaf.read(Swift.String) -> Swift.String",
        ] {
            let text = try await type.resolve(.method(name, as: ((String) -> String).self))
            #expect(try unsafe text.unsafeInvoke(on: object, "a") == "leaf a")
        }
        let label = try await type.resolve(
            .method(module + ".Leaf.label()", as: (() -> String).self)
        )
        #expect(try unsafe label.unsafeInvoke(on: object) == "leaf")
    }

    @Test func objectiveCProtocolExtensionMembersResolveAfterRequirementChecks() async throws {
        let module = "Foreign_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Objective-C protocols have no Swift protocol descriptor, and their
        // runtime records name requirements only by selectors.
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                import Foundation
                @objc public protocol Foreign {
                    func storeValue(_ value: Int64)
                }
                extension Foreign {
                    @inline(never) public func bonus() -> Int64 { 2 }
                    @inline(never) public func store(value: Int64) -> Int64 { value }
                }
                extension NSCopying {
                    @inline(never) public func copied() -> Int64 { 3 }
                }
                extension NSObjectProtocol {
                    @inline(never) public func extra() -> Int64 { 4 }
                    @inline(never) public func isProxy() -> Bool { false }
                }
                public final class Impl: NSObject, Foreign, NSCopying {
                    public func storeValue(_ value: Int64) {}
                    public func copy(with zone: NSZone? = nil) -> Any { self }
                }
                public func makeImpl() -> AnyObject { Impl() }
                """,
            linkArguments: ["-O"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(library.libraryURL)
        let type = try await runtime.resolveSwiftType(named: module + ".Impl", in: scope)
        let make = try await runtime.resolve(
            .function(
                module + ".makeImpl()",
                as: (() -> AnyObject).self
            ),
            in: scope
        )
        let object = try unsafe make.unsafeInvoke()
        let bonus = try await type.resolve(
            .method(
                module + ".Foreign.bonus()",
                as: (() -> Int64).self
            )
        )
        #expect(try unsafe bonus.unsafeInvoke(on: object) == 2)
        // The requirement storeValue: is another member than store(value:).
        let store = try await type.resolve(
            .method(
                module + ".Foreign.store(value:)",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe store.unsafeInvoke(on: object, 42) == 42)
        // An imported protocol's extension member.
        let copied = try await type.resolve(
            .method(
                "__C.NSCopying.copied()",
                as: (() -> Int64).self
            )
        )
        #expect(try unsafe copied.unsafeInvoke(on: object) == 3)
        let extra = try await type.resolve(
            .method("__C.NSObject.extra()", as: (() -> Int64).self)
        )
        #expect(try unsafe extra.unsafeInvoke(on: object) == 4)
        await #expect {
            _ = try await type.resolve(.method("__C.NSObject.isProxy()", as: (() -> Bool).self))
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("isProxy") && message.contains("SDK imports it as isProxy()")
        }
    }

    @Test func objectiveCRequirementsAreNotReplacedByExtensionMembers() async throws {
        let module = "ObjCRequirements_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                import Foundation
                @objc public protocol Ancestor { func inherited() -> Double }
                @objc public protocol Parent: Ancestor {}
                @objc public protocol Store: Parent {
                    @objc(renamedSelector:) func extra(_ value: Int64) -> Int64
                    @objc(isOn) var on: Bool { get }
                    var value: Int64 { get set }
                    static func make() -> Int64
                }
                @objc public protocol OptionalStore {
                    @objc optional func maybe() -> Int64
                    @objc optional var level: Int64 { get }
                }
                extension Store {
                    @inline(never) public func extra(_ value: Int64) -> Int64 { -1 }
                    @inline(never) public func inherited() -> Double { -1 }
                    public var on: Bool { false }
                    public var value: Int64 { get { -1 } set {} }
                    @inline(never) public static func make() -> Int64 { -1 }
                }
                extension OptionalStore {
                    @inline(never) public func maybe() -> Int64 { 42 }
                    public var level: Int64 { 43 }
                    public var nullableLevel: Int64? { 44 }
                }
                public final class Impl: NSObject, Store, OptionalStore {
                    public func extra(_ value: Int64) -> Int64 { value }
                    public func inherited() -> Double { 1 }
                    public var on: Bool { true }
                    public var value: Int64 = 2
                    public static func make() -> Int64 { 3 }
                    @objc public func maybe() -> Int64 { 45 }
                    @objc public var level: Int64 { 46 }
                }
                public func makeImpl() -> AnyObject { Impl() }
                """,
            linkArguments: ["-O"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(library.libraryURL)
        let type = try await runtime.resolveSwiftType(named: module + ".Impl", in: scope)
        func expectRequirement(_ selector: String, _ operation: () async throws -> Void) async {
            await #expect { try await operation() } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains(selector)
                    && message.contains("no record establishes its Swift name")
                    && message.contains("(extension in \(module)):")
                    && message.contains("NativeObject")
            }
        }
        await expectRequirement("renamedSelector:") {
            _ = try await type.resolve(
                .method(module + ".Store.extra(_:)", as: ((Int64) -> Int64).self)
            )
        }
        await expectRequirement("inherited") {
            _ = try await type.resolve(
                .method(module + ".Store.inherited()", as: (() -> Double).self)
            )
        }
        await expectRequirement("isOn") {
            _ = try await type.resolve(.getter(module + ".Store.on", as: (() -> Bool).self))
        }
        await expectRequirement("setValue:") {
            _ = try await type.resolve(.setter(module + ".Store.value", as: ((Int64) -> Void).self))
        }
        await expectRequirement("make") {
            _ = try await type.resolve(
                .staticMethod(module + ".Store.make()", as: (() -> Int64).self)
            )
        }
        let make = try await runtime.resolve(
            .function(module + ".makeImpl()", as: (() -> AnyObject).self),
            in: scope
        )
        let object = try unsafe make.unsafeInvoke()
        let exact = try await type.resolve(
            .method(
                "(extension in \(module)):\(module).Store.extra(Swift.Int64) -> Swift.Int64",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe exact.unsafeInvoke(on: object, 9) == -1)
        let maybe = try await type.resolve(
            .method(module + ".OptionalStore.maybe()", as: (() -> Int64).self)
        )
        #expect(try unsafe maybe.unsafeInvoke(on: object) == 42)
        let level = try await type.resolve(
            .getter(module + ".OptionalStore.level", as: (() -> Int64).self)
        )
        #expect(try unsafe level.unsafeInvoke(on: object) == 43)
        await expectRequirement("level") {
            _ = try await type.resolve(
                .getter(module + ".OptionalStore.nullableLevel", as: (() -> Int64?).self)
            )
        }
        await expectRequirement("level") {
            _ = try await type.resolve(
                .getter(module + ".OptionalStore.nullableLevel", as: (() -> NativeSwiftValue).self)
            )
        }
    }

    @Test func classMembersExportedOnlyThroughDispatchThunksCaptureTheSelectedEntry() async throws {
        let module = "ThunkOnly_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = "_$s\(module.utf8.count)\(module)"
        let lists = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lists) }
        // Keep dispatch thunks and method descriptors while hiding and stripping
        // member bodies, as frameworks such as SimulatorKit ship them.
        let hidden = lists.appendingPathComponent("hidden.txt")
        try ["4BaseC", "7DerivedC", "7GenericC"].flatMap { owner in
            ["F", "FZ", "vg", "vgZ", "vs", "vM"].map { prefix + owner + "*" + $0 }
        }.joined(separator: "\n").write(to: hidden, atomically: true, encoding: .utf8)
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public enum Mode { case on, off }
                open class Base {
                    public init() {}
                    open var mode: Mode = .off
                    open var count: Int64 = 0
                    @inline(never) open func value(_ input: Int64) -> Int64 { input + 1 }
                    @inline(never) open func value(_ input: Int64) async -> Int64 { input + 3 }
                    @inline(never) open func replacement(_ input: Int64) -> Int64 { input + 100 }
                    @inline(never) open func opaque() -> some Equatable { count }
                    @inline(never) open class func kind() -> Int64 { 5 }
                    open class var kindValue: Int64 { 5 }
                    open var asyncCount: Int64 { get async { count } }
                }
                open class Derived: Base {
                    @inline(never) public override func value(_ input: Int64) -> Int64 { input + 2 }
                    @inline(never) public override class func kind() -> Int64 { 6 }
                    @inline(never) public override func replacement(_ input: Int64) -> Int64 { input + 200 }
                }
                open class Generic<Element> {
                    public init() {}
                    open class var kindValue: Int64 { 5 }
                }
                public func makeBase() -> Base { Base() }
                public func makeGeneric() -> Generic<Int64> { Generic() }
                public func makeDerived() -> Base { Derived() }
                @inline(never) public func value(_ object: Base, _ input: Int64) -> Int64 { object.value(input) }
                @inline(never) public func describe(_ object: Base) -> String { "\\(object.mode):\\(object.count)" }
                """,
            stripped: true,
            linkArguments: [
                "-O", "-enable-library-evolution", "-emit-module", "-Xlinker",
                "-unexported_symbols_list", "-Xlinker", hidden.path,
            ]
        )
        defer { library.cleanup() }
        // A same-signature member in another module's extension does not hide
        // the defining class's member; one with another effect remains
        // available.
        let extensions = try FixtureLibrary(
            swiftModule: "ThunkExtension_"
                + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            swiftSource: """
                import \(module)
                extension Base {
                    @inline(never) public func value(_ input: Int64) -> Int64 { input + 50 }
                    public var count: Int64 { get async { 99 } }
                    public static func kind() -> Int64 { 77 }
                    public static var kindValue: Int64 { get async { 88 } }
                }
                extension Generic {
                    public static var kindValue: Int64 { get async { 89 } }
                }
                """,
            linkArguments: ["-I", library.directory.path, library.libraryURL.path]
        )
        defer { extensions.cleanup() }

        let runtime = ABIRuntime(), scope = ImageSelector.path(library.libraryURL)
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.resolve(
                .init(name: module + ".Base.value(Swift.Int64) -> Swift.Int64", language: .swift),
                in: scope
            )
        }
        let base = try await runtime.resolveSwiftType(named: module + ".Base", in: scope)
        let derived = try await runtime.resolveSwiftType(named: module + ".Derived", in: scope)
        let mode = try await runtime.resolveSwiftType(named: module + ".Mode", in: scope)
        func make(_ name: String) async throws -> AnyObject {
            let make = try await runtime.resolve(
                .function(
                    module + "." + name + "() -> " + base.name,
                    as: (() -> AnyObject).self
                ),
                in: scope
            )
            return try unsafe make.unsafeInvoke()
        }
        let baseObject = try await make("makeBase"), derivedObject = try await make("makeDerived")
        let describe = try await runtime.resolve(
            .function(
                module + ".describe(" + base.name + ") -> Swift.String",
                as: ((AnyObject) -> String).self
            ),
            in: scope
        )

        // The lookup type's entry is captured; a subclass receiver does not redispatch.
        let baseValue = try await base.resolve(
            .method(
                "value(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe baseValue.unsafeInvoke(on: baseObject, 40) == 41)
        #expect(try unsafe baseValue.unsafeInvoke(on: derivedObject, 40) == 41)
        // An override has no thunk of its own; the inherited slot of the lookup type holds it.
        let derivedValue = try derived.resolveAndWait(
            .method(
                "value(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe derivedValue.unsafeInvoke(on: derivedObject, 40) == 42)
        let bound = try await runtime.object(derivedObject).resolve(
            .method(
                "value(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe bound.unsafeInvoke(40) == 42)

        let setCount = try await base.resolve(.setter("count", as: ((Int64) -> Void).self))
        let getCount = try await base.resolve(.getter("count", as: (() -> Int64).self))
        try unsafe setCount.unsafeInvoke(on: baseObject, 7)
        #expect(try unsafe getCount.unsafeInvoke(on: baseObject) == 7)
        let extensionCount = try await base.resolve(
            .getter(
                "count",
                as: (() async -> Int64).self,
                declaredAs: "() async -> Swift.Int64"
            )
        )
        #expect(try await unsafe extensionCount.unsafeInvoke(on: baseObject) == 99)
        // A runtime-only resilient value binds its declaration through the thunk.
        let setMode = try await base.resolve(
            .setter(
                "mode.setter : " + mode.name,
                as: ((NativeSwiftValue) -> Void).self,
                valueABIs: [mode: .opaque(named: mode.name)]
            )
        )
        try unsafe setMode.unsafeInvoke(on: baseObject, try mode.makeEnumCase(named: "on"))
        #expect(try unsafe describe.unsafeInvoke(baseObject) == "on:7")

        // Relative names that need binding search dispatch thunks too, and the
        // async overload does not match the synchronous request.
        let declared = try await base.resolve(
            .method(
                "value(_:)",
                as: ((Int64) -> Int64).self,
                declaredAs: "(Swift.Int64) -> Swift.Int64"
            )
        )
        #expect(try unsafe declared.unsafeInvoke(on: baseObject, 40) == 41)
        // An accessor's async effect comes from its method descriptor.
        let asyncCount = try await base.resolve(
            .getter(
                "asyncCount",
                as: (() async -> Int64).self
            )
        )
        #expect(try await unsafe asyncCount.unsafeInvoke(on: baseObject) == 7)
        // Class members also use the lookup type's slot, and the class's
        // method hides the extension's.
        for declared in [nil, "() -> Swift.Int64"] {
            let kind = try await base.resolve(
                .staticMethod(
                    "kind()",
                    as: (() -> Int64).self,
                    declaredAs: declared
                )
            )
            #expect(try unsafe kind.unsafeInvoke() == 5)
        }
        let derivedKind = try await derived.resolve(.staticMethod("kind()", as: (() -> Int64).self))
        #expect(try unsafe derivedKind.unsafeInvoke() == 6)
        let kindValue = try await base.resolve(.staticGetter("kindValue", as: (() -> Int64).self))
        #expect(try unsafe kindValue.unsafeInvoke() == 5)
        // A class getter's descriptor says it is synchronous, so it does not
        // hide an async extension getter requested with its declaration.
        let extensionKind = try await base.resolve(
            .staticGetter(
                "kindValue",
                as: (() async -> Int64).self,
                declaredAs: "() async -> Swift.Int64"
            )
        )
        #expect(try await unsafe extensionKind.unsafeInvoke() == 88)
        // The descriptor decides this before the class layout is decoded, so
        // a generic class, whose slots are not selected, does not hide it either.
        let makeGeneric = try await runtime.resolve(
            .function(
                module + ".makeGeneric()",
                as: (() -> NativeSwiftValue).self
            ),
            in: scope
        )
        let generic = try unsafe makeGeneric.unsafeInvoke().type
        let genericKind = try await generic.resolve(
            .staticGetter(
                "kindValue",
                as: (() async -> Int64).self,
                declaredAs: "() async -> Swift.Int64"
            )
        )
        #expect(try await unsafe genericKind.unsafeInvoke() == 89)
        // The opaque result descriptor is named by the member, not its thunk.
        let opaque = try await base.resolve(
            .method(
                "opaque()",
                as: (() -> NativeSwiftValue).self
            )
        )
        #expect(try unsafe opaque.unsafeInvoke(on: baseObject).withCopy { $0 as? Int64 } == 7)
        // Replacement publishes the captured entry. A redispatching thunk would
        // reach Derived's override of the replacement instead.
        let replacement = try await base.resolve(
            .method(
                "replacement(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        let plan = try unsafe derivedValue.prepareVirtualReplacementAndWait(with: replacement)
        let oracle = try await runtime.resolve(
            .function(
                module + ".value(" + base.name + ", Swift.Int64) -> Swift.Int64",
                as: ((AnyObject, Int64) -> Int64).self
            ),
            in: scope
        )
        try unsafe plan.install()
        defer { try? plan.restore() }
        #expect(try unsafe oracle.unsafeInvoke(derivedObject, 40) == 140)
        try plan.restore()
        #expect(try unsafe oracle.unsafeInvoke(derivedObject, 40) == 42)

        // A replacement from another image keeps the declaration's opaque
        // descriptor lookup in the declaring image.
        let patchModule = "ThunkPatch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let patch = try FixtureLibrary(
            swiftModule: patchModule,
            swiftSource: """
                open class Patch {
                    public init() {}
                    @inline(never) open func opaque() -> some Equatable { Int64(9) }
                }
                """,
            linkArguments: ["-O", "-enable-library-evolution"]
        )
        defer { patch.cleanup() }
        let patchType = try await runtime.resolveSwiftType(
            named: patchModule + ".Patch",
            in: .path(patch.libraryURL)
        )
        let patchOpaque = try await patchType.resolve(
            .method(
                "opaque()",
                as: (() -> NativeSwiftValue).self
            )
        )
        let opaquePlan = try unsafe opaque.prepareVirtualReplacementAndWait(with: patchOpaque)
        try unsafe opaquePlan.install()
        defer { try? opaquePlan.restore() }
        let replaced = try base.resolveAndWait(
            .method(
                "opaque()",
                as: (() -> NativeSwiftValue).self
            )
        )
        #expect(try unsafe replaced.unsafeInvoke(on: baseObject).withCopy { $0 as? Int64 } == 9)
        try opaquePlan.restore()

        // A hook's generated dispatcher has no image; a later lookup still captures it.
        let hook = try await unsafe derivedValue.hookVirtualCalls(onFailure: { _ in }) {
            call,
            input in
            try call.proceed(input) + 1000
        }
        defer { hook.invalidate() }
        let hooked = try derived.resolveAndWait(
            .method(
                "value(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        #expect(try unsafe hooked.unsafeInvoke(on: derivedObject, 40) == 1042)
    }
    #endif

    @MainActor @Test func extractedMethodsAndBindingsHaveIndependentReceiverLifetimes() async throws
    {
        let runtime = ABIRuntime()
        weak var observedOriginal: SwiftMemberRenderer?
        let render: NativeSwiftMethod<(Int) -> Int>
        let getter: NativeSwiftMethod<() -> String>
        let setter: NativeSwiftMethod<(String) -> Void>
        do {
            let original = SwiftMemberRenderer(text: "original")
            observedOriginal = original
            render = try await runtime.object(original).resolve(
                .method(
                    "render(_:)",
                    as: ((Int) -> Int).self
                )
            ).method
            getter = try await runtime.object(original).resolve(
                .getter(
                    "consumedText",
                    as: (() -> String).self,
                    receiver: .consuming
                )
            ).method
            setter = try await runtime.object(original).resolve(
                .setter(
                    "consumedText",
                    as: ((String) -> Void).self,
                    receiver: .consuming
                )
            ).method
        }
        runtime.removeCachedResults()
        #expect(observedOriginal == nil)
        var receiver: SwiftMemberRenderer? = SwiftMemberDerived(text: "second")
        weak let observedReceiver = receiver
        var bound: NativeBoundSwiftMethod<(Int) -> Int>? = try render.bind(to: receiver!)
        try unsafe setter.unsafeInvoke(on: receiver!, "ready")
        #expect(try unsafe getter.unsafeInvoke(on: receiver!) == "ready")
        #expect(try unsafe render.unsafeInvoke(on: receiver!, 37) == 42)
        receiver = nil
        #expect(observedReceiver != nil)
        #expect(try unsafe bound!.unsafeInvoke(37) == 42)
        bound = nil
        withExtendedLifetime((render, getter, setter)) { #expect(observedReceiver == nil) }
        let incompatible = try render.bind(to: NSObject())
        #expect(throws: ABIInvocationError.self) { try unsafe incompatible.unsafeInvoke(0) }
        let adaptedType = try await runtime.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberRenderer",
            as: AnyObject.self
        )
        let adapted = try await adaptedType.resolve(
            .method(
                "render(_:)",
                as: ((Int) -> Int).self
            )
        )
        let adaptedBinding = try adapted.bind(to: NSObject())
        #expect(throws: ABIInvocationError.self) { try unsafe adaptedBinding.unsafeInvoke(0) }
    }

    @MainActor @Test(arguments: [false, true])
    func privateReceiversKeepTheirDeclarationIdentity(_ second: Bool) async throws {
        let receiver = second ? makeSecondPrivateReceiver() : makeFirstPrivateReceiver()
        let runtime = ABIRuntime()
        let object = runtime.object(receiver)
        for member in ["title()", "title() -> Swift.String"] {
            let title = try await object.resolve(.method(member, as: (() -> String).self))
            #expect(try unsafe title.unsafeInvoke() == (second ? "22" : "11"))
        }
        let echo = try await object.resolve(.method("echo(_:)", as: ((Int) -> Int).self))
        #expect(try unsafe echo.unsafeInvoke(1) == (second ? 23 : 12))
        let inherited = try await object.resolve(.method("inherited()", as: (() -> Int).self))
        #expect(try unsafe inherited.unsafeInvoke() == (second ? 22 : 11))
        let getter = try await object.resolve(.getter("value", as: (() -> Int).self))
        let setter = try await object.resolve(.setter("value", as: ((Int) -> Void).self))
        runtime.removeCachedResults()
        try unsafe setter.unsafeInvoke(42)
        #expect(try unsafe getter.unsafeInvoke() == 42)
    }

    /// A signature that names a private type matches its declaration: as a
    /// closure's parameter, a result, a tuple element, and twice within a
    /// generic argument.
    @MainActor @Test func privateHostTypesMatchTheirDeclarations() async throws {
        let caller = SwiftPrivateMemberCaller()
        // Compiler calls keep the private methods and control their results.
        #expect(caller.apply { $0.x + $0.y } == 42)
        #expect(caller.sum([(caller.make(), caller.make()), nil], (caller.make(), 1)) == 84)
        let object = ABIRuntime().object(caller)
        typealias Callback = NativeSwiftClosure<(SwiftPrivateMemberPoint) -> Double>
        let apply = try await object.resolve(
            .method(
                "apply(_:)",
                as: ((Callback) -> Double).self
            )
        )
        #expect(try unsafe apply.unsafeInvoke(Callback { $0.x + $0.y }) == 42)
        let make = try await object.resolve(
            .method(
                "make()",
                as: (() -> SwiftPrivateMemberPoint).self
            )
        )
        typealias Pair = (SwiftPrivateMemberPoint, SwiftPrivateMemberPoint)
        let sum = try await object.resolve(
            .method(
                "sum(_:_:)",
                as: (([Pair?], (SwiftPrivateMemberPoint, Int)) -> Double).self
            )
        )
        let point = try unsafe make.unsafeInvoke()
        #expect(try unsafe sum.unsafeInvoke([(point, point), nil], (point, 1)) == 84)
    }

    /// A private generic argument matches wherever a container names it,
    /// including a tuple with an Objective-C superclass existential, which has
    /// no runtime mangled name.
    @Test func privateGenericArgumentsMatchInContainers() async throws {
        typealias Pair = (SwiftPrivateMemberPoint, any NSObject & NSCopying)
        let echo = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.echoGeneric(_:)",
                as: ((Pair) -> Pair).self,
                genericArguments: [.type(Pair.self)]
            )
        )
        let text = NSString(string: "copy")
        let pair = (SwiftPrivateMemberPoint(x: 40, y: 2), text)
        let result = try unsafe echo.unsafeInvoke(pair)
        #expect(result.0.x + result.0.y == 42 && result.1 === text)
        let count = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.countNSObjectCopyingPairs(_:)",
                as: (([Pair]) -> Int64).self,
                genericArguments: [.type(SwiftPrivateMemberPoint.self)]
            )
        )
        #expect(try unsafe count.unsafeInvoke([pair, pair]) == 2)
    }

    @MainActor @Test func missingMembersPreserveRequestedOwner() async throws {
        let runtime = ABIRuntime()
        let receiver = SwiftMemberLookupReceiver()
        let owner = "ABIBridgeTests.SwiftMemberLookupReceiver"
        let path = try #require(Bundle(for: SwiftMemberLookupReceiver.self).executableURL)
        let type = try await runtime.resolveSwiftType(
            named: owner,
            in: .path(path),
            loading: .loadedOnly
        )
        for operation in [
            "method", "getter", "setter", "staticMethod", "staticGetter", "staticSetter",
        ] {
            let expected: String
            switch operation {
            case "method": expected = owner + ".missing()"
            case "getter": expected = owner + ".missing.getter"
            case "setter": expected = owner + ".missing.setter"
            case "staticMethod": expected = "static " + owner + ".missing()"
            case "staticGetter": expected = "static " + owner + ".missing.getter"
            default: expected = "static " + owner + ".missing.setter"
            }
            await #expect(
                throws: ABIResolutionError.declarationNotFound(
                    NativeDeclaration(name: expected, language: .swift)
                )
            ) {
                switch operation {
                case "method":
                    _ = try await runtime.object(receiver).resolve(
                        .method(
                            "missing()",
                            as: (() -> Int).self
                        )
                    )
                case "getter":
                    _ = try await runtime.object(receiver).resolve(
                        .getter(
                            "missing",
                            as: (() -> Int).self
                        )
                    )
                case "setter":
                    _ = try await runtime.object(receiver).resolve(
                        .setter(
                            "missing",
                            as: ((Int) -> Void).self
                        )
                    )
                case "staticMethod":
                    _ = try await type.resolve(.staticMethod("missing()", as: (() -> Int).self))
                case "staticGetter":
                    _ = try await type.resolve(.staticGetter("missing", as: (() -> Int).self))
                default:
                    _ = try await type.resolve(.staticSetter("missing", as: ((Int) -> Void).self))
                }
            }
        }
    }

    @MainActor @Test func consumingAccessorsPreserveCallerReferencesAndValues() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let get = try await type.resolve(
            .getter(
                "consumedText",
                as: (() -> String).self,
                receiver: .consuming
            )
        )
        let set = try await type.resolve(
            .setter(
                "consumedText",
                as: ((String) -> Void).self,
                receiver: .consuming
            )
        )
        var value: SwiftMemberRenderer? = .init(text: String(repeating: "a", count: 100))
        weak let observed = value
        #expect(try unsafe get.unsafeInvoke(on: value!) == value?.text)
        try unsafe set.unsafeInvoke(on: value!, String(repeating: "b", count: 100))
        #expect(value?.text == String(repeating: "b", count: 100))
        var boundGet: NativeBoundSwiftMethod<() -> String>? = try await runtime.object(value!)
            .resolve(
                .getter(
                    "consumedText",
                    as: (() -> String).self,
                    receiver: .consuming
                )
            )
        var boundSet: NativeBoundSwiftMethod<(String) -> Void>? = try await runtime.object(value!)
            .resolve(
                .setter(
                    "consumedText",
                    as: ((String) -> Void).self,
                    receiver: .consuming
                )
            )
        value = nil
        try unsafe boundSet!.unsafeInvoke(String(repeating: "c", count: 100))
        #expect(try unsafe boundGet!.unsafeInvoke() == String(repeating: "c", count: 100))
        boundGet = nil
        #expect(observed != nil)
        boundSet = nil
        #expect(observed == nil)

        let pointType = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let getValue = try await pointType.resolve(
            .getter(
                "consumedValue",
                as: (() -> Int64).self,
                receiver: .consuming
            )
        )
        let setValue = try await pointType.resolve(
            .setter(
                "consumedValue",
                as: ((Int64) -> Void).self,
                receiver: .consuming
            )
        )
        var point = SwiftMemberPoint(value: 12)
        #expect(try unsafe getValue.unsafeInvoke(on: point) == 12)
        try unsafe setValue.unsafeInvoke(on: point, 7)
        #expect(SwiftMemberPoint.observedConsumedValue == 19 && point.value == 12)
        try unsafe setValue.unsafeInvoke(on: &point, 8)
        #expect(SwiftMemberPoint.observedConsumedValue == 20 && point.value == 12)
        SwiftMemberPoint.observedConsumedValue = 0
    }

    @MainActor @Test func consumingReceiversTransferAnIndependentCopy() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let consume = try await type.resolve(
            .method(
                "consumeText()",
                as: (() -> Int).self,
                receiver: .consuming
            )
        )
        let invalidResult = try await type.resolve(
            .method(
                "consumeReturningNil() -> Swift.Optional<Swift.UnsafeRawPointer>",
                as: (() -> UnsafeRawPointer).self,
                receiver: .consuming
            )
        )
        var value: SwiftMemberRenderer? = .init(text: String(repeating: "x", count: 100))
        weak let observed = value
        #expect(try unsafe consume.unsafeInvoke(on: value!) == 100)
        #expect(throws: ABIInvocationError.self) {
            try unsafe invalidResult.unsafeInvoke(on: value!)
        }
        #expect(value?.text.count == 100)
        let rawType = try await runtime.resolveSwiftType(
            named: type.name,
            as: UnsafeRawPointer.self,
            in: type.image
        )
        let rawConsume = try await rawType.resolve(
            .method(
                "consumeText()",
                as: (() -> Int).self,
                receiver: .consuming
            )
        )
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(value!).toOpaque())
        #expect(try unsafe rawConsume.unsafeInvoke(on: pointer) == 100)
        var bound: NativeBoundSwiftMethod<() -> Int>? = try await runtime.object(value!)
            .resolve(
                .method(
                    "consumeText()",
                    as: (() -> Int).self,
                    receiver: .consuming
                )
            )
        value = nil
        #expect(observed != nil)
        #expect(try unsafe bound!.unsafeInvoke() == 100)
        bound = nil
        #expect(observed == nil)

        let pointType = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let take = try await pointType.resolve(
            .method(
                "consumeValue()",
                as: (() -> Int64).self,
                receiver: .consuming
            )
        )
        let point = SwiftMemberPoint(value: 42)
        #expect(try unsafe take.unsafeInvoke(on: point) == 42 && point.value == 42)
        let largeType = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberLarge")
        let change = try await largeType.resolve(
            .method(
                "consumeAfterChanging(_:)",
                as: ((Int64) -> Int64).self,
                receiver: .consuming
            )
        )
        let large = SwiftMemberLarge(a: 1, b: 2, c: 3, d: 4, e: 5)
        #expect(try unsafe change.unsafeInvoke(on: large, 10) == 24 && large.a == 1)
    }

    @Test func throwingDeclarationsNeedEffectsAndInitializersCanBorrow() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let member = "typedFailure() throws(ABIBridgeTests.SwiftMemberFailure) -> Swift.Int"
        _ = try runtime.resolveAndWait(
            .init(name: type.name + "." + member, language: .swift),
            in: type.image
        )
        do {
            _ = try await type.resolve(.method(member, as: (() -> Int).self))
            Issue.record("Typed-throwing members need a throwing function metatype")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.expected == "ABIBridgeTests.SwiftMemberFailure")
        }
        do {
            _ = try await runtime.resolve(
                .function(
                    "ABIBridgeTests.swiftMemberTypedFailure() throws(ABIBridgeTests.SwiftMemberFailure) -> Swift.Int",
                    as: (() -> Int).self
                ),
                in: type.image
            )
            Issue.record("Typed-throwing free functions need a throwing function metatype")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.expected == "ABIBridgeTests.SwiftMemberFailure")
        }
        let initializer =
            "init(borrowedChild: __shared ABIBridgeTests.SwiftMemberRenderer) -> ABIBridgeTests.SwiftMemberRenderer"
        _ = try runtime.resolveAndWait(
            .init(name: type.name + ".__allocating_" + initializer, language: .swift),
            in: type.image
        )
        let make = try await type.resolve(
            .initializer(
                initializer,
                as: ((NativeSwiftBorrowing<SwiftMemberRenderer>) -> SwiftMemberRenderer).self
            )
        )
        let child = SwiftMemberRenderer(text: "borrowed")
        let parent = try unsafe make.unsafeInvoke(.init(child))
        #expect(parent.object === child && parent.text == "borrowed")
    }

    @Test func operatorsResolveByLabelsAndReportFixityAmbiguity() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPoint"
        )
        let greater = try await type.resolve(
            .staticMethod(
                ">(_:_:)",
                as: ((SwiftMemberPoint, SwiftMemberPoint) -> Bool).self
            )
        )
        #expect(try unsafe greater.unsafeInvoke(.init(value: 42), .init(value: 1)))
        do {
            _ = try await type.resolve(
                .staticMethod(
                    "~~~(_:)",
                    as: ((SwiftMemberPoint) -> SwiftMemberPoint).self
                )
            )
            Issue.record("Both prefix and postfix implementations match")
        } catch ABIResolutionError.ambiguousDeclaration {}
        let prefix = try await type.resolve(
            .staticMethod(
                "~~~ prefix(_:)",
                as: ((SwiftMemberPoint) -> SwiftMemberPoint).self
            )
        )
        let postfix = try await type.resolve(
            .staticMethod(
                "~~~ postfix(_:)",
                as: ((SwiftMemberPoint) -> SwiftMemberPoint).self
            )
        )
        #expect(try unsafe prefix.unsafeInvoke(.init(value: 10)).value == 11)
        #expect(try unsafe postfix.unsafeInvoke(.init(value: 10)).value == 9)
    }

    @Test func membersFromAnotherModulesExtensionResolveWithoutItsQualifier() async throws {
        let imported = try await ABIRuntime.shared.object(NSObject()).resolve(
            .method(
                "bridgeImportedExtension(_:)",
                as: ((Int) -> Int).self
            )
        )
        #expect(try unsafe imported.unsafeInvoke(41) == 42)
        let value = try NativeValue(copying: Int64(42), as: .int64)
        let object = ABIRuntime.shared.object(value)
        let method = try await object.resolve(
            .method(
                "bridgeExtensionCount(_:)",
                as: ((Int) -> Int).self
            )
        )
        #expect(try unsafe method.unsafeInvoke(2) == value.bridgeExtensionCount(2))
        let getter = try await object.resolve(
            .getter(
                "bridgeExtensionSize",
                as: (() -> Int).self
            )
        )
        #expect(try unsafe getter.unsafeInvoke() == value.type.size)
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "ABIBridge.NativeValue")
        let staticMethod = try await type.resolve(
            .staticMethod(
                "bridgeExtensionStatic(_:)",
                as: ((Int) -> Int).self
            )
        )
        #expect(try unsafe staticMethod.unsafeInvoke(41) == 42)
    }

    @Test func repeatedWritebackReleasesIntermediateValues() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPointer",
            as: SwiftPointerView.self
        )
        let advance = try await type.resolve(
            .method(
                "advance()",
                as: (() -> Void).self,
                receiver: .mutating
            )
        )
        weak var observed: SwiftPointerAllocation?
        do {
            var value: SwiftPointerView = {
                let allocation = SwiftPointerAllocation(count: 101)
                observed = allocation
                return SwiftPointerView(
                    nativeValue: NativeValue(type: .pointer, retaining: allocation) {
                        $0.baseAddress!.storeBytes(
                            of: allocation.pointer,
                            as: UnsafeMutablePointer<Int64>.self
                        )
                    }
                )
            }()
            var previous: [WeakNativeValue] = []
            for _ in 0..<100 {
                previous.append(WeakNativeValue(value.storage))
                try unsafe advance.unsafeInvoke(on: &value)
            }
            #expect(previous.allSatisfy { $0.value == nil })
            try #require(observed != nil)
            let pointer = try unsafe value.storage.read(as: UnsafeMutablePointer<Int64>.self)
            #expect(pointer.pointee == 1010)
        }
        #expect(observed == nil)
    }

    @Test func protocolExtensionReceiversPreserveExplicitAdapters() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPointer",
            as: SwiftPointerView.self
        )
        let read = try await type.resolve(
            .method(
                "(extension in ABIBridgeTests):ABIBridgeTests.SwiftMemberPointerProtocol.pointedValue() -> Swift.Int64",
                as: (() -> Int64).self
            )
        )
        let advance = try await type.resolve(
            .method(
                "(extension in ABIBridgeTests):ABIBridgeTests.SwiftMemberPointerProtocol.advancePointer() -> ()",
                as: (() -> Void).self,
                receiver: .mutating
            )
        )
        weak var observed: SwiftPointerAllocation?
        do {
            var value: SwiftPointerView = {
                let allocation = SwiftPointerAllocation()
                observed = allocation
                return SwiftPointerView(
                    nativeValue: NativeValue(type: .pointer, retaining: allocation) {
                        $0.baseAddress!.storeBytes(
                            of: allocation.pointer,
                            as: UnsafeMutablePointer<Int64>.self
                        )
                    }
                )
            }()
            #expect(try unsafe read.unsafeInvoke(on: value) == 10)
            try unsafe advance.unsafeInvoke(on: &value)
            #expect(try unsafe read.unsafeInvoke(on: value) == 20)
            #expect(observed != nil)
        }
        #expect(observed == nil)
    }

    @Test func writebackKeepsReceiverOwnedResourcesAlive() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPointer",
            as: SwiftPointerView.self
        )
        let advance = try await type.resolve(
            .method(
                "advance()",
                as: (() -> Void).self,
                receiver: .mutating
            )
        )
        weak var observed: SwiftPointerAllocation?
        do {
            var value: SwiftPointerView = {
                let allocation = SwiftPointerAllocation()
                observed = allocation
                return SwiftPointerView(
                    nativeValue: NativeValue(type: .pointer, retaining: allocation) {
                        $0.baseAddress!.storeBytes(
                            of: allocation.pointer,
                            as: UnsafeMutablePointer<Int64>.self
                        )
                    }
                )
            }()
            try unsafe advance.unsafeInvoke(on: &value)
            try #require(observed != nil)
            let pointer = try unsafe value.storage.read(as: UnsafeMutablePointer<Int64>.self)
            #expect(pointer.pointee == 20)
        }
        #expect(observed == nil)
    }

    @Test func largeValueReceiversUseIndirectSwiftContext() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberLarge"
        )
        let sum = try await type.resolve(.method("sum(_:)", as: ((Int64) -> Int64).self))
        let value = SwiftMemberLarge(a: 1, b: 2, c: 3, d: 4, e: 5)
        #expect(try unsafe sum.unsafeInvoke(on: value, 6) == value.sum(6))
    }

    @Test func resultAndWritebackFailuresRemainAvailable() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPoint",
            as: RejectingSwiftPoint.self
        )
        let change = try await type.resolve(
            .method(
                "changeReturningNil(Swift.Int64) -> Swift.Optional<Swift.UnsafeRawPointer>",
                as: ((Int64) -> UnsafeRawPointer).self,
                receiver: .mutating
            )
        )
        var value = RejectingSwiftPoint(1)
        do {
            _ = try unsafe change.unsafeInvoke(on: &value, 42)
            Issue.record("Expected conversion and writeback failures")
        } catch let error as NativeSwiftWritebackError {
            #expect(error.invocationError is ABIInvocationError)
            #expect(error.writebackError is SwiftWritebackRejection)
        }
    }

    @MainActor @Test func inheritedImplementationsResolveThroughTheirDeclaringClass() async throws {
        let object = SwiftMemberDerived(text: "derived")
        let method = try await ABIRuntime.shared.object(object).resolve(
            .method(
                "render(_:)",
                as: ((Int) -> Int).self
            )
        )
        #expect(try unsafe method.unsafeInvoke(5) == object.render(5))
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberDerived"
        )
        let getter = try await type.resolve(.getter("text", as: (() -> String).self))
        #expect(try unsafe getter.unsafeInvoke(on: object) == object.text)
    }

    @MainActor @Test func propertyAccessorsPreserveIncomingObjectOwnership() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberRenderer"
        )
        let text = try await type.resolve(.getter("text", as: (() -> String).self))
        let setText = try await type.resolve(.setter("text", as: ((String) -> Void).self))
        let object = SwiftMemberRenderer(text: "old")
        let bound = ABIRuntime.shared.object(object)
        let boundGet = try await bound.resolve(.getter("text", as: (() -> String).self))
        let boundSet = try await bound.resolve(.setter("text", as: ((String) -> Void).self))
        try unsafe boundSet.unsafeInvoke("bound")
        #expect(try unsafe boundGet.unsafeInvoke() == "bound")
        try unsafe setText.unsafeInvoke(on: object, String(repeating: "abc", count: 100))
        #expect(try unsafe text.unsafeInvoke(on: object) == String(repeating: "abc", count: 100))
        let setObject = try await type.resolve(
            .setter("object", as: ((SwiftMemberRenderer?) -> Void).self)
        )
        var child: SwiftMemberRenderer? = .init(text: "child")
        weak let observed = child
        try unsafe setObject.unsafeInvoke(on: object, child)
        child = nil
        #expect(observed != nil && object.object?.text == "child")
        try unsafe setObject.unsafeInvoke(on: object, nil)
        #expect(observed == nil)
        let standard = try await type.resolve(
            .staticGetter(
                "standard",
                as: (() -> String).self
            )
        )
        #expect(try unsafe standard.unsafeInvoke() == SwiftMemberRenderer.standard)
        let count = try await type.resolve(.staticGetter("count", as: (() -> Int).self))
        let setCount = try await type.resolve(.staticSetter("count", as: ((Int) -> Void).self))
        try unsafe setCount.unsafeInvoke(42)
        #expect(try unsafe count.unsafeInvoke() == SwiftMemberRenderer.count)
        SwiftMemberRenderer.count = 0
        let pointType = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPoint"
        )
        let value = try await pointType.resolve(.getter("value", as: (() -> Int64).self))
        let setValue = try await pointType.resolve(.setter("value", as: ((Int64) -> Void).self))
        var point = SwiftMemberPoint(value: 1)
        try unsafe setValue.unsafeInvoke(on: &point, 7)
        #expect(try unsafe value.unsafeInvoke(on: point) == 7)
    }

    @MainActor @Test func initializersAndStaticMethodsSupplyMetadataAndOwnership() throws {
        let rendererType = try ABIRuntime.shared.resolveSwiftTypeAndWait(
            named: "ABIBridgeTests.SwiftMemberRenderer"
        )
        let initialize = try rendererType.resolveAndWait(
            .initializer(
                "init(text:)",
                as: ((String) -> SwiftMemberRenderer).self
            )
        )
        var renderer: SwiftMemberRenderer? = try unsafe initialize.unsafeInvoke(
            String(repeating: "ab", count: 100)
        )
        weak let observed = renderer
        #expect(renderer?.text == String(repeating: "ab", count: 100))
        renderer = nil
        #expect(observed == nil)
        let withChild = try rendererType.resolveAndWait(
            .initializer(
                "init(child:)",
                as: ((SwiftMemberRenderer) -> SwiftMemberRenderer).self
            )
        )
        var child: SwiftMemberRenderer? = .init(text: "child")
        weak let childReference = child
        var parent: SwiftMemberRenderer? = try unsafe withChild.unsafeInvoke(child!)
        child = nil
        #expect(parent?.object === childReference && childReference != nil)
        parent = nil
        #expect(childReference == nil)
        let failable = try rendererType.resolveAndWait(
            .initializer(
                "init(nonemptyText:)",
                as: ((String) -> SwiftMemberRenderer?).self
            )
        )
        #expect(try unsafe failable.unsafeInvoke("") == nil)
        #expect(try unsafe failable.unsafeInvoke("ok")?.text == "ok")
        let staticMethod = try rendererType.resolveAndWait(
            .staticMethod(
                "decorate(_:)",
                as: ((String) -> String).self
            )
        )
        #expect(
            try unsafe staticMethod.unsafeInvoke("hello") == SwiftMemberRenderer.decorate("hello")
        )
        let pointType = try ABIRuntime.shared.resolveSwiftTypeAndWait(
            named: "ABIBridgeTests.SwiftMemberPoint"
        )
        let pointInitializer = try pointType.resolveAndWait(
            .initializer(
                "init(value:)",
                as: ((Int64) -> SwiftMemberPoint).self
            )
        )
        #expect(try unsafe pointInitializer.unsafeInvoke(42).value == 42)
    }

    @Test func completeMemberNamesRejectHostTypesWithAnotherLowering() throws {
        let type = try ABIRuntime.shared.resolveSwiftTypeAndWait(
            named: "ABIBridgeTests.SwiftMemberRenderer"
        )
        do {
            _ = try type.resolveAndWait(
                .staticMethod(
                    "answer() -> Swift.Int32",
                    as: (() -> Double).self
                )
            )
            Issue.record("A Double result was accepted for Swift.Int32")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .result)
        }
        do {
            _ = try type.resolveAndWait(
                .method(
                    "render(Swift.Int) -> Swift.Int",
                    as: ((Double) -> Int).self
                )
            )
            Issue.record("A Double argument was accepted for Swift.Int")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .argument(0))
        }
        let answer = try type.resolveAndWait(
            .staticMethod(
                "answer() -> Swift.Int32",
                as: (() -> UInt32).self
            )
        )
        #expect(try unsafe answer.unsafeInvoke() == 42)
    }

    @Test func receiverRepresentationsMustPassAsSelf() throws {
        let type = try ABIRuntime.shared.resolveSwiftTypeAndWait(
            named: "ABIBridgeTests.SwiftMemberPoint",
            as: Double.self
        )
        do {
            _ = try type.resolveAndWait(.method("read(_:)", as: ((Int64) -> Int64).self))
            Issue.record("A Double representation was accepted for an Int64 receiver")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .receiver)
        }
    }

    @MainActor @Test func boundSwiftMethodsRetainTheirReceiver() throws {
        var object: SwiftMemberRenderer? = .init(text: "abc")
        weak let observed = object
        var method: NativeBoundSwiftMethod<(Int) -> Int>? = try ABIRuntime.shared.object(object!)
            .resolveAndWait(
                .method(
                    "render(_:)",
                    as: ((Int) -> Int).self
                )
            )
        object = nil
        #expect(observed != nil)
        #expect(try unsafe method!.unsafeInvoke(5) == 8)
        method = nil
        #expect(observed == nil)
    }

    @MainActor @Test func classMembersUseTheBoundClassContext() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberRenderer"
        )
        let render = try await type.resolve(.method("render(_:)", as: ((Int) -> Int).self))
        let object = SwiftMemberRenderer(text: "abc")
        #expect(try unsafe render.unsafeInvoke(on: object, 5) == object.render(5))
        #expect(throws: ABIInvocationError.self) { try unsafe render.unsafeInvoke(on: 1, 5) }
    }

    @Test func valueAndEnumMembersUseTheirSwiftReceiverLayouts() async throws {
        let runtime = ABIRuntime()
        let point = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let read = try await point.resolve(.method("read(_:)", as: ((Int64) -> Int64).self))
        var value = SwiftMemberPoint(value: 10)
        #expect(try unsafe read.unsafeInvoke(on: value, 5) == value.read(5))
        let change = try await point.resolve(
            .method(
                "change(_:)",
                as: ((Int64) -> Void).self,
                receiver: .mutating
            )
        )
        #expect(throws: ABIResolutionError.self) { try unsafe change.unsafeInvoke(on: value, 42) }
        try unsafe change.unsafeInvoke(on: &value, 42)
        #expect(value.value == 42)
        let mode = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberMode")
        let modeRead = try await mode.resolve(.method("read(_:)", as: ((Int) -> Int).self))
        #expect(
            try unsafe modeRead.unsafeInvoke(on: SwiftMemberMode.second, 7)
                == SwiftMemberMode.second.read(7)
        )
    }

    @Test func valueMutationSurvivesAResultConversionFailure() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ABIBridgeTests.SwiftMemberPoint"
        )
        let change = try await type.resolve(
            .method(
                "changeReturningNil(Swift.Int64) -> Swift.Optional<Swift.UnsafeRawPointer>",
                as: ((Int64) -> UnsafeRawPointer).self,
                receiver: .mutating
            )
        )
        var value = SwiftMemberPoint(value: 1)
        #expect(throws: ABIInvocationError.self) { try unsafe change.unsafeInvoke(on: &value, 42) }
        #expect(value.value == 42)
    }

    @Test func nominalMetadataIsCachedAndSurvivesCacheRemoval() async throws {
        let runtime = ABIRuntime()
        let known: [Any.Type] = [
            SwiftMemberRenderer.self, SwiftMemberPoint.self, SwiftMemberMode.self,
        ]
        for expected in known {
            let qualified = String(reflecting: expected)
            let first = try await runtime.resolveSwiftType(named: qualified)
            let second = try await runtime.resolveSwiftType(named: qualified, in: first.image)
            #expect(first === second)
            #expect(first.name == qualified)
            runtime.removeCachedResults()
            let next = try await runtime.resolveSwiftType(named: qualified, in: first.image)
            #expect(next !== first && next.image == first.image)
        }
    }

    @Test func missingGenericArgumentsFailBeforeCallingTheAccessor() async throws {
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.resolveSwiftTypeAndWait(
                named: "ABIBridgeTests.SwiftMemberGeneric"
            )
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.resolveSwiftTypeAndWait(
                named: "ABIBridgeTests.MissingSwiftType"
            )
        }
    }
}
