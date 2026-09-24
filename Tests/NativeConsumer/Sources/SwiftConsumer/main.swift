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

private typealias ConsumerBlock = @convention(block) (Int32) -> Int32
private final class BlockReceiver: NSObject {
    @objc var handler: ConsumerBlock?
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

        try await MainActor.run {
            let factory = try ABIRuntime.shared.object(NSData.self as AnyObject).method(
                selector: "data", as: (() -> NSData).self
            )
            let data = try unsafe factory.unsafeInvoke()
            precondition(data.length == 0)
            let receiver = BlockReceiver()
            let object = ABIRuntime.shared.object(receiver)
            let setter = try object.method(selector: "setHandler:", as: ((ConsumerBlock?) -> Void).self)
            let getter = try object.method(selector: "handler", as: (() -> ConsumerBlock?).self)
            let captured = NSNumber(value: 31)
            let block: ConsumerBlock = { captured.int32Value + $0 }
            try unsafe setter.unsafeInvoke(block)
            let returned = try unsafe getter.unsafeInvoke()
            try unsafe setter.unsafeInvoke(nil)
            precondition(returned?(11) == 42)
            let cleared = try unsafe getter.unsafeInvoke()
            precondition(cleared == nil)
            let capturedGetter = try ABIRuntime.shared.objcImplementation(
                on: BlockReceiver.self, selector: "handler", as: (() -> ConsumerBlock?).self
            )
            try unsafe setter.unsafeInvoke(block)
            let capturedBlock = try unsafe capturedGetter.unsafeInvoke(on: receiver)
            precondition(capturedBlock?(11) == 42)
            let capturedFactory = try ABIRuntime.shared.objcImplementation(
                on: NSData.self, selector: "data", as: (() -> NSData).self, classMethod: true
            )
            let capturedData = try unsafe capturedFactory.unsafeInvoke(on: NSData.self as AnyObject)
            precondition(capturedData.length == 0)
        }
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
