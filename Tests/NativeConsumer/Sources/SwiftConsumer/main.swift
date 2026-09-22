import ABIBridge
import Darwin
import Foundation

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
        dlclose(loader!)
        loader = nil
        await runtime.removeCachedResults()

        let sum = try unsafe add.unsafeInvoke(20, 22)
        let cSum = try unsafe cAdd.unsafeInvoke(12, 30)
        precondition(sum == 42 && cSum == 42)
        print("Swift consumer passed: typed C/C++ functions and retained image lifetime.")
    }
}
