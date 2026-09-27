import ArchitectureValidation
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var mode = "swift-callback"
    @State private var isRunning = false
    @State private var output = "Choose a probe and run it on this device."
    @State private var reportURL: URL?
    @State private var didAutoRun = false

    private let modes = [
        "native", "swift", "ffi", "memory", "replacement", "hooks",
        "initializers", "native-hooks", "coordinated-hooks",
        "import-replacement", "import-hooks", "virtual-replacement",
        "virtual-hooks", "virtual-entries", "virtual-public",
        "swift-replacement", "swift-callback"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Probe") {
                    Picker("Mode", selection: $mode) {
                        ForEach(modes, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(isRunning)
                    Button("Run probe") {
                        Task { await run(mode) }
                    }
                    .disabled(isRunning)
                    if isRunning {
                        ProgressView("Running \(mode)…")
                    }
                }
                Section("Result") {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if let reportURL {
                        ShareLink("Share JSON report", item: reportURL)
                    }
                }
                Section {
                    Text("A completed report can include a protected-memory refusal. Read its checks before treating a mutation as verified.")
                    Text("The deliberate PAC tamper probe is available only through the --probe tamper launch arguments.")
                }
            }
            .navigationTitle("ABI Architecture")
            .task {
                guard !didAutoRun else { return }
                didAutoRun = true
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--probe"),
                   arguments.indices.contains(index + 1) {
                    let requested = arguments[index + 1]
                    if modes.contains(requested) { mode = requested }
                    await run(requested)
                }
            }
        }
    }

    @MainActor
    private func run(_ selectedMode: String) async {
        guard !isRunning else { return }
        isRunning = true
        reportURL = nil
        output = "Running \(selectedMode)…"
        let previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            isRunning = false
        }

        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            // An invalid launch argument must not become a path outside Documents.
            guard modes.contains(selectedMode) || selectedMode == "tamper" else {
                output = "Unknown probe: \(selectedMode)"
                return
            }
            let url = directory.appendingPathComponent("architecture-\(selectedMode).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["mode": selectedMode, "status": "started"]).write(to: url, options: .atomic)

            let data: Data
            do {
                let report = try await runArchitectureValidation(mode: selectedMode)
                data = try encoder.encode(report)
            } catch {
                data = try encoder.encode([
                    "mode": selectedMode,
                    "status": "failed",
                    "error": String(describing: error)
                ])
            }
            // Replace the started marker only after the probe returns. A crash leaves
            // that marker in place and must never be counted as a completed run.
            try data.write(to: url, options: .atomic)
            output = String(decoding: data, as: UTF8.self)
            reportURL = url
        } catch {
            output += "\nReport error: \(error)"
        }
    }
}
