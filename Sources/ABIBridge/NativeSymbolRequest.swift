import Foundation

/// One symbol requirement with aliases, lazy fallbacks, and ordered image scopes.
///
/// All found aliases within the first matching scope must resolve to the same
/// address and image generation. Missing aliases are ignored. Only absence
/// advances to another scope or fallback; substantive errors stop resolution.
/// Candidate priority precedes scope priority: all scopes are searched for the
/// primary and aliases before trying each fallback across the same scopes.
public struct NativeSymbolRequest: Sendable, Hashable {
    /// The preferred declaration and the identity used in missing-symbol errors.
    public let declaration: NativeDeclaration
    /// Other spellings accepted only when their resolved addresses agree.
    public let alternatives: [NativeDeclaration]
    /// Declarations tried in order only if the primary and all aliases are absent.
    ///
    /// The first successful candidate wins; later candidates are not resolved.
    public let fallbacks: [NativeDeclaration]
    /// Scopes tried in order. An empty array matches no images.
    public let imageScopes: [ImageSelector]

    /// Describes a requirement without loading code.
    ///
    /// - Parameters:
    ///   - declaration: The preferred declaration, using a source-level or exact name.
    ///   - alternatives: Additional declarations for the same symbol.
    ///   - fallbacks: Ordered candidates resolved lazily after primary/alias absence.
    ///   - imageScopes: Ordered scopes; defaults to all loaded images.
    public init(
        _ declaration: NativeDeclaration,
        alternatives: [NativeDeclaration] = [],
        fallbacks: [NativeDeclaration] = [],
        in imageScopes: [ImageSelector] = [.automatic]
    ) {
        self.declaration = declaration
        self.alternatives = alternatives
        self.fallbacks = fallbacks
        self.imageScopes = imageScopes
    }
}
