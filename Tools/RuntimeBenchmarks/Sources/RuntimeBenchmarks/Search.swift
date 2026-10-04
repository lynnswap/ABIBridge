import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
struct SearchBenchmark {
    static func run(in directory: URL) async throws {
        for count in [100, 1000, 10000] {
            let function = "f\(count - 1)"
            let workloads: [(String, String, NativeDeclaration, String)] = [
                (
                    "C++", "libSymbols", .init(name: "LookupBench::\(function)()", language: .cxx),
                    "__ZN11LookupBench\(function.utf8.count)\(function)Ev"
                ),
                (
                    "C", "libSymbols", .init(name: "lookup_C\(count - 1)", language: .c),
                    "_lookup_C\(count - 1)"
                ),
                (
                    "Swift", "libSwiftSymbols",
                    .init(name: "SwiftLookupBench.\(function)() -> Swift.Int32", language: .swift),
                    "_$s16SwiftLookupBench\(function.utf8.count)\(function)s5Int32VyF"
                ),
            ]
            for (language, library, declaration, linkage) in workloads {
                let path = directory.appendingPathComponent("\(library)\(count).dylib")
                var first: [Double] = []
                for _ in 0..<5 {
                    let runtime = ABIRuntime()
                    let start = ContinuousClock.now
                    let symbol = try await runtime.resolve(declaration, in: .path(path))
                    first.append(seconds(start.duration(to: .now)) * 1000)
                    guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
                        fatalError("Provider failed to load")
                    }
                    defer { dlclose(handle) }
                    guard let expected = dlsym(handle, String(linkage.dropFirst())) else {
                        fatalError("Missing fixture symbol " + linkage)
                    }
                    unsafe symbol.withUnsafeAddress {
                        precondition($0 == UnsafeRawPointer(expected))
                    }
                }
                let runtime = ABIRuntime()
                let initial = try await runtime.resolve(declaration, in: .path(path))
                var repeated: [Double] = []
                for _ in 0..<5 {
                    let start = ContinuousClock.now
                    for _ in 0..<1000 {
                        let symbol = try await runtime.resolve(declaration, in: .path(path))
                        unsafe symbol.withUnsafeAddress { address in
                            unsafe initial.withUnsafeAddress { precondition(address == $0) }
                        }
                    }
                    repeated.append(seconds(start.duration(to: .now)) * 1e6 / 1000)
                }
                var retained: [Double] = []
                for _ in 0..<5 {
                    let start = ContinuousClock.now
                    for _ in 0..<1000 {
                        let symbol = try await runtime.resolve(
                            declaration, in: initial.image, loading: .loadedOnly)
                        unsafe symbol.withUnsafeAddress { address in
                            unsafe initial.withUnsafeAddress { precondition(address == $0) }
                        }
                    }
                    retained.append(seconds(start.duration(to: .now)) * 1e6 / 1000)
                }
                print(
                    "\(language) declarations=\(count) first=\(median(first)) ms repeated-path=\(median(repeated)) us retained-image=\(median(retained)) us"
                )
            }
        }
        for (language, name) in [
            ("C++ simple", "_ZN7ABIPerf3addEii"),
            (
                "C++ standard string",
                "_ZN16ABIBridgeFixture5greetENSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE"
            ), ("Swift regular", "$s12PerfProvider3addys5Int64VAD_ADtF"),
            ("Swift generic", "$s12PerfProvider8hashEchoyxxSHRzlF"),
        ] {
            var samples: [Double] = []
            var length = 0
            for _ in 0..<5 {
                let start = ContinuousClock.now
                for _ in 0..<10000 {
                    let decoded = name.withCString {
                        language.hasPrefix("C++")
                            ? ABICopyDemangledCXXName($0) : ABICopyDemangledSwiftName($0)
                    }
                    guard let decoded else { fatalError("Invalid demangling input: \(name)") }
                    length = String(cString: decoded).utf8.count
                    ABIFreeString(decoded)
                }
                samples.append(seconds(start.duration(to: .now)) * 1e6 / 10000)
            }
            print("\(language) demangle=\(median(samples)) us length=\(length)")
        }
        let table = UnsafeMutablePointer<UInt>.allocate(capacity: 4)
        table.initialize(repeating: 0, count: 4)
        defer {
            table.deinitialize(count: 4)
            table.deallocate()
        }
        let addressPoint = UInt(bitPattern: table)
        let targets = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        targets.initialize(repeating: addressPoint, count: 2)
        defer {
            targets.deinitialize(count: 2)
            targets.deallocate()
        }
        for bytes in [1024, 65536, 1_048_576, 16_777_216] {
            let count = bytes / MemoryLayout<UInt>.size
            let slots = UnsafeMutablePointer<UInt>.allocate(capacity: count)
            slots.initialize(repeating: 0, count: count)
            defer {
                slots.deinitialize(count: count)
                slots.deallocate()
            }
            let region = try NativeMemoryRegion(address: UInt(bitPattern: slots), byteCount: bytes)
            for density in ["empty", "single", "aliases", "distinct"] {
                slots.update(repeating: 0, count: count)
                if density != "empty" { slots[count - 1] = UInt(bitPattern: targets) }
                if density == "aliases" { slots[0] = UInt(bitPattern: targets) }
                if density == "distinct" { slots[0] = UInt(bitPattern: targets.advanced(by: 1)) }
                var samples: [Double] = []
                for _ in 0..<3 {
                    let start = ContinuousClock.now
                    let result = try region.pointers(
                        toVTable: addressPoint, options: .init(normalization: .none))
                    samples.append(seconds(start.duration(to: .now)) * 1000)
                    precondition(
                        result.isComplete && result.failures.isEmpty && result.visitedCount == count
                    )
                    precondition(
                        result.candidates.count
                            == (density == "empty" ? 0 : density == "single" ? 1 : 2))
                    precondition(
                        result.distinctCount
                            == (density == "empty" ? 0 : density == "distinct" ? 2 : 1))
                }
                print("Pointer bytes=\(bytes) \(density) full=\(median(samples)) ms")
            }
            var hint: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                for _ in 0..<100 {
                    let result = try region.pointers(
                        toVTable: addressPoint,
                        options: .init(
                            normalization: .none, policy: .first,
                            hintOffset: bytes - MemoryLayout<UInt>.size))
                    precondition(
                        result.visitedCount == 1
                            && result.candidates[0].offset == bytes - MemoryLayout<UInt>.size)
                }
                hint.append(seconds(start.duration(to: .now)) * 1e6 / 100)
            }
            print("Pointer bytes=\(bytes) hint=\(median(hint)) us")
        }
    }
}
