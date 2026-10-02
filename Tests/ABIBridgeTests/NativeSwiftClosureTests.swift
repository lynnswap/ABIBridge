#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import CoreGraphics
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class ClosureCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureCapture: Sendable {
    let destroyed: ClosureCounter
    let bias: Int64
    init(_ destroyed: ClosureCounter, bias: Int64 = 7) { self.destroyed = destroyed; self.bias = bias }
    deinit { destroyed.increment() }
}

private enum ClosureConversionError: Error { case rejected }
private struct RejectingClosureArgument: ABIBridgeValue {
    static let abiType = NativeType.int64
    init() {}
    init(nativeValue: NativeValue) throws { throw ClosureConversionError.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw ClosureConversionError.rejected }
}

private final class ReentrantClosureCapture: Sendable {
    let destroyed: ClosureCounter
    init(_ destroyed: ClosureCounter) { self.destroyed = destroyed }
    deinit {
        do {
            let callback = try NativeSwiftClosure { Int64(42) }
            #expect(try unsafe callback.unsafeInvoke() == 42)
        } catch { Issue.record(error) }
        destroyed.increment()
    }
}

struct NativeSwiftClosureTests {
    @Test func sendableNonescapingSignaturePreservesItsTypedBody() throws {
        let result = try unsafe NativeSwiftClosure<@Sendable (Int64) -> Int64>.withUnsafeNonescaping({ $0 + 7 }) {
            try unsafe $0.unsafeInvoke(35)
        }
        #expect(result == 42)
    }

    @Test func callbackPageReuseReleasesCapturesAndPermitsDestructionReentry() throws {
        let destroyed = ClosureCounter()
        for expected in 1...128 {
            do {
                let capture = ReentrantClosureCapture(destroyed)
                let callback = try NativeSwiftClosure { [capture] in
                    withExtendedLifetime(capture) { Int64(42) }
                }
                #expect(try unsafe callback.unsafeInvoke() == 42)
            }
            #expect(destroyed.count == expected)
        }
    }

    @Test func callbacksAcrossMultiplePagesKeepIndependentContexts() throws {
        let destroyed = ClosureCounter()
        var callbacks: [NativeSwiftClosure<(Int64) -> Int64>] = []
        for index in 0..<1100 {
            let capture = ClosureCapture(destroyed, bias: Int64(index))
            callbacks.append(try NativeSwiftClosure { (value: Int64) in value + capture.bias })
        }
        for index in callbacks.indices {
            #expect(try unsafe callbacks[index].unsafeInvoke(1) == Int64(index + 1))
        }
        callbacks.removeFirst(1000)
        #expect(destroyed.count == 1000)
        for index in callbacks.indices {
            #expect(try unsafe callbacks[index].unsafeInvoke(2) == Int64(index + 1002))
        }
        callbacks.removeAll()
        #expect(destroyed.count == 1100)
        let next = try NativeSwiftClosure { Int64(7) }
        #expect(try unsafe next.unsafeInvoke() == 7)
    }

