import ABIBridge
import ABIBridgeTestSupport
import Foundation
import Testing

#if os(macOS)
/// How a conformance provider module is built.
///
/// Stripped variants model frameworks such as SimulatorKit: local symbols are
/// stripped, so a library-evolution class member that clients call through a
/// dispatch thunk keeps only that thunk and its method descriptor.
struct ConformanceVariant: Hashable, Sendable, CustomTestStringConvertible {
    enum Bodies: String, Sendable { case exported, stripped }

    let libraryEvolution: Bool
    let bodies: Bodies
    let optimized: Bool

    var testDescription: String {
        [
            libraryEvolution ? "evolution" : "fixed",
            bodies.rawValue,
            optimized ? "O" : "Onone",
        ].joined(separator: "-")
    }

    /// Variants run by default. Set ABI_CONFORMANCE_VARIANTS=all for every variant.
    static var selected: [Self] {
        ProcessInfo.processInfo.environment["ABI_CONFORMANCE_VARIANTS"] == "all" ? all : continuous
    }

    static let continuous: [Self] = [
        .init(libraryEvolution: false, bodies: .exported, optimized: false),
        .init(libraryEvolution: true, bodies: .exported, optimized: true),
        .init(libraryEvolution: true, bodies: .stripped, optimized: true),
    ]

    // Without library evolution, class members have no dispatch thunks, so
    // stripping their bodies only removes them.
    static let all: [Self] = [false, true].flatMap { optimized in
        [
            Self(libraryEvolution: false, bodies: .exported, optimized: optimized),
            Self(libraryEvolution: true, bodies: .exported, optimized: optimized),
            Self(libraryEvolution: true, bodies: .stripped, optimized: optimized),
        ]
    }
}

/// One provider image and its compiled oracle for a variant.
final class ConformanceFixture: @unchecked Sendable {
    let variant: ConformanceVariant
    let module: String
    let provider: FixtureLibrary
    let consumer: FixtureLibrary
    let runtime = ABIRuntime()
    private let oracle: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>

    var scope: ImageSelector { .path(provider.libraryURL) }

    init(variant: ConformanceVariant, cases: [ConformanceCase]) throws {
        self.variant = variant
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        module = "Conformance_" + suffix
        let optimization = variant.optimized ? "-O" : "-Onone"
        var providerArguments = [
            optimization, "-swift-version", "6", "-emit-module", "-parse-as-library",
        ]
        if variant.libraryEvolution { providerArguments.append("-enable-library-evolution") }
        provider = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: cases.map(\.provider).joined(separator: "\n"),
            linkArguments: providerArguments
        )
        if variant.bodies == .stripped { try Self.stripLocalSymbols(of: provider) }
        try provider.load()
        let consumerModule = "ConformanceOracle_" + suffix
        consumer = try FixtureLibrary(
            swiftModule: consumerModule,
            swiftSource: Self.oracleSource(module: module, cases: cases),
            linkArguments: [
                optimization, "-swift-version", "6", "-parse-as-library", "-I",
                provider.directory.path,
                provider.libraryURL.path,
            ]
        )
        oracle = unsafeBitCast(
            try consumer.symbol(named: "conformance_oracle"),
            to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>).self
        )
    }

    /// The result of the case's compiled caller.
    func expected(_ id: String) -> String {
        let result = id.withCString { oracle($0) }
        defer { free(result) }
        return String(cString: result)
    }

    func type(_ name: String) async throws -> NativeSwiftType {
        try await runtime.resolve(.swift(.type(module + "." + name)), in: scope)
    }

    /// A provider function, named relative to the provider module.
    func function<Signature>(
        _ declaration: String,
        as signature: Signature.Type,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftFunction<Signature> {
        try await runtime.resolve(
            .swift(
                .function(
                    module + "." + declaration,
                    as: signature,
                    valueABIs: valueABIs
                )
            ),
            in: scope
        )
    }

    /// Calls a provider factory, such as `cmMakeCounter`, that takes no
    /// arguments and returns an instance of the provider class `type`.
    func make(_ factory: String, returning type: String) throws -> AnyObject {
        let make = try runtime.resolveAndWait(
            .swift(
                .function(
                    "\(module).\(factory)() -> \(module).\(type)",
                    as: (() -> AnyObject).self
                )
            ),
            in: scope
        )
        return try unsafe make.unsafeInvoke()
    }

    func cleanup() {
        consumer.cleanup()
        provider.cleanup()
    }

    // Library evolution already leaves dispatched member bodies unexported;
    // stripping local symbols leaves only their thunks and descriptors. A
    // known-issue cell that starts passing reveals a strip that kept them.
    private static func stripLocalSymbols(of library: FixtureLibrary) throws {
        try FixtureLibrary.run(["--sdk", "macosx", "strip", "-u", "-r", library.libraryURL.path])
    }

    private static func oracleSource(module: String, cases: [ConformanceCase]) -> String {
        let branches = cases.map { item in
            """
                case "\(item.id)":
                    result = { () -> String in
            \(item.oracle)
                    }()
            """
        }.joined(separator: "\n")
        return """
            import Foundation
            import \(module)

            func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
                nonisolated(unsafe) var value: T?
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    value = await body()
                    done.signal()
                }
                done.wait()
                return value!
            }

            @_cdecl("conformance_oracle")
            public func conformanceOracle(_ id: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
                let result: String
                switch String(cString: id) {
            \(branches)
                default: result = "unknown case"
                }
                return strdup(result)!
            }
            """
    }
}

/// Builds each variant's provider once per test process.
actor ConformanceFixtures {
    static let shared = ConformanceFixtures()
    private var fixtures: [ConformanceVariant: Result<ConformanceFixture, any Error>] = [:]

    func fixture(for variant: ConformanceVariant) throws -> ConformanceFixture {
        if let fixture = fixtures[variant] { return try fixture.get() }
        let fixture = Result {
            try ConformanceFixture(variant: variant, cases: ConformanceCase.all)
        }
        fixtures[variant] = fixture
        return try fixture.get()
    }
}

/// One native declaration, its compiled caller, and its ABIBridge call.
struct ConformanceCase: Sendable, CustomTestStringConvertible {
    /// Unique among cases; also the oracle branch name.
    let id: String
    /// Declarations added to the provider module. Names must be unique across cases.
    let provider: String
    /// Statements in the oracle module that return the expected result as a String.
    let oracle: String
    /// The ABIBridge call that must produce the same String.
    let invoke: @Sendable (ConformanceFixture) async throws -> String
    /// A reason and the issue expected to resolve it, for cells that do not pass yet.
    var knownIssue: @Sendable (ConformanceVariant) -> String? = { _ in nil }
    /// For variants whose binary evidence cannot decide the call's convention,
    /// the evidence that the `metadataUnavailable` failure must name instead
    /// of matching the compiled caller.
    var expectedError: @Sendable (ConformanceVariant) -> String? = { _ in nil }

    var testDescription: String { id }
}
#endif
