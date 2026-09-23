import Foundation

/// One symbol requirement with alternative declarations and ordered image scopes.
///
/// All found declarations within the first matching scope must resolve to the
/// same address and image generation. Missing aliases are ignored. Ambiguity or
/// invalid storage stops resolution rather than falling back to another scope.
public struct NativeSymbolRequest: Sendable, Hashable {
    /// The preferred declaration and the identity used in missing-symbol errors.
    public let declaration: NativeDeclaration
    /// Other spellings accepted only when their resolved addresses agree.
    public let alternatives: [NativeDeclaration]
    /// Scopes tried in order. An empty array matches no images.
    public let imageScopes: [ImageSelector]

    /// Describes a requirement without loading code.
    ///
    /// - Parameters:
    ///   - declaration: The preferred source-level declaration.
    ///   - alternatives: Additional declarations for the same symbol.
    ///   - imageScopes: Ordered scopes; defaults to all loaded images.
    public init(
        _ declaration: NativeDeclaration,
        alternatives: [NativeDeclaration] = [],
        in imageScopes: [ImageSelector] = [.automatic]
    ) {
        self.declaration = declaration
        self.alternatives = alternatives
        self.imageScopes = imageScopes
    }
}