    @Test func concurrentCallbackCreationAndReleaseKeepBodiesIndependent() async throws {
        let total = try await withThrowingTaskGroup(of: Int64.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var sum: Int64 = 0
                    for index in 0..<128 {
                        let value = Int64(worker * 128 + index)
                        let callback = try NativeSwiftClosure { value }
                        sum += try unsafe callback.unsafeInvoke()
                    }
                    return sum
                }
            }
            var total: Int64 = 0
            for try await value in group { total += value }
            return total
        }
        #expect(total == 1023 * 1024 / 2)
    }

    @Test func sendableNativeCallersCanInvokeOneContextConcurrently() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyConcurrentClosure(_:)",
            as: ((NativeSwiftClosure<@Sendable (Int64) -> Int64>) -> Int64).self
        )
        let calls = ClosureCounter()
        let callback = try NativeSwiftClosure<@Sendable (Int64) -> Int64> { value in calls.increment(); return value + 7 }
        #expect(try unsafe apply.unsafeInvoke(callback) == 2464)
        #expect(calls.count == 64)
    }

    @Test func builtInRepresentationsRoundTripThroughGeneratedEntries() throws {
        func check<Value: Equatable>(_ value: Value) throws {
            let callback = try NativeSwiftClosure<(Value) -> Value> { $0 }
            #expect(try unsafe callback.unsafeInvoke(value) == value)
        }
        try check(true); try check(false)
        try check(Int8(-7)); try check(UInt8(250))
        try check(Int16(-300)); try check(UInt16(60_000))
        try check(Int32(-70_000)); try check(UInt32(4_000_000_000))
        try check(Int64(-5_000_000_000)); try check(UInt64.max)
        try check(Int(-42)); try check(UInt(42))
        try check(Float(1.25)); try check(Double(2.5)); try check(CGFloat(3.75))
        try check(String(repeating: "value", count: 100))
        try check(CGPoint(x: 1, y: 2)); try check(CGSize(width: 3, height: 4))
        try check(CGRect(x: 1, y: 2, width: 3, height: 4)); try check(NSRange(location: 5, length: 6))
        try check(NSSelectorFromString("description"))
        var number: Int64 = 42
        try withUnsafeMutablePointer(to: &number) { pointer in
            try check(pointer); try check(UnsafePointer(pointer))
            try check(UnsafeRawPointer(pointer)); try check(UnsafeMutableRawPointer(pointer))
            try check(OpaquePointer(pointer)); try check(Optional(pointer))
        }
        try check(UnsafeRawPointer?.none)
    }

#if DEBUG && os(macOS)
    @Test func builtInAuthenticationMatchesNativeCompilerCalls() throws {
        let cases: [(Any.Type, String)] = [
            (Bool.self, "Bool"), (Int8.self, "Int8"), (UInt8.self, "UInt8"),
            (Int16.self, "Int16"), (UInt16.self, "UInt16"),
            (Int32.self, "Int32"), (UInt32.self, "UInt32"),
            (Int64.self, "Int64"), (UInt64.self, "UInt64"),
            (Int.self, "Int"), (UInt.self, "UInt"),
            (Float.self, "Float"), (Double.self, "Double"), (CGFloat.self, "CGFloat"),
            (String.self, "String"), (AnyObject.self, "AnyObject"),
            (NSObject?.self, "NSObject?"), (Selector.self, "Selector"),
            (CGPoint.self, "CGPoint"), (CGSize.self, "CGSize"), (CGRect.self, "CGRect"),
            (NSRange.self, "NSRange"), (UnsafeRawPointer.self, "UnsafeRawPointer"),
            (UnsafeMutableRawPointer?.self, "UnsafeMutableRawPointer?"),
            (UnsafePointer<Int64>.self, "UnsafePointer<Int64>"),
            (UnsafeMutablePointer<UInt8>?.self, "UnsafeMutablePointer<UInt8>?"),
            (OpaquePointer?.self, "OpaquePointer?"),
            ([String].self, "[String]"), ([Int].self, "[Int]"),
            ([[String?]].self, "[[String?]]"), ([String]?.self, "[String]?"),
            (String?.self, "String?")
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let source = directory.appendingPathComponent("Closures.swift")
        let ir = directory.appendingPathComponent("Closures.ll")
        let declarations = cases.enumerated().map { index, entry in
            "@inline(never) public func closureProbe\(index)(_ callback: (\(entry.1)) -> \(entry.1), _ value: \(entry.1)) -> \(entry.1) { callback(value) }"
        }.joined(separator: "\n")
        try ("import Foundation\nimport CoreGraphics\n" + declarations).write(to: source, atomically: true, encoding: .utf8)
        func run(_ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            // The test runner's injected Xcode frameworks belong to its process,
            // not to the xcrun-selected compiler and SDK tools.
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("DYLD_") && $0.key != "SDKROOT"
            }
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ClosureCompilerProbe", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: text])
            }
            return text
        }
        let sdk = try run(["--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
                     "-target", "arm64e-apple-ios18.4", "-sdk", sdk, "-emit-ir",
                     source.path, "-o", ir.path])
        let text = try String(contentsOf: ir, encoding: .utf8)
        for (index, entry) in cases.enumerated() {
            let pattern = #"(?ms)^define[^\n]*closureProbe"# + String(index) + #"[y_][^\n]*\{(.*?)^\}"#
            let expression = try NSRegularExpression(pattern: pattern)
            let match = try #require(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let range = try #require(Range(match.range(at: 1), in: text))
            let body = String(text[range])
            let call = try #require(body.split(separator: "\n").first { $0.contains("call swiftcc") && $0.contains("swiftself") && $0.contains(#""ptrauth""#) })
            let discriminator = try NSRegularExpression(pattern: #""ptrauth"\(i32 0, i64 ([0-9]+)\)"#)
            let line = String(call)
            let auth = try #require(discriminator.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
            let digits = try #require(Range(auth.range(at: 1), in: line))
            let expected = try #require(UInt16(line[digits]))
            let name = try swiftClosureAuthType(entry.0)
            #expect(swiftClosureDiscriminator(parameters: [name], result: name) == expected, "\(entry.1)")
        }
    }
