import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor @Observable public final class PanelModel {
    public var count: Int64
    public init(_ count: Int64 = 0) { self.count = count }
}
@MainActor public final class RenderEvents {
    public var rendered: Int64?
    public init() {}
}
@MainActor private struct NativePanel: View {
    let model: PanelModel
    let events: RenderEvents
    let increment: (Int64) -> Int64

    var body: some View {
        VStack(spacing: 12) {
            Text("Native SwiftUI panel").font(.headline)
            Text("Count: \(model.count)").accessibilityIdentifier("swiftui-count")
            Rectangle().fill(model.count == 0 ? Color.red : Color.blue)
                .frame(width: 160, height: 80)
            Button("Increment") { model.count = increment(model.count) }
                .accessibilityIdentifier("swiftui-increment")
        }
        .padding(24)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .onChange(of: model.count, initial: true) { _, value in events.rendered = value }
    }
}

@MainActor @inline(never) public func makePanel(_ model: PanelModel, _ events: RenderEvents, _ increment: @escaping (Int64) -> Int64) -> some View {
    NativePanel(model: model, events: events, increment: increment)
}
#if !os(watchOS) && (canImport(UIKit) || canImport(AppKit))
@MainActor @inline(never) public func makeHost(_ model: PanelModel, _ events: RenderEvents, _ increment: @escaping (Int64) -> Int64) -> AnyObject {
    #if canImport(UIKit)
    return UIHostingController(rootView: makePanel(model, events, increment))
    #elseif canImport(AppKit)
    return NSHostingView(rootView: makePanel(model, events, increment))
    #endif
}

#endif

@MainActor @inline(never) public func echoText(_ value: Text) -> Text { value }
@MainActor @inline(never) public func echoImage(_ value: Image) -> Image { value }
@MainActor @inline(never) public func echoColor(_ value: Color) -> Color { value }
@MainActor @inline(never) public func echoAnyView(_ value: AnyView) -> AnyView { value }

// A resilient generic declaration: the compiler owns Content's metadata and
// View witnesses when this fixture is imported by the validation adapter.
public nonisolated struct Container<Content: View>: View {
    public let content: Content
    public init(_ content: Content) { self.content = content }
    public var body: some View { VStack(spacing: 8) { Text("Container"); content } }
}
@MainActor @inline(never) public func echoContainer(_ value: Container<Text>) -> Container<Text> { value }
@MainActor @inline(never) public func wrap<Content: View>(_ value: Content) -> Container<Content> { Container(value) }
@MainActor @inline(never) public func wrapText(_ value: Text) -> Container<Text> { wrap(value) }

// This is non-generic at the native boundary; its private/generic composition
// remains the provider compiler's responsibility.
@MainActor @inline(never) public func makeComposedPanel(_ model: PanelModel, _ events: RenderEvents, _ increment: @escaping (Int64) -> Int64) -> some View {
    wrap(makePanel(model, events, increment)).padding(8)
}
