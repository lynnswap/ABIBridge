import ABIBridge
import ABIBridgeSwiftUI
import SwiftUI
import SwiftUIFixtures
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Fixture-only conformances. These describe the SDK's frozen layouts verified
// by check-swiftui-codegen.py, not all values merely conforming to View.
extension Text: @retroactive ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        let words: [NativeType] = [.uint, .uint]
        return try! .structure(named: "SwiftUI.Text", fields: words + [.uint8, .pointer])
    }
}
extension Image: @retroactive ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .pointer } }
extension Color: @retroactive ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .pointer } }
extension AnyView: @retroactive ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .pointer } }
extension Container: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { try! .opaque(named: "SwiftUIFixtures.Container") }
}

/// A visible consumer of three existing ABIBridge invocation paths.
@MainActor public final class SwiftUIValidationSession {
    public let model: PanelModel
    public let events: RenderEvents
    public let host: AnyObject
    private init(model: PanelModel, events: RenderEvents, host: AnyObject) {
        self.model = model; self.events = events; self.host = host
    }

    public static func make(route: String) async throws -> SwiftUIValidationSession {
        let runtime = ABIRuntime()
        let model = PanelModel(), events = RenderEvents()
        let increment = try NativeSwiftClosure<Int64, Int64> { $0 + 1 }
        let host: AnyObject
        if route == "host" {
            let make = try await runtime.swiftFunction(named: "SwiftUIFixtures.makeHost(_:_:_:)",
                as: ((PanelModel, RenderEvents, NativeSwiftClosure<Int64, Int64>) -> AnyObject).self)
            host = try unsafe make.unsafeInvoke(model, events, increment)
        } else {
            let name = route == "opaque" ? "makePanel" : "makeComposedPanel"
            let make = try await runtime.swiftFunction(named: "SwiftUIFixtures." + name + "(_:_:_:)",
                as: ((PanelModel, RenderEvents, NativeSwiftClosure<Int64, Int64>) -> NativeSwiftOpaqueValue).self)
            let result = try unsafe make.unsafeInvoke(model, events, increment)
            let view = try NativeSwiftView(result)
            #if canImport(UIKit)
            host = UIHostingController(rootView: view)
            #else
            host = NSHostingView(rootView: view)
            #endif
        }
        await runtime.removeCachedResults()
        return SwiftUIValidationSession(model: model, events: events, host: host)
    }
}

private struct SwiftUIRender {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    func matches(_ other: Self) -> Bool {
        // Repeated Core Text rasterization can round a color channel by one
        // level (observed in Release). Geometry and larger changes must match.
        width == other.width && height == other.height &&
            zip(pixels, other.pixels).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    }
}

@MainActor private func swiftUIImage<Content: View>(_ content: Content) throws -> SwiftUIRender {
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = .init(width: 240, height: 160)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
        throw ArchitectureValidationFailure(description: "SwiftUI renderer did not produce an image")
    }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let result = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard result else { throw ArchitectureValidationFailure(description: "Cannot read rendered SwiftUI pixels") }
    return SwiftUIRender(width: image.width, height: image.height, pixels: bytes)
}

