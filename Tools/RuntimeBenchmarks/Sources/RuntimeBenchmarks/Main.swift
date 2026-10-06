import Foundation

@main struct RuntimeBenchmarks {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first ?? "calls" {
        case "calls": try await Benchmark.run()
        case "prepare": try await Benchmark.runPreparation()
        case "search":
            guard CommandLine.arguments.count == 3 else {
                throw NSError(
                    domain: "RuntimeBenchmarks", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "search requires the generated provider directory"
                    ])
            }
            try await SearchBenchmark.run(in: URL(fileURLWithPath: CommandLine.arguments[2]))
        default:
            throw NSError(
                domain: "RuntimeBenchmarks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Use calls, prepare, or search"])
        }
    }
}
