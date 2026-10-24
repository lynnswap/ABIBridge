#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Testing

/// Overloads that only the shared cache's local symbols describe, beside an
/// exported overload with the same labels.
struct SwiftSharedCacheOverloadTests {
    @Test func labelOnlyLookupFindsOverloadsOnlyLocalSymbolsDescribe() async throws {
        let module = "LocalOverload_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public func value() -> Int { 1 }
                public final class Counter {
                    public init() {}
                    public func value() -> Int { 1 }
                }
                """,
            linkArguments: ["-parse-as-library", "-enable-library-evolution"]
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        // Each exported `value() -> Int` gains a `value() -> String` that only
        // local symbols describe. Lookup does not run either.
        var overloads: [(name: String, address: UInt64)] = []
        for request in [module + ".value() -> Swift.Int", module + ".Counter.value() -> Swift.Int"] {
            let exported = try #require(
                try RuntimeSymbolResolver().swiftDeclarationCandidates(
                    .init(name: request, language: .swift),
                    in: image
                ).first
            )
            let identity = exported.record.identity
            #expect(identity.hasSuffix("SiyF"))
            overloads.append((String(identity.dropLast(4)) + "SSyF", exported.symbol.address + 4))
        }
        let local = overloads
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        for overload in local {
                            ("_" + overload.name).withCString { record($0, overload.address) }
                        }
                    }
                ],
                imageIdentity: image.identity
            )
        })
        let runtime = ABIRuntime(resolver: SymbolResolver(resolver))
        let function = try await runtime.resolve(
            .swift(
                .function(
                    module + ".value()",
                    as: (() -> String).self
                )
            ),
            in: .path(fixture.libraryURL)
        )
        #expect(function.symbol.linkageName.hasSuffix(local[0].name))
        let type = try await runtime.resolveSwiftType(
            named: module + ".Counter",
            in: .path(fixture.libraryURL)
        )
        let method = try await type.resolve(.swift(.method("value()", as: (() -> String).self)))
        #expect(method.symbol.linkageName.hasSuffix(local[1].name))
    }
}
#endif