@MainActor public func validateSwiftUIValues() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let text = try await runtime.swiftFunction(named: "SwiftUIFixtures.echoText(_:)", as: ((Text) -> Text).self)
    for input in [Text(verbatim: String(repeating: "text", count: 16)), Text("Count: \(42)").bold().italic()] {
        let result = try unsafe text.unsafeInvoke(input)
        try check(result == input && (try swiftUIImage(result)).matches(try swiftUIImage(input)), "Text preserves storage, modifiers, and rendered pixels")
    }
    let image = try await runtime.swiftFunction(named: "SwiftUIFixtures.echoImage(_:)", as: ((Image) -> Image).self)
    let symbol = Image(systemName: "star.fill")
    let returned = try unsafe image.unsafeInvoke(symbol)
    try check(returned == symbol && (try swiftUIImage(returned)).matches(try swiftUIImage(symbol)), "Image retains its provider and renders identically")
    let color = try await runtime.swiftFunction(named: "SwiftUIFixtures.echoColor(_:)", as: ((Color) -> Color).self)
    let original = Color(red: 0.25, green: 0.5, blue: 0.75)
    let returnedColor = try unsafe color.unsafeInvoke(original)
    try check(returnedColor == original && (try swiftUIImage(returnedColor)).matches(try swiftUIImage(original)), "Color retains its provider and renders identically")
    let any = try await runtime.swiftFunction(named: "SwiftUIFixtures.echoAnyView(_:)", as: ((AnyView) -> AnyView).self)
    let erased = AnyView(Text("Erased").padding().background(Color.yellow))
    try check(try swiftUIImage(unsafe any.unsafeInvoke(erased)).matches(swiftUIImage(erased)), "AnyView preserves a compiler-composed view")

    let container = try await runtime.swiftFunction(named: "SwiftUIFixtures.echoContainer(_:)",
        as: ((Container<Text>) -> Container<Text>).self)
    let content = Container(Text("Generic content"))
    try check(try swiftUIImage(unsafe container.unsafeInvoke(content)).matches(swiftUIImage(content)), "Imported Container<Text> uses its resilient indirect convention")
    let wrap = try await runtime.swiftFunction(named: "SwiftUIFixtures.wrapText(_:)",
        as: ((Text) -> Container<Text>).self)
    let input = Text("Compiler adapter")
    try check(try swiftUIImage(unsafe wrap.unsafeInvoke(input)).matches(swiftUIImage(SwiftUIFixtures.wrap(input))), "Compiled specialization supplies generic View metadata and witnesses")

    let opaque = try await runtime.swiftFunction(named: "SwiftUIFixtures.makeComposedPanel(_:_:_:)",
        as: ((PanelModel, RenderEvents, NativeSwiftClosure<Int64, Int64>) -> NativeSwiftOpaqueValue).self)
    let model = PanelModel(), events = RenderEvents()
    let result = try unsafe opaque.unsafeInvoke(model, events, .init { $0 + 1 })
    let view = try NativeSwiftView(result)
    let before = try swiftUIImage(view)
    model.count = 1
    let after = try swiftUIImage(view)
    try check(!before.matches(after), "Private some View composition renders an observable state change")
    try check(after.matches(swiftUIImage(SwiftUIFixtures.makeComposedPanel(model, events, { $0 + 1 }))), "Opaque View erasure matches the ordinary compiler call")
    let number = try await runtime.swiftFunction(named: "SwiftUIFixtures.makeNumber()", as: (() -> NativeSwiftOpaqueValue).self)
    let nonView = try unsafe number.unsafeInvoke()
    do {
        _ = try NativeSwiftView(nonView)
        throw ArchitectureValidationFailure(description: "Non-View opaque result unexpectedly created a view")
    } catch let error as ABIInvocationError {
        try check(error == .incompatibleValue(expected: "any SwiftUI.View", actual: "Swift.Int64"),
                  "Non-View result reports its actual type through ABIInvocationError")
    }
    try nonView.withValue { try check($0 as? Int64 == 42, "Failed view conversion leaves the owned result usable") }

    weak var capturedModel: PanelModel?
    var ownedView: NativeSwiftView?
    do {
        let model = PanelModel()
        capturedModel = model
        let result = try unsafe opaque.unsafeInvoke(model, RenderEvents(), .init { $0 + 1 })
        ownedView = try NativeSwiftView(result)
    }
    var copiedView = ownedView
    ownedView = nil
    try check(capturedModel != nil, "Copied NativeSwiftView keeps its hidden model after the original result is released")
    _ = try swiftUIImage(copiedView!)
    copiedView = nil
    let deadline = ContinuousClock.now + .seconds(5)
    while capturedModel != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try check(capturedModel == nil, "Final NativeSwiftView release destroys the hidden model after rendering")
    return checks
}

/// Validates graph updates in an actual platform host. The onChange observer
/// acknowledges SwiftUI evaluation; a timeout reports missing updates.
@MainActor public func validateSwiftUIHosts() async throws -> [String] {
    var checks: [String] = []
    for route in ["host", "opaque", "composed"] {
        weak var modelReference: PanelModel?
        weak var hostReference: AnyObject?
        do {
            var session: SwiftUIValidationSession? = try await .make(route: route)
            modelReference = session!.model
            hostReference = session!.host
            #if canImport(UIKit)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                throw ArchitectureValidationFailure(description: "Host validation requires an active UIWindowScene")
            }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
            window.rootViewController = session!.host as? UIViewController
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            #else
            _ = NSApplication.shared
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session!.host as? NSView
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            #endif
            for expected in [Int64(0), 1] {
                session!.model.count = expected
                let deadline = ContinuousClock.now + .seconds(5)
                while session!.events.rendered != expected && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard session!.events.rendered == expected else {
                    throw ArchitectureValidationFailure(description: route + " host did not render state \(expected)")
                }
                checks.append(route + " host rendered state \(expected) on MainActor")
            }
            #if canImport(UIKit)
            window.isHidden = true; window.rootViewController = nil
            #else
            window.orderOut(nil); window.contentView = nil
            #endif
            session = nil
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while (modelReference != nil || hostReference != nil) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard modelReference == nil && hostReference == nil else {
            throw ArchitectureValidationFailure(description: route + " host or model remained retained after teardown")
        }
        checks.append(route + " host and model release after teardown")
    }
    return checks
}
