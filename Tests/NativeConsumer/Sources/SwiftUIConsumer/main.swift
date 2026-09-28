import ABIBridge
import SwiftUI
import AppKit
import Synchronization

private final class ReleaseFlag: Sendable { let state = Mutex(false) }
private final class Capture: Sendable {
    let destroyed: ReleaseFlag
    init(_ destroyed: ReleaseFlag) { self.destroyed = destroyed }
    func next(_ value: Int64) -> Int64 { value + 1 }
    deinit { destroyed.state.withLock { $0 = true } }
}

@MainActor private struct RetainedView: View {
    let owner: NativeSwiftOpaqueValue
    let content: AnyView
    init(_ owner: NativeSwiftOpaqueValue) throws {
        self.owner = owner
        content = try owner.withValue {
            guard let view = $0 as? any View else { throw Failure.notAView }
            return AnyView(view)
        }
    }
    var body: some View { content }
}
private enum Failure: Error { case notAView }

@MainActor private func pixels<V: View>(_ view: V) -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = .init(width: 240, height: 160)
    renderer.scale = 1
    let image = renderer.cgImage!
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Data(bytes)
}

// This package has no dependency on SwiftUIPlugin and is compiled without its
// swiftmodule. Only the loaded binary and the declared ABI are available.
let library = URL(fileURLWithPath: CommandLine.arguments[1])
let runtime = ABIRuntime()
let make = try await runtime.swiftFunction(named: "SwiftUIPlugin.makeView(_:_:)",
    as: ((String, NativeSwiftClosure<Int64, Int64>) -> NativeSwiftOpaqueValue).self, in: .path(library))
let host = try await runtime.swiftFunction(named: "SwiftUIPlugin.makeHost(_:_:)",
    as: ((String, NativeSwiftClosure<Int64, Int64>) -> NSView).self, in: .path(library))
let title = "Unimportable SwiftUI provider"
let expected = pixels(VStack { Text(verbatim: title); Text("Value: 42") }.padding().background(Color.yellow))
private let destroyed = ReleaseFlag()
private weak var observed: Capture?
var opaque: NativeSwiftOpaqueValue?
do {
    let capture = Capture(destroyed)
    observed = capture
    let callback = try NativeSwiftClosure<Int64, Int64> { capture.next($0) }
    opaque = try unsafe make.unsafeInvoke(title, callback)
}
await runtime.removeCachedResults()
try autoreleasepool {
    let view = try RetainedView(opaque!)
    precondition(pixels(view) == expected)
}
precondition(observed != nil)
opaque = nil
precondition(observed == nil)
destroyed.state.withLock { precondition($0) }

var hostReference: NSView?
weak var observedHost: NSView?
try autoreleasepool {
    let view = try unsafe host.unsafeInvoke(title, .init { $0 + 1 })
    hostReference = view; observedHost = view
}
precondition(hostReference != nil)
hostReference = nil
precondition(observedHost == nil)
print("SwiftUI consumer passed: provider without a module, opaque View rendering, callback lifetime, and compiled host adapter")
