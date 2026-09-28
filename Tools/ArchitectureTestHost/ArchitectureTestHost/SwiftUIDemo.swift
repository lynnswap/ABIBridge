import ArchitectureValidation
import SwiftUI
import UIKit

struct SwiftUIDemo: View {
    @State private var route: String
    @State private var session: SwiftUIValidationSession?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(route: String = "opaque") { _route = State(initialValue: route) }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Route", selection: $route) {
                    Text("Host adapter").tag("host")
                    Text("some View").tag("opaque")
                    Text("Composition").tag("composed")
                }.pickerStyle(.segmented).padding()
                if let controller = session?.host as? UIViewController {
                    HostedPanel(controller: controller).id(ObjectIdentifier(controller))
                } else if let error {
                    Text(error).textSelection(.enabled).padding()
                } else {
                    ProgressView("Resolving view…")
                }
            }
            .navigationTitle("SwiftUI Interoperability")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: route) {
                session = nil; error = nil
                do {
                    let value = try await SwiftUIValidationSession.make(route: route)
                    guard !Task.isCancelled else { return }
                    session = value
                } catch { self.error = String(describing: error) }
            }
        }
    }
}

private struct HostedPanel: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
