import ABIBridgeRuntime
import ABIBridgeCore

/// A selected Swift declaration and the code that calls of it run.
///
/// Lookup establishes three facts that do not always come from one symbol:
/// the declaration (its source name and mangled signature), its provenance
/// (the image whose descriptors describe it, such as opaque result and async
/// entry descriptors), and the code a call runs. `implementation` replaces the
/// symbol's own address when lookup selected other code, and owns that code.
struct SwiftEntry: Sendable {
    /// The exported symbol that names the declaration.
    let symbol: ResolvedSymbol
    let declaration: NativeDeclaration
    /// The declaration's mangled name, used to bind its native signature.
    let linkageName: String
    /// The image that holds the declaration's descriptors.
    let provenance: NativeImage
    /// What the symbol declares, when it is a Swift declaration.
    let record: RuntimeSwiftDeclaration?
    /// Code selected instead of the symbol's address.
    var implementation: SwiftImplementation?
    /// The async function pointer selected with `implementation` for an
    /// async declaration.
    var asyncEntry: SwiftAsyncEntry?

    init(symbol: ResolvedSymbol) {
        self.init(
            symbol: symbol,
            record: RuntimeSwiftDeclaration(linkageName: symbol.linkageName),
            declaration: symbol.declaration,
            linkageName: symbol.linkageName
        )
    }

    /// An entry whose symbol, such as a dispatch thunk, can name a
    /// declaration other than its own.
    init(
        symbol: ResolvedSymbol,
        record: RuntimeSwiftDeclaration?,
        declaration: NativeDeclaration,
        linkageName: String
    ) {
        self.symbol = symbol
        self.record = record
        self.declaration = declaration
        self.linkageName = linkageName
        provenance = symbol.image
    }

    /// The images that keep the code a call runs loaded.
    var codeImages: [NativeImage] { [symbol.image] + [implementation?.image].compactMap { $0 } }

    /// Passes the code a call runs to `body` while its owners stay alive.
    @unsafe func withFunction<Result: ~Copyable>(
        _ body: (ABIUnmanagedFunction) throws -> Result
    ) rethrows -> Result {
        if let implementation {
            return try withExtendedLifetime(implementation) { try body(implementation.function) }
        }
        return try unsafe symbol.withUnsafeAddress { try body(ABIUnsafeFunctionAtAddress($0)) }
    }

    /// The code a call runs, owned together with `owner`.
    ///
    /// Published code without an owner is pinned once per image generation,
    /// so an owner is attached only when one exists.
    func implementation(retaining owner: (any Sendable)?) throws -> SwiftImplementation {
        guard let implementation else {
            return try unsafe symbol.withUnsafeAddress {
                try SwiftImplementation(function: ABIUnsafeFunctionAtAddress($0), retaining: owner)
            }
        }
        guard let owner else { return implementation }
        return try SwiftImplementation(
            function: implementation.function,
            retaining: (owner, implementation)
        )
    }
}

/// A Swift symbol found for a lookup, with the declaration it defines or dispatches.
struct SwiftCandidate: Sendable {
    let symbol: ResolvedSymbol
    let record: RuntimeSwiftDeclaration
    /// The declaration the symbol defines or, for a thunk, dispatches.
    let declaration: NativeDeclaration
    /// The declaration's name without the module of an extension that declares it.
    let memberName: String

    init(_ value: RuntimeSwiftCandidate) {
        symbol = ResolvedSymbol(value.symbol)
        record = value.record
        declaration = NativeDeclaration(value.declaration)
        memberName = value.memberName
    }

    /// The entry a call through this candidate uses. A protocol requirement
    /// is called through its dispatch thunk, which selects the witness, or
    /// through a conformance's witness; either symbol names itself. Other
    /// candidates name the declaration they define or dispatch.
    var entry: SwiftEntry {
        SwiftEntry(
            symbol: symbol,
            record: record,
            declaration: record.context == .protocolRequirement ? symbol.declaration : declaration,
            linkageName: record.context == .protocolRequirement
                ? symbol.linkageName : record.identity
        )
    }
}
