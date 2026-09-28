import SwiftUI
import AppKit

@MainActor private struct PrivatePanel: View {
    let title: String
    let next: (Int64) -> Int64
    var body: some View {
        VStack {
            Text(verbatim: title)
            Text("Value: \(next(41))")
        }.padding().background(Color.yellow)
    }
}

@MainActor @inline(never) public func makeView(_ title: String, _ next: @escaping (Int64) -> Int64) -> some View {
    PrivatePanel(title: title, next: next)
}

@MainActor @inline(never) public func makeHost(_ title: String, _ next: @escaping (Int64) -> Int64) -> NSView {
    NSHostingView(rootView: makeView(title, next))
}