#endif

    @Test func preservesManagedResultsAndFloatingAggregates() async throws {
        let runtime = ABIRuntime.shared
        let apply = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyStringClosure(_:_:)",
            as: ((NativeSwiftClosure<(String) -> String>, String) -> String).self
        )
        let suffix = String(repeating: "!", count: 100)
        let callback = try NativeSwiftClosure { (value: String) in value + suffix }
        let input = String(repeating: "managed", count: 100)
        #expect(try unsafe apply.unsafeInvoke(callback, input) == input + suffix)
        let make = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeStringClosure(_:)",
            as: ((String) -> NativeSwiftClosure<(String) -> String>).self
        )
        let returned = try unsafe make.unsafeInvoke(input)
        #expect(try unsafe returned.unsafeInvoke(suffix) == input + suffix)

        let applyObject = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyOptionalObjectClosure(_:_:)",
            as: ((NativeSwiftClosure<(LifetimeToken?) -> LifetimeToken?>, LifetimeToken?) -> LifetimeToken?).self
        )
        let identity = try NativeSwiftClosure { (value: LifetimeToken?) in value }
        let token = LifetimeToken()
        #expect(try unsafe applyObject.unsafeInvoke(identity, token) === token)
        #expect(try unsafe applyObject.unsafeInvoke(identity, nil) == nil)

        let applyRect = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyRectClosure(_:_:)",
            as: ((NativeSwiftClosure<(CGRect) -> CGRect>, CGRect) -> CGRect).self
        )
        let translate = try NativeSwiftClosure { (value: CGRect) in value.offsetBy(dx: 3, dy: 4) }
        let rectangle = CGRect(x: 1, y: 2, width: 5, height: 6)
        #expect(try unsafe applyRect.unsafeInvoke(translate, rectangle) == rectangle.offsetBy(dx: 3, dy: 4))
    }

    @Test func laterArgumentFailureReleasesTheEncodedClosureReference() async throws {
        let runtime = ABIRuntime.shared
        let prototype = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let apply = try await runtime.swiftFunction(
            named: prototype.symbol.declaration.name,
            as: ((NativeSwiftClosure<(Int64) -> Int64>, RejectingClosureArgument) -> Int64).self
        )
        let destroyed = ClosureCounter(), calls = ClosureCounter()
        weak var observed: ClosureCapture?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in calls.increment(); return value + capture.bias }
            #expect(throws: ClosureConversionError.self) {
                try unsafe apply.unsafeInvoke(callback, RejectingClosureArgument())
            }
        }
        #expect(calls.count == 0)
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func explicitEmptyTupleMatchesTheCompiledCallback() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyEmptyTupleClosure(_:)",
            as: ((NativeSwiftClosure<(Void) -> Int64>) -> Int64).self
        )
        let callback = try NativeSwiftClosure<(Void) -> Int64> { _ in 42 }
        #expect(try unsafe apply.unsafeInvoke(callback) == 42)
        #expect(try unsafe callback.unsafeInvoke(()) == 42)
    }

    @Test func incomingNonescapingHooksRequireAScopedClosureRepresentation() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        await #expect(throws: ABIResolutionError.unsupportedDeclaration(
            "Incoming Swift closure hook arguments require a scoped nonescaping representation."
        )) {
            try await unsafe function.hookImportedCalls(in: .automatic, onFailure: { _ in }) { _, _, value in value }
        }
    }

    @Test func rejectsFallibleCustomConversionsBeforePublishingACallback() {
        #expect(throws: ABIResolutionError.self) {
            try NativeSwiftClosure { (value: RejectingClosureArgument) in Int64(42) }
        }
    }

    @Test func passesConcreteCallbackToNonescapingNativeParameter() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
        #expect(try unsafe apply.unsafeInvoke(callback, 35) == 42)
        #expect(try unsafe callback.unsafeInvoke(35) == 42)
    }

    @Test func closureResultsDoNotRetainUncapturedReceivers() async throws {
        let type = try await ABIRuntime.shared.swiftType(
            named: "ManagedSwiftFixtures.ClosurePropertyOwner", as: ClosurePropertyOwner.self
        )
        let getter = try await type.getter(named: "callback", as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self)
        let method = try await type.method(named: "readCallback()", as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self)
        let setter = try await type.setter(named: "callback", as: NativeSwiftClosure<(Int64) -> Int64>.self)
        for throughMethod in [false, true] {
            weak var observed: ClosurePropertyOwner?
            var returned: NativeSwiftClosure<(Int64) -> Int64>?
            do {
                let receiver = ClosurePropertyOwner()
                observed = receiver
                returned = try unsafe throughMethod ? method.unsafeInvoke(on: receiver) : getter.unsafeInvoke(on: receiver)
                let callback = try #require(returned)
                try unsafe setter.unsafeInvoke(on: receiver, callback)
                #expect(receiver.callback(35) == 42)
            }
            #expect(observed == nil)
            do {
                let callback = try #require(returned)
                #expect(try unsafe callback.unsafeInvoke(35) == 42)
            }
            returned = nil
        }
    }

    @Test func initializersTransferClosuresAndMethodsBorrowThem() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.StoredIntegerClosure",
                                               as: StoredIntegerClosure.self)
        let create = try await type.initializer(
            named: "init(_:)", as: ((NativeSwiftClosure<(Int64) -> Int64>) -> StoredIntegerClosure).self
        )
        let apply = try await type.method(
            named: "apply(_:_:)", as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        var receiver: StoredIntegerClosure?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            receiver = try unsafe create.unsafeInvoke(callback)
        }
        do {
            let object = try #require(receiver)
            let doubling = try NativeSwiftClosure { (value: Int64) in value * 2 }
            #expect(try unsafe apply.unsafeInvoke(on: object, doubling, 35) == 84)
            #expect(observed != nil)
        }
        receiver = nil
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func escapingNativeCallbackOwnsCapturesAndEntryCode() async throws {
        let retain = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.retainIntegerClosure(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> StoredIntegerClosure).self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        var native: StoredIntegerClosure?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            native = try unsafe retain.unsafeInvoke(callback)
        }
        withExtendedLifetime(native) {
            #expect(observed != nil)
            #expect(destroyed.count == 0)
        }
        #expect(native!(35) == 42)
        native = nil
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func repeatedNativeHandoffsPreserveOneOwningEntry() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.echoClosure(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            var callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            for _ in 0..<10_000 { callback = try unsafe echo.unsafeInvoke(callback) }
            #expect(try unsafe callback.unsafeInvoke(35) == 42)
        }
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func noncapturingNativeResultAllowsANilContext() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeNoncapturingClosure()",
            as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        let callback = try unsafe make.unsafeInvoke()
        #expect(try unsafe callback.unsafeInvoke(21) == 42)
    }

    @Test func returnedNativeClosureOwnsItsCaptureContext() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeIntegerClosure(_:_:)",
            as: ((LifetimeToken, Int64) -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        var callback: NativeSwiftClosure<(Int64) -> Int64>?
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            callback = try unsafe make.unsafeInvoke(token, 7)
        }
        do {
            let value = try #require(callback)
            #expect(observed != nil)
            #expect(try unsafe value.unsafeInvoke(35) == 42)
        }
        callback = nil
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func handlesZeroArgumentsVoidAndStackArguments() throws {
        let calls = ClosureCounter()
        let empty = try NativeSwiftClosure<() -> Void> { calls.increment() }
        try unsafe empty.unsafeInvoke()
        #expect(calls.count == 1)
        let many = try NativeSwiftClosure {
            (a: Int64, b: Int64, c: Int64, d: Int64, e: Int64, f: Int64,
             g: Int64, h: Int64, i: Int64, j: Int64, k: Int64, l: Int64) -> Int64 in
            let first = a + b + c + d + e + f
            return first + g + h + i + j + k + l
        }
        #expect(try unsafe many.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) == 78)
    }

