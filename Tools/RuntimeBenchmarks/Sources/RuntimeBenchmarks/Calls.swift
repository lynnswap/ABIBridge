import ABIBridge
import BenchmarkNativeCalls
import BenchmarkNativeProvider
import BenchmarkSwiftProvider
import Foundation

func seconds(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}
@MainActor func measure(
    _ label: String,
    n: Int = 50000,
    delta: Int64 = 7,
    _ body: (Int64) throws -> Int64
) rethrows {
    let expected = (0..<n).reduce(Int64(0)) { $0 + Int64($1 & 1023) + delta }
    var checksum: Int64 = 0
    for i in 0..<min(n, 2000) { checksum &+= try body(Int64(i & 1023)) }
    var values: [Double] = []
    for _ in 0..<5 {
        checksum = 0
        let start = ContinuousClock.now
        for i in 0..<n { checksum &+= try body(Int64(i & 1023)) }
        values.append(seconds(start.duration(to: .now)) * 1e6 / Double(n))
        precondition(checksum == expected, "Incorrect result in " + label)
    }
    values.sort()
    print("\(label): \(values[2]) us/call checksum=\(checksum)")
}
struct Benchmark {
    @MainActor static func runPreparation() async throws {
        let object = ABIRuntime().object(PreparationBox("value"))
        let name = "add(Swift.Int64) -> Swift.Int64"
        let firstStart = ContinuousClock.now
        let first = try object.resolveMethodAndWait(named: name, as: ((Int64) -> Int64).self)
        let firstValue = try unsafe first.unsafeInvoke(35)
        precondition(firstValue == 42)
        print(
            "Swift generic member first preparation: \(seconds(firstStart.duration(to: .now))*1000) ms"
        )
        let count = 1000
        var samples: [Double] = []
        for _ in 0..<5 {
            var checksum: Int64 = 0
            let start = ContinuousClock.now
            for value in 0..<count {
                let method = try object.resolveMethodAndWait(
                    named: name,
                    as: ((Int64) -> Int64).self
                )
                checksum += try unsafe method.unsafeInvoke(Int64(value))
            }
            samples.append(seconds(start.duration(to: .now)) * 1e6 / Double(count))
            precondition(checksum == Int64(count * (count - 1) / 2 + count * 7))
        }
        samples.sort()
        print(
            "Swift generic member warm preparation: \(samples[2]) us/call (median of 5 x \(count))"
        )
    }

