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
    _ label: String, n: Int = 50000, delta: Int64 = 7, _ body: (Int64) throws -> Int64
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
    @MainActor static func run() async throws {
        ABIPerfRunNative()
        let runtime = ABIRuntime()
        let source = ImageSelector.automatic
        let start = ContinuousClock.now
        let regular = try await runtime.swiftFunction(
            named: "BenchmarkSwiftProvider.add(_:_:)", as: ((Int64, Int64) -> Int64).self,
            in: source)
        print("Swift regular first preparation: \(seconds(start.duration(to:.now))*1000) ms")
        let genericStart = ContinuousClock.now
        let generic = try await runtime.swiftFunction(
            named: "BenchmarkSwiftProvider.identity(_:)", as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)], in: source)
        print("Swift generic first preparation: \(seconds(genericStart.duration(to:.now))*1000) ms")
        let constrainedStart = ContinuousClock.now
        let constrained = try await runtime.swiftFunction(
            named: "BenchmarkSwiftProvider.hashEcho(_:)", as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)], in: source)
        print(
            "Swift Hashable first preparation: \(seconds(constrainedStart.duration(to:.now))*1000) ms"
        )
        measure("Swift direct") { BenchmarkSwiftProvider.add($0, 7) }
        try measure("Swift prepared regular") { try unsafe regular.unsafeInvoke($0, 7) }
        measure("Swift direct Hashable generic", delta: 0) { BenchmarkSwiftProvider.hashEcho($0) }
        measure("Swift direct callback", delta: 1) { BenchmarkSwiftProvider.apply({ $0 + 1 }, $0) }
        measure("Swift direct generic", delta: 0) { BenchmarkSwiftProvider.identity($0) }
        try measure("Swift prepared generic", delta: 0) { try unsafe generic.unsafeInvoke($0) }
        try measure("Swift prepared Hashable generic", delta: 0) {
            try unsafe constrained.unsafeInvoke($0)
        }
        let c = try await runtime.cFunction(
            named: "ABIPerfCAdd", as: ((Int32, Int32) -> Int32).self)
        let cpp = try await runtime.cxxFunction(
            named: "ABIPerf::add(int, int)", as: ((Int32, Int32) -> Int32).self)
        try measure("Swift frontend C") { Int64(try unsafe c.unsafeInvoke(Int32($0), 7)) }
        try measure("Swift frontend C++") { Int64(try unsafe cpp.unsafeInvoke(Int32($0), 7)) }
        let receiver = ABIPerfReceiver()
        let objc = try runtime.object(receiver).method(
            selector: "add:right:", as: ((Int64, Int64) -> Int64).self)
        let captured = try runtime.objcImplementation(
            on: ABIPerfReceiver.self, selector: "add:right:", as: ((Int64, Int64) -> Int64).self)
        try measure("Swift frontend ObjC message") { try unsafe objc.unsafeInvoke($0, 7) }
        try measure("Swift frontend captured ObjC IMP") {
            try unsafe captured.unsafeInvoke(on: receiver, $0, 7)
        }
        let apply = try await runtime.swiftFunction(
            named: "BenchmarkSwiftProvider.apply(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self, in: source)
        let callback = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 1 }
        try measure("Swift reused callback", delta: 1) {
            try unsafe apply.unsafeInvoke(callback, $0)
        }
        try measure("Swift fresh callback", n: 10000, delta: 1) {
            let body = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 1 }
            return try unsafe apply.unsafeInvoke(body, $0)
        }
    }
}
