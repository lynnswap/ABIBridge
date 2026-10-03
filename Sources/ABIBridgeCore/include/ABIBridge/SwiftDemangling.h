#ifndef ABIBRIDGE_SWIFT_DEMANGLING_H
#define ABIBRIDGE_SWIFT_DEMANGLING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftSyntax ABISwiftSyntax;
typedef struct ABISwiftSyntaxNode ABISwiftSyntaxNode;

/// Parses a modern Swift symbol. Nodes borrow the returned syntax object's
/// storage. Invalid or unsupported input returns null.
ABISwiftSyntax *ABICopySwiftSymbolSyntax(const char *name, size_t length);
/// Parses a compiler-emitted type reference at its original address, resolving
/// relative symbolic references before the original bytes leave scope.
ABISwiftSyntax *ABICopySwiftTypeSyntax(const char *name, size_t length);
void ABIReleaseSwiftSyntax(ABISwiftSyntax *syntax);
const ABISwiftSyntaxNode *ABISwiftSyntaxRoot(const ABISwiftSyntax *syntax);
const char *ABISwiftSyntaxNodeKind(const ABISwiftSyntaxNode *node);
size_t ABISwiftSyntaxNodeChildCount(const ABISwiftSyntaxNode *node);
const ABISwiftSyntaxNode *ABISwiftSyntaxNodeChild(const ABISwiftSyntaxNode *node, size_t index);
const char *ABISwiftSyntaxNodeText(const ABISwiftSyntaxNode *node, size_t *length);
bool ABISwiftSyntaxNodeHasIndex(const ABISwiftSyntaxNode *node);
uint64_t ABISwiftSyntaxNodeIndex(const ABISwiftSyntaxNode *node);
/// Remangles a subtree without symbolic references. Release with ABIFreeString.
char *ABICopySwiftSyntaxNodeMangledName(const ABISwiftSyntaxNode *node);
/// Copies a type tree, substituting its depth-zero generalization parameters.
ABISwiftSyntax *ABICopySwiftSubstitutedTypeSyntax(const ABISwiftSyntaxNode *node,
    const ABISwiftSyntaxNode *const *arguments, size_t count);
/// Copies tuple, Optional, or metatype components into a type tree.
ABISwiftSyntax *ABICopySwiftContainerTypeSyntax(uint32_t metadataKind,
    const ABISwiftSyntaxNode *const *elements, size_t count, const char *const *labels);
/// Describes function metadata without imposing callable preparation rules.
ABISwiftSyntax *ABICopySwiftFunctionTypeSyntax(uintptr_t flags, uint32_t extendedFlags,
    const ABISwiftSyntaxNode *const *parameters, const uint32_t *parameterFlags,
    const ABISwiftSyntaxNode *result, const ABISwiftSyntaxNode *failure,
    const ABISwiftSyntaxNode *globalActor, uintptr_t differentiability);
/// The compiler's uniquable shape symbol for a parameterized protocol value.
/// Same-type constraints become generalization arguments in requirement order.
char *ABICopySwiftConstrainedExistentialShapeName(const ABISwiftSyntaxNode *node, size_t metatypeDepth);
/// Builds an unpublished parameterized-protocol shape. The caller keeps its
/// storage and referenced protocol images alive after publishing it to Swift.
void *ABICreateSwiftExtendedExistentialShape(const ABISwiftSyntaxNode *node,
    const void *const *protocols, size_t protocolCount,
    const char *const *writtenProtocols, const char *const *declaringProtocols,
    size_t constraintCount, bool classBound);
void ABIReleaseSwiftExtendedExistentialShape(void *shape);

#ifdef __cplusplus
}
#endif
#endif
