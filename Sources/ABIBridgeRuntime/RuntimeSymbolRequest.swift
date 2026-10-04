import Foundation

package struct RuntimeSymbolRequest: Sendable, Hashable {
    package let declaration: RuntimeDeclaration
    package let alternatives: [RuntimeDeclaration]
    package let fallbacks: [RuntimeDeclaration]
    package let imageScopes: [RuntimeImageSelector]
    package let loading: RuntimeImageLoadingPolicy

    package init(
        _ declaration: RuntimeDeclaration,
        alternatives: [RuntimeDeclaration] = [],
        fallbacks: [RuntimeDeclaration] = [],
        in imageScopes: [RuntimeImageSelector] = [.automatic],
        loading: RuntimeImageLoadingPolicy = .ifNeeded
    ) {
        self.declaration = declaration
        self.alternatives = alternatives
        self.fallbacks = fallbacks
        self.imageScopes = imageScopes
        self.loading = loading
    }
}
