import Foundation

@main struct RuntimeBenchmarks {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first ?? "calls" {
        case "calls":
            let iterations: Int
            if CommandLine.arguments.count > 2 {
                guard let count = Int(CommandLine.arguments[2]), count > 0 else {
                    throw NSError(
                        domain: "RuntimeBenchmarks",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "calls requires a positive iteration count"
                        ]
                    )
                }
                iterations = count
            } else {
                iterations = 50000
            }
            try await Benchmark.run(iterations: iterations)
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
