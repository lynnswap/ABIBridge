import ArchitectureValidation
import Foundation

let mode = CommandLine.arguments.dropFirst().first ?? "native"
let result: ArchitectureReport
if mode == "loading" {
    result = try await runImageLoadingValidation()
} else {
    result = try await runArchitectureValidation(mode: mode)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(result), as: UTF8.self))
