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

#ifdef __cplusplus
}
#endif
#endif
