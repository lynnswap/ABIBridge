import ABIBridge
import ABIBridgeSwiftUI
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
let echo = try await runtime.swiftFunction(
    named: "SwiftUIPlugin.echo<A where A: SwiftUI.View>(A) -> A",
    as: ((Text) -> Text).self, genericArguments: [.type(Text.self)], in: .path(library))
let echoed = try unsafe echo.unsafeInvoke(Text(verbatim: "Generic SwiftUI value"))
precondition(pixels(echoed) == pixels(Text(verbatim: "Generic SwiftUI value")))
let make = try await runtime.swiftFunction(named: "SwiftUIPlugin.makeView(_:_:)",
    as: ((String, NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftOpaqueValue).self, in: .path(library))
let host = try await runtime.swiftFunction(named: "SwiftUIPlugin.makeHost(_:_:)",
    as: ((String, NativeSwiftClosure<(Int64) -> Int64>) -> NSView).self, in: .path(library))
let title = "Unimportable SwiftUI provider"
let expected = pixels(VStack { Text(verbatim: title); Text("Value: 42") }.padding().background(Color.yellow))
private let destroyed = ReleaseFlag()
private weak var observed: Capture?
var opaque: NativeSwiftOpaqueValue?
do {
    let capture = Capture(destroyed)
    observed = capture
    let callback = try NativeSwiftClosure<(Int64) -> Int64> { capture.next($0) }
    opaque = try unsafe make.unsafeInvoke(title, callback)
}
var retainedView: NativeSwiftView? = try NativeSwiftView(opaque!)
opaque = nil
await runtime.removeCachedResults()
precondition(observed != nil)
var copiedView = retainedView
retainedView = nil
autoreleasepool { precondition(pixels(copiedView!) == expected) }
precondition(observed != nil)
copiedView = nil
precondition(observed == nil)
destroyed.state.withLock { precondition($0) }

let number = try await runtime.swiftFunction(named: "SwiftUIPlugin.makeNumber()",
    as: (() -> NativeSwiftOpaqueValue).self, in: .path(library))
let numberResult = try unsafe number.unsafeInvoke()
do {
    _ = try NativeSwiftView(numberResult)
    fatalError("Expected non-View rejection")
} catch let error as ABIInvocationError {
    precondition(error == .incompatibleValue(expected: "any SwiftUI.View", actual: "Swift.Int64"))
}
numberResult.withValue { precondition($0 as? Int64 == 42) }

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
