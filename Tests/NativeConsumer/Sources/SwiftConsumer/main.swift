import ABIBridge
import Darwin
import Foundation

private struct LargeValue: ABIBridgeValue {
    static let abiType = try! NativeType.structure(
        named: "ABIBridgeFixture::LargeResult", fields: Array(repeating: .int, count: 8)
    )
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.storage }
}

@main
struct SwiftConsumer {
    enum Failure: Error { case missingPath, loadFailed, missingImage }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.missingPath }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var loader = dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
        guard loader != nil else { throw Failure.loadFailed }
        defer { if let loader { dlclose(loader) } }

        let runtime = ABIRuntime()
        let processID = try await runtime.cFunction(named: "getpid", as: (() -> Int32).self)
        let pid = try unsafe processID.unsafeInvoke()
        precondition(pid == getpid())

        let images = try await runtime.images(matching: .path(url))
        guard let image = images.first else { throw Failure.missingImage }
        let add = try await runtime.cxxFunction(
            named: "ABIBridgeFixture::add(int, int)",
            as: ((Int32, Int32) -> Int32).self, in: image
        )
        let cAdd = try await runtime.cFunction(
            named: "ABIBridgeFixtureCAdd",
            as: ((Int32, Int32) -> Int32).self, in: .path(url)
        )
        let large = try await runtime.cxxFunction(
            named: "ABIBridgeFixture::large(long)", as: ((Int) -> LargeValue).self, in: image
        )
        let dynamic = try await runtime.cxxFunction(
            named: "ABIBridgeFixture::large(long)",
            signature: .init(parameters: [.int], returns: LargeValue.abiType), in: image
        )
        dlclose(loader!)
        loader = nil
        await runtime.removeCachedResults()

        let sum = try unsafe add.unsafeInvoke(20, 22)
        let cSum = try unsafe cAdd.unsafeInvoke(12, 30)
        precondition(sum == 42 && cSum == 42)
        let typedResult = try unsafe large.unsafeInvoke(10)
        let typedLast = try unsafe typedResult.storage.field(at: 7).read(as: Int.self)
        let dynamicResult = try unsafe dynamic.unsafeInvoke(with: [NativeValue(copying: Int(20), as: .int)])
        let wrapped = try dynamicResult.cast(to: LargeValue.self)
        let dynamicLast = try unsafe wrapped.storage.field(at: 7).read(as: Int.self)
        precondition(typedLast == 17 && dynamicLast == 27)
        print("Swift consumer passed: typed C/C++ functions, native wrappers, runtime signatures, and image lifetime.")
    }
}
