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
    /// Code selected instead of the symbol's address.
    var implementation: SwiftImplementation?

    init(symbol: ResolvedSymbol) {
        self.symbol = symbol
        declaration = symbol.declaration
        linkageName = symbol.linkageName
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
    func implementation(retaining owner: (any Sendable)?) throws -> SwiftImplementation {
        try unsafe withFunction { function in
            try SwiftImplementation(function: function, retaining: (owner, implementation))
        }
    }
}
