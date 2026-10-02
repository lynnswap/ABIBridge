#include <ABIBridge/SwiftDemangling.h>
#include <ptrauth.h>
#include <cstring>
#include <memory>
#include <sstream>

// Keep the upstream parser/remangler unchanged and isolate both its Swift
// symbols and its small standard-library replacements from other LLVM clients.
#define SWIFT_INLINE_NAMESPACE ABIBridgeDemangling
#define llvm ABIBridgeDemanglingSupport
#define SWIFT_RUNTIME 1
#ifndef NDEBUG
#define NDEBUG 1
#endif
#pragma GCC visibility push(hidden)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include "SwiftDemangling/Upstream/lib/Demangling/Demangler.cpp"
#include "SwiftDemangling/Upstream/lib/Demangling/Punycode.cpp"
#include "SwiftDemangling/Upstream/lib/Demangling/ManglingUtils.cpp"
#include "SwiftDemangling/Upstream/lib/Demangling/Remangler.cpp"
#pragma clang diagnostic pop

namespace {
using namespace swift::Demangle;

const char *nodeKind(Node::Kind kind) {
    switch (kind) {
#define NODE(ID) case Node::Kind::ID: return #ID;
#include "swift/Demangling/DemangleNodes.def"
    }
    return "Unknown";
}

void describeNode(NodePointer node, std::ostream &stream, size_t depth = 0) {
    if (!node) return;
    stream << std::string(depth, ' ') << nodeKind(node->getKind());
    if (node->hasText()) stream << "=" << node->getText().str();
    if (node->hasIndex()) stream << "=" << node->getIndex();
    stream << "\n";
    for (auto child : *node) describeNode(child, stream, depth + 1);
}
}

// These are only upstream allocation/invariant diagnostics. Parse failures
// return null; they do not enter the diagnostic or termination path.
void swift::Demangle::Node::dump() {
    auto text = getNodeTreeAsString(this);
    std::fputs(text.c_str(), stderr);
}
std::string swift::Demangle::getNodeTreeAsString(NodePointer node) {
    std::ostringstream stream;
    describeNode(node, stream);
    return stream.str();
}
void swift::Demangle::fatal(uint32_t, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    std::vfprintf(stderr, format, arguments);
    va_end(arguments);
    std::abort();
}
#pragma GCC visibility pop
#undef llvm

struct ABISwiftSyntax {
    swift::Demangle::Demangler demangler;
    swift::Demangle::NodePointer root = nullptr;
};

namespace {
using namespace swift::Demangle;

NodePointer nativeNode(const ABISwiftSyntaxNode *node) {
    return reinterpret_cast<NodePointer>(const_cast<ABISwiftSyntaxNode *>(node));
}

NodePointer symbolicReference(Demangler &demangler, SymbolicReferenceKind kind,
                              Directness directness, int32_t offset, const void *base) {
    uintptr_t address = reinterpret_cast<uintptr_t>(base) + offset;
    if (directness == Directness::Indirect) {
        if (kind != SymbolicReferenceKind::Context) return nullptr;
        const void *slot = reinterpret_cast<const void *>(address);
        const void *pointer;
        std::memcpy(&pointer, slot, sizeof(pointer));
#if __has_feature(ptrauth_calls)
        if (pointer) pointer = ptrauth_auth_data(pointer, ptrauth_key_process_independent_data,
                                               ptrauth_blend_discriminator(slot, 0xae86));
#endif
        address = reinterpret_cast<uintptr_t>(pointer);
    }
    if (!address) return nullptr;
    Node::Kind nodeKind;
    bool isType = false;
    switch (kind) {
    case SymbolicReferenceKind::Context: {
        uint32_t flags;
        std::memcpy(&flags, reinterpret_cast<const void *>(address), sizeof(flags));
        auto contextKind = flags & 0x1f;
        if (contextKind == 3) nodeKind = Node::Kind::ProtocolSymbolicReference;
        else if (contextKind == 4) nodeKind = Node::Kind::OpaqueTypeDescriptorSymbolicReference;
        else if (contextKind >= 16) {
            nodeKind = Node::Kind::TypeSymbolicReference;
            isType = true;
        } else return nullptr;
        break;
    }
    case SymbolicReferenceKind::ObjectiveCProtocol:
        nodeKind = Node::Kind::ObjectiveCProtocolSymbolicReference;
        break;
    default:
        return nullptr;
    }
    auto node = demangler.createNode(nodeKind, static_cast<uint64_t>(address));
    if (!isType) return node;
    auto type = demangler.createNode(Node::Kind::Type);
    type->addChild(node, demangler);
    return type;
}
}

ABISwiftSyntax *ABICopySwiftSymbolSyntax(const char *name, size_t length) {
    auto syntax = std::make_unique<ABISwiftSyntax>();
    syntax->root = syntax->demangler.demangleSymbol({name, length});
    return syntax->root ? syntax.release() : nullptr;
}

ABISwiftSyntax *ABICopySwiftTypeSyntax(const char *name, size_t length) {
    auto syntax = std::make_unique<ABISwiftSyntax>();
    syntax->root = syntax->demangler.demangleType({name, length},
        [&](auto kind, auto directness, auto offset, auto base) {
            return symbolicReference(syntax->demangler, kind, directness, offset, base);
        });
    return syntax->root ? syntax.release() : nullptr;
}

void ABIReleaseSwiftSyntax(ABISwiftSyntax *syntax) { delete syntax; }
const ABISwiftSyntaxNode *ABISwiftSyntaxRoot(const ABISwiftSyntax *syntax) {
    return reinterpret_cast<const ABISwiftSyntaxNode *>(syntax->root);
}
const char *ABISwiftSyntaxNodeKind(const ABISwiftSyntaxNode *node) {
    return nodeKind(nativeNode(node)->getKind());
}
size_t ABISwiftSyntaxNodeChildCount(const ABISwiftSyntaxNode *node) { return nativeNode(node)->getNumChildren(); }
const ABISwiftSyntaxNode *ABISwiftSyntaxNodeChild(const ABISwiftSyntaxNode *node, size_t index) {
    return reinterpret_cast<const ABISwiftSyntaxNode *>(nativeNode(node)->getChild(index));
}
const char *ABISwiftSyntaxNodeText(const ABISwiftSyntaxNode *node, size_t *length) {
    if (!nativeNode(node)->hasText()) { *length = 0; return nullptr; }
    auto text = nativeNode(node)->getText();
    *length = text.size();
    return text.data();
}
bool ABISwiftSyntaxNodeHasIndex(const ABISwiftSyntaxNode *node) { return nativeNode(node)->hasIndex(); }
uint64_t ABISwiftSyntaxNodeIndex(const ABISwiftSyntaxNode *node) { return nativeNode(node)->getIndex(); }
char *ABICopySwiftSyntaxNodeMangledName(const ABISwiftSyntaxNode *node) {
    auto result = swift::Demangle::mangleNode(nativeNode(node));
    return result.isSuccess() ? strdup(result.result().c_str()) : nullptr;
}
