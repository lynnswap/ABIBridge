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

char *ABICopySwiftConstrainedExistentialShapeName(const ABISwiftSyntaxNode *node, size_t metatypeDepth) {
    using namespace swift::Demangle;
    auto source = nativeNode(node);
    if (source->getKind() != Node::Kind::ConstrainedExistential || source->getNumChildren() != 2)
        return nullptr;
    NodeFactory factory;
    auto countProtocols = [&](auto &&visit, NodePointer node) -> size_t {
        if (node->getKind() == Node::Kind::ProtocolList)
            return node->getChild(0)->getNumChildren();
        for (auto child : *node) if (auto count = visit(visit, child)) return count;
        return 0;
    };
    const bool singleProtocol = countProtocols(countProtocols, source->getChild(0)) == 1;
    auto copySubject = [&](auto &&copy, NodePointer node) -> NodePointer {
        NodePointer result = node->hasText() ? factory.createNode(node->getKind(), node->getText())
            : node->hasIndex() ? factory.createNode(node->getKind(), node->getIndex())
            : factory.createNode(node->getKind());
        for (auto child : *node) {
            if (singleProtocol && node->getKind() == Node::Kind::DependentAssociatedTypeRef
                && child->getKind() != Node::Kind::Identifier) continue;
            result->addChild(copy(copy, child), factory);
        }
        return result;
    };
    auto existential = factory.createNode(Node::Kind::ConstrainedExistential);
    existential->addChild(source->getChild(0), factory);
    auto requirements = factory.createNode(Node::Kind::ConstrainedExistentialRequirementList);
    size_t index = 0;
    for (auto requirement : *source->getChild(1)) {
        if (requirement->getKind() != Node::Kind::DependentGenericSameTypeRequirement
            || requirement->getNumChildren() != 2) return nullptr;
        auto replacement = factory.createNode(requirement->getKind());
        replacement->addChild(copySubject(copySubject, requirement->getChild(0)), factory);
        auto type = factory.createNode(Node::Kind::Type);
        auto parameter = factory.createNode(Node::Kind::DependentGenericParamType);
        parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(0)), factory);
        parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(index++)), factory);
        type->addChild(parameter, factory);
        replacement->addChild(type, factory);
        requirements->addChild(replacement, factory);
    }
    existential->addChild(requirements, factory);
    auto signature = factory.createNode(Node::Kind::DependentGenericSignature);
    signature->addChild(factory.createNode(Node::Kind::DependentGenericParamCount, uint64_t(index)), factory);
    NodePointer generalized = existential;
    for (size_t index = 0; index < metatypeDepth; ++index) {
        auto instance = factory.createNode(Node::Kind::Type);
        instance->addChild(generalized, factory);
        generalized = factory.createNode(Node::Kind::ExistentialMetatype);
        generalized->addChild(instance, factory);
    }
    auto type = factory.createNode(Node::Kind::Type);
    type->addChild(generalized, factory);
    auto shape = factory.createNode(Node::Kind::ExtendedExistentialTypeShape);
    shape->addChild(signature, factory);
    shape->addChild(type, factory);
    auto uniquable = factory.createNode(Node::Kind::Uniquable);
    uniquable->addChild(shape, factory);
    auto global = factory.createNode(Node::Kind::Global);
    global->addChild(uniquable, factory);
    auto result = mangleNode(global);
    return result.isSuccess() ? strdup(result.result().c_str()) : nullptr;
}