    @MainActor static func run(iterations: Int = 50000) async throws {
        ABIPerfRunNative()
        let runtime = ABIRuntime()
        let source = ImageSelector.automatic
        let start = ContinuousClock.now
        let regular = try await runtime.resolveSwiftFunction(
            named: "BenchmarkSwiftProvider.add(_:_:)",
            as: ((Int64, Int64) -> Int64).self,
            in: source
        )
        print("Swift regular first preparation: \(seconds(start.duration(to:.now))*1000) ms")
        let genericStart = ContinuousClock.now
        let generic = try await runtime.resolveSwiftFunction(
            named: "BenchmarkSwiftProvider.identity(_:)",
            as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)],
            in: source
        )
        print("Swift generic first preparation: \(seconds(genericStart.duration(to:.now))*1000) ms")
        let constrainedStart = ContinuousClock.now
        let constrained = try await runtime.resolveSwiftFunction(
            named: "BenchmarkSwiftProvider.hashEcho(_:)",
            as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)],
            in: source
        )
        print(
            "Swift Hashable first preparation: \(seconds(constrainedStart.duration(to:.now))*1000) ms"
        )
        measure("Swift direct", n: iterations) { BenchmarkSwiftProvider.add($0, 7) }
        try measure("Swift prepared regular", n: iterations) {
            try unsafe regular.unsafeInvoke($0, 7)
        }
        measure("Swift direct Hashable generic", n: iterations, delta: 0) {
            BenchmarkSwiftProvider.hashEcho($0)
        }
        measure("Swift direct callback", n: iterations, delta: 1) {
            BenchmarkSwiftProvider.apply({ $0 + 1 }, $0)
        }
        measure("Swift direct generic", n: iterations, delta: 0) {
            BenchmarkSwiftProvider.identity($0)
        }
        try measure("Swift prepared generic", n: iterations, delta: 0) {
            try unsafe generic.unsafeInvoke($0)
        }
        try measure("Swift prepared Hashable generic", n: iterations, delta: 0) {
            try unsafe constrained.unsafeInvoke($0)
        }
        let c = try runtime.resolveCFunctionAndWait(
            named: "ABIPerfCAdd",
            as: ((Int32, Int32) -> Int32).self
        )
        let cpp = try runtime.resolveCXXFunctionAndWait(
            named: "ABIPerf::add(int, int)",
            as: ((Int32, Int32) -> Int32).self
        )
        let pointer = try runtime.resolveCFunctionAndWait(
            named: "ABIPerfRead",
            as: ((UnsafePointer<Int64>) -> Int64).self
        )
        let dynamic = try runtime.resolveCFunctionAndWait(
            named: "ABIPerfCAdd",
            signature: .init(parameters: [.int32, .int32], returns: .int32)
        )
        try measure("Swift frontend C", n: iterations) {
            Int64(try unsafe c.unsafeInvoke(Int32($0), 7))
        }
        try measure("Swift frontend C++", n: iterations) {
            Int64(try unsafe cpp.unsafeInvoke(Int32($0), 7))
        }
        measure("C direct pointer", n: iterations) { value in
            withUnsafePointer(to: value) { ABIPerfRead($0) }
        }
        try measure("Swift frontend C pointer", n: iterations) { value in
            try withUnsafePointer(to: value) { try unsafe pointer.unsafeInvoke($0) }
        }
        let left = NativeValue(type: .int32) { _ in }
        let right = try NativeValue(copying: Int32(7), as: .int32)
        let dynamicArguments = [left, right]
        try measure("Swift frontend runtime C", n: iterations) { value in
            unsafe left.withUnsafeMutableBytes {
                $0.baseAddress!.storeBytes(of: Int32(value), as: Int32.self)
            }
            return Int64(
                try unsafe dynamic.unsafeInvoke(with: dynamicArguments).read(as: Int32.self)
            )
        }
        let receiver = ABIPerfReceiver()
        let objc = try runtime.object(receiver).resolveMethodAndWait(
            selector: "add:right:",
            as: ((Int64, Int64) -> Int64).self
        )
        let captured = try runtime.resolveObjCImplementationAndWait(
            on: ABIPerfReceiver.self,
            selector: "add:right:",
            as: ((Int64, Int64) -> Int64).self
        )
        try measure("Swift frontend ObjC message", n: iterations) {
            try unsafe objc.unsafeInvoke($0, 7)
        }
        try measure("Swift frontend captured ObjC IMP", n: iterations) {
            try unsafe captured.unsafeInvoke(on: receiver, $0, 7)
        }
        let size = try runtime.resolveObjCImplementationAndWait(
            on: ABIPerfReceiver.self,
            selector: "shiftSize:",
            as: ((CGSize) -> CGSize).self
        )
        try measure("Swift frontend ObjC aggregate", n: iterations) {
            Int64(
                try unsafe size.unsafeInvoke(on: receiver, CGSize(width: Double($0), height: 3))
                    .width
            )
        }
        let echo = try runtime.resolveObjCImplementationAndWait(
            on: ABIPerfReceiver.self,
            selector: "echoObject:",
            as: ((NSString) -> NSString).self
        )
        let object: NSString = "Benchmark object"
        try measure("Swift frontend ObjC object", n: iterations, delta: 0) { value in
            let result = try unsafe echo.unsafeInvoke(on: receiver, object)
            precondition(result === object)
            return value
        }
        let decorate = try await runtime.resolveSwiftFunction(
            named: "BenchmarkSwiftProvider.decorate(_:)",
            as: ((String) -> String).self
        )
        let input = String(repeating: "x", count: 64)
        measure("Swift direct String", n: iterations, delta: 65) {
            $0 + Int64(BenchmarkSwiftProvider.decorate(input).utf8.count)
        }
        try measure("Swift prepared String", n: iterations, delta: 65) {
            $0 + Int64(try unsafe decorate.unsafeInvoke(input).utf8.count)
        }
        let apply = try await runtime.resolveSwiftFunction(
            named: "BenchmarkSwiftProvider.apply(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self,
            in: source
        )
        let callback = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 1 }
        try measure("Swift reused callback", n: iterations, delta: 1) {
            try unsafe apply.unsafeInvoke(callback, $0)
        }
        try measure("Swift fresh callback", n: min(iterations, 10000), delta: 1) {
            let body = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 1 }
            return try unsafe apply.unsafeInvoke(body, $0)
        }
    }
}