#if DEBUG
    @Test func cachedInterfacesPreserveIndirectionErrorsAndLiveHandlesAfterEviction() throws {
        let word = try CValueType(scalar: ABIValueInt64)
        let direct = try SwiftCallInterface.cached(result: word, parameters: [word])
        let indirect = try CValueType(indirectSwiftSize: 8, alignment: 8)
        #expect(try SwiftCallInterface.cached(result: indirect, parameters: [word]) !== direct)
        #expect(try SwiftCallInterface.cached(result: word, parameters: [indirect]) !== direct)
        let typed = try SwiftCallInterface.cached(result: word, parameters: [word],
                                                  errorPlan: SwiftErrorPlan.make(ScalarFailure.self))
        let untyped = try SwiftCallInterface.cached(result: word, parameters: [word],
                                                    errorPlan: SwiftErrorPlan.make((any Error).self))
        #expect(typed !== untyped && typed !== direct && untyped !== direct)
        let callback = try NativeSwiftClosure { (value: Int64) in value + 1 }
        for size in 1...80 {
            _ = try SwiftCallInterface.cached(result: CValueType(indirectSwiftSize: size, alignment: 1), parameters: [])
        }
        #expect(try unsafe callback.unsafeInvoke(41) == 42)
        let repeated = try NativeSwiftClosure { (value: Int64) in value + 2 }
        #expect(try unsafe repeated.unsafeInvoke(40) == 42)
    }

    @Test func closureDiscriminatorsMatchCompilerEvidence() throws {
        #expect(swiftClosureDiscriminator(parameters: [try swiftClosureAuthType(Int64.self)],
                                          result: try swiftClosureAuthType(Int64.self)) == 21761)
        #expect(swiftClosureDiscriminator(parameters: ["-indirect"], result: "-indirect") == 55683)
        #expect(try swiftClosureAuthType(LifetimeToken.self) == swiftClosureAuthType(LifetimeToken?.self))
        #expect(try swiftClosureAuthType(UnsafePointer<Int64>.self) == swiftClosureAuthType(UnsafePointer<UInt8>.self))
    }

    @Test func failedReturnedClosurePreparationReleasesOwnedContext() throws {
        let codec = try NativeSwiftClosure<(Int64) -> Int64>.makeClosureCodec()
        let destroyed = ClosureCounter()
        let context = Unmanaged.passRetained(ClosureCapture(destroyed)).toOpaque()
        #expect(throws: ABIInvocationError.self) {
            _ = try codec.makeValue(ABISwiftClosureValue(function: nil, context: context), nil, true)
        }
        #expect(destroyed.count == 1)
    }
#endif
}