void *ABICreateSwiftExtendedExistentialShape(const ABISwiftSyntaxNode *node,
    const void *const *protocols, size_t protocolCount,
    const char *const *writtenProtocols, const char *const *declaringProtocols,
    size_t constraintCount, bool classBound) {
    using namespace swift::Demangle;
    auto source = nativeNode(node);
    size_t metatypeDepth = 0;
    while (source->getKind() == Node::Kind::ExistentialMetatype) {
        if (source->getNumChildren() != 1 || source->getChild(0)->getKind() != Node::Kind::Type) return nullptr;
        source = source->getChild(0)->getChild(0);
        ++metatypeDepth;
    }
    if (source->getKind() != Node::Kind::ConstrainedExistential || source->getNumChildren() != 2
        || source->getChild(1)->getNumChildren() != constraintCount
        || constraintCount + protocolCount + 1 > UINT16_MAX) return nullptr;
    NodeFactory factory;
    std::vector<std::unique_ptr<Demangler>> parsers;
    auto protocolNode = [&](const char *name) -> NodePointer {
        auto parser = std::make_unique<Demangler>();
        auto root = parser->demangleType(name);
        auto find = [&](auto &&visit, NodePointer node) -> NodePointer {
            if (!node) return nullptr;
            if (node->getKind() == Node::Kind::Protocol) return node;
            for (auto child : *node) if (auto result = visit(visit, child)) return result;
            return nullptr;
        };
        auto result = find(find, root);
        parsers.push_back(std::move(parser));
        return result;
    };
    auto subject = [&](auto &&copy, NodePointer node, NodePointer protocol, bool requirement) -> NodePointer {
        if (node->getKind() == Node::Kind::ConstrainedExistentialSelf && requirement) {
            auto parameter = factory.createNode(Node::Kind::DependentGenericParamType);
            parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(1)), factory);
            parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(0)), factory);
            return parameter;
        }
        NodePointer result = node->hasText() ? factory.createNode(node->getKind(), node->getText())
            : node->hasIndex() ? factory.createNode(node->getKind(), node->getIndex())
            : factory.createNode(node->getKind());
        for (auto child : *node) {
            if (node->getKind() == Node::Kind::DependentAssociatedTypeRef
                && child->getKind() != Node::Kind::Identifier) continue;
            result->addChild(copy(copy, child, protocol, requirement), factory);
        }
        if (node->getKind() == Node::Kind::DependentAssociatedTypeRef) {
            auto type = factory.createNode(Node::Kind::Type);
            type->addChild(protocol, factory);
            result->addChild(type, factory);
        }
        return result;
    };
    auto spelling = [&](NodePointer node) -> std::string {
        auto result = mangleNode(node);
        if (!result.isSuccess()) return {};
        auto name = result.result();
        return name.compare(0, 2, "$s") == 0 ? name.substr(2) : name;
    };
    auto existential = factory.createNode(Node::Kind::ConstrainedExistential);
    existential->addChild(source->getChild(0), factory);
    auto requirements = factory.createNode(Node::Kind::ConstrainedExistentialRequirementList);
    std::vector<std::string> parameters, associatedTypes;
    for (size_t index = 0; index < constraintCount; ++index) {
        auto original = source->getChild(1)->getChild(index);
        auto written = protocolNode(writtenProtocols[index]);
        auto declaring = protocolNode(declaringProtocols[index]);
        if (!written || !declaring || original->getKind() != Node::Kind::DependentGenericSameTypeRequirement)
            return nullptr;
        auto constraint = factory.createNode(original->getKind());
        constraint->addChild(subject(subject, original->getChild(0), written, false), factory);
        constraint->addChild(original->getChild(1), factory);
        requirements->addChild(constraint, factory);
        parameters.push_back(spelling(original->getChild(1)));
        associatedTypes.push_back(spelling(subject(subject, original->getChild(0), declaring, true)));
    }
    existential->addChild(requirements, factory);
    NodePointer generalized = existential;
    auto head = factory.createNode(Node::Kind::DependentGenericParamType);
    head->addChild(factory.createNode(Node::Kind::Index, uint64_t(1)), factory);
    head->addChild(factory.createNode(Node::Kind::Index, uint64_t(0)), factory);
    for (size_t index = 0; index < metatypeDepth; ++index) {
        auto instance = factory.createNode(Node::Kind::Type);
        instance->addChild(generalized, factory);
        generalized = factory.createNode(Node::Kind::ExistentialMetatype);
        generalized->addChild(instance, factory);
        auto instanceHead = factory.createNode(Node::Kind::Type);
        instanceHead->addChild(head, factory);
        head = factory.createNode(Node::Kind::Metatype);
        head->addChild(instanceHead, factory);
    }
    const auto typeName = spelling(generalized);
    const auto typeExpression = metatypeDepth ? spelling(head) : std::string();
    if (typeName.empty()) return nullptr;
    const size_t requirementCount = constraintCount + protocolCount;
    const size_t records = 28 + (metatypeDepth ? 4 : 0);
    size_t size = records + requirementCount * 12;
    for (const auto &name : parameters) size += name.size() + 1;
    for (const auto &name : associatedTypes) size += name.size() + 1;
    size += typeName.size() + 1 + sizeof("qd__");
    if (metatypeDepth) size += typeExpression.size() + 1;
    size = (size + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
    const size_t slots = size;
    size += (protocolCount + 1) * sizeof(void *);
    auto memory = static_cast<char *>(std::calloc(1, size));
    auto put = [&](size_t at, auto value) { std::memcpy(memory + at, &value, sizeof(value)); };
    auto relative = [&](size_t at, size_t target, int tag = 0) {
        put(at, int32_t(target - at) | tag);
    };
    size_t cursor = records + requirementCount * 12;
    auto string = [&](const std::string &text) {
        const size_t start = cursor;
        std::memcpy(memory + cursor, text.c_str(), text.size() + 1);
        cursor += text.size() + 1;
        return start;
    };
    relative(0, slots);
    put(4, uint32_t(0x1900 | (metatypeDepth ? 0x202 : classBound ? 1 : 0)));
    relative(8, string(typeName));
    put(12, uint16_t(constraintCount + 1));
    put(14, uint16_t(requirementCount));
    put(16, uint16_t(constraintCount + 1 + protocolCount));
    put(20, uint16_t(constraintCount));
    put(24, uint16_t(constraintCount));
    if (metatypeDepth) relative(28, string(typeExpression));
    for (size_t index = 0; index < constraintCount; ++index) {
        const size_t entry = records + index * 12;
        put(entry, uint32_t(1));
        relative(entry + 4, string(parameters[index]));
        relative(entry + 8, string(associatedTypes[index]));
    }
    const size_t self = string("qd__");
    for (size_t index = 0; index < protocolCount; ++index) {
        const size_t entry = records + (constraintCount + index) * 12;
        const size_t slot = slots + (index + 1) * sizeof(void *);
        put(entry, uint32_t(0x80));
        relative(entry + 4, self);
        relative(entry + 8, slot, 1);
        const void *protocol = protocols[index];
#if __has_feature(ptrauth_calls)
        protocol = ptrauth_sign_unauthenticated(protocol, ptrauth_key_process_independent_data,
            ptrauth_blend_discriminator(memory + slot, 0xae86));
#endif
        put(slot, protocol);
    }
    return memory;
}

void ABIReleaseSwiftExtendedExistentialShape(void *shape) { std::free(shape); }
