#include <ABIBridge/SwiftDemangling.h>
#include <ABIBridge/SwiftInvocation.h>
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

struct ABISwiftTypeName { const char *data; uintptr_t length; };
extern "C" ABISwiftTypeName __attribute__((swiftcall)) swift_getMangledTypeName(const void *);

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

namespace {
NodePointer copyTypeNode(NodeFactory &factory, NodePointer source) {
    auto result = source->hasText() ? factory.createNode(source->getKind(), source->getText())
        : source->hasIndex() ? factory.createNode(source->getKind(), source->getIndex())
        : factory.createNode(source->getKind());
    for (auto child : *source) result->addChild(copyTypeNode(factory, child), factory);
    return result;
}
NodePointer unwrappedType(NodePointer node) {
    while (node->getKind() == Node::Kind::Type) node = node->getFirstChild();
    return node;
}
NodePointer typedNode(NodeFactory &factory, NodePointer node) {
    auto type = factory.createNode(Node::Kind::Type);
    type->addChild(unwrappedType(node), factory);
    return type;
}
}

ABISwiftSyntax *ABICopySwiftSubstitutedTypeSyntax(const ABISwiftSyntaxNode *node,
    const ABISwiftSyntaxNode *const *arguments, size_t count) {
    auto syntax = std::make_unique<ABISwiftSyntax>();
    auto &factory = syntax->demangler;
    auto copy = [&](auto &&copy, NodePointer source) -> NodePointer {
        if (source->getKind() == Node::Kind::DependentGenericParamType
            && source->getChild(0)->getIndex() == 0 && source->getChild(1)->getIndex() < count) {
            return copyTypeNode(factory, unwrappedType(nativeNode(arguments[source->getChild(1)->getIndex()])));
        }
        auto result = source->hasText() ? factory.createNode(source->getKind(), source->getText())
            : source->hasIndex() ? factory.createNode(source->getKind(), source->getIndex())
            : factory.createNode(source->getKind());
        for (auto child : *source) result->addChild(copy(copy, child), factory);
        return result;
    };
    syntax->root = copy(copy, nativeNode(node));
    return syntax.release();
}

ABISwiftSyntax *ABICopySwiftContainerTypeSyntax(uint32_t kind,
    const ABISwiftSyntaxNode *const *elements, size_t count, const char *const *labels) {
    auto syntax = std::make_unique<ABISwiftSyntax>();
    auto &factory = syntax->demangler;
    NodePointer value;
    if (kind == 0x301) {
        value = factory.createNode(Node::Kind::Tuple);
        for (size_t index = 0; index < count; ++index) {
            auto element = factory.createNode(Node::Kind::TupleElement);
            if (labels && labels[index] && labels[index][0])
                element->addChild(factory.createNode(Node::Kind::TupleElementName, labels[index]), factory);
            element->addChild(typedNode(factory, copyTypeNode(factory, nativeNode(elements[index]))), factory);
            value->addChild(element, factory);
        }
    } else if (count == 1 && (kind == 0x304 || kind == 0x306)) {
        value = factory.createNode(kind == 0x304 ? Node::Kind::Metatype : Node::Kind::ExistentialMetatype);
        value->addChild(typedNode(factory, copyTypeNode(factory, nativeNode(elements[0]))), factory);
    } else if (count == 1 && kind == 0x202) {
        auto nominal = factory.createNode(Node::Kind::Enum);
        nominal->addChild(factory.createNode(Node::Kind::Module, "Swift"), factory);
        nominal->addChild(factory.createNode(Node::Kind::Identifier, "Optional"), factory);
        auto arguments = factory.createNode(Node::Kind::TypeList);
        arguments->addChild(typedNode(factory, copyTypeNode(factory, nativeNode(elements[0]))), factory);
        value = factory.createNode(Node::Kind::BoundGenericEnum);
        value->addChild(typedNode(factory, nominal), factory);
        value->addChild(arguments, factory);
    } else return nullptr;
    syntax->root = typedNode(factory, value);
    return syntax.release();
}

ABISwiftSyntax *ABICopySwiftFunctionTypeSyntax(uintptr_t flags, uint32_t extended,
    const ABISwiftSyntaxNode *const *parameters, const uint32_t *parameterFlags,
    const ABISwiftSyntaxNode *result, const ABISwiftSyntaxNode *failure,
    const ABISwiftSyntaxNode *globalActor, uintptr_t differentiability) {
    auto syntax = std::make_unique<ABISwiftSyntax>();
    auto &factory = syntax->demangler;
    const size_t count = flags & 0xffff;
    Node::Kind kind;
    switch ((flags >> 16) & 0xff) {
    case 0: kind = flags & 0x04000000 ? Node::Kind::FunctionType : Node::Kind::NoEscapeFunctionType; break;
    case 1: kind = Node::Kind::ObjCBlock; break;
    case 2: kind = Node::Kind::ThinFunctionType; break;
    case 3: kind = Node::Kind::CFunctionPointer; break;
    default: return nullptr;
    }
    auto tuple = factory.createNode(Node::Kind::Tuple);
    NodePointer single = nullptr;
    for (size_t index = 0; index < count; ++index) {
        auto input = unwrappedType(copyTypeNode(factory, nativeNode(parameters[index])));
        const uint32_t parameter = parameterFlags[index];
        auto wrap = [&](Node::Kind kind) {
            auto parent = factory.createNode(kind);
            parent->addChild(input, factory);
            input = parent;
        };
        if (parameter & 0x200) wrap(Node::Kind::NoDerivative);
        switch (parameter & 7) {
        case 0: break;
        case 1: wrap(Node::Kind::InOut); break;
        case 2: wrap(Node::Kind::Shared); break;
        case 3: wrap(Node::Kind::Owned); break;
        default: return nullptr;
        }
        if (parameter & 0x400) wrap(Node::Kind::Isolated);
        if (parameter & 0x800) wrap(Node::Kind::Sending);
        if (count == 1 && !(parameter & 0x80) && input->getKind() != Node::Kind::Tuple) single = input;
        auto element = factory.createNode(Node::Kind::TupleElement);
        if (parameter & 0x80) element->addChild(factory.createNode(Node::Kind::VariadicMarker), factory);
        element->addChild(typedNode(factory, input), factory);
        tuple->addChild(element, factory);
    }
    auto function = factory.createNode(kind);
    if (extended & 0x10) function->addChild(factory.createNode(Node::Kind::SendingResultFunctionType), factory);
    if (globalActor) {
        auto actor = factory.createNode(Node::Kind::GlobalActorFunctionType);
        actor->addChild(copyTypeNode(factory, nativeNode(globalActor)), factory);
        function->addChild(actor, factory);
    } else if ((extended & 0x0e) == 2) {
        function->addChild(factory.createNode(Node::Kind::IsolatedAnyFunctionType), factory);
    } else if ((extended & 0x0e) == 4) {
        function->addChild(factory.createNode(Node::Kind::NonIsolatedCallerFunctionType), factory);
    }
    if (differentiability) {
        if (differentiability > 4) return nullptr;
        const uint64_t kinds[] = {0, 'f', 'r', 'd', 'l'};
        function->addChild(factory.createNode(Node::Kind::DifferentiableFunctionType, kinds[differentiability]), factory);
    }
    if (flags & 0x01000000) {
        auto throwing = factory.createNode(failure ? Node::Kind::TypedThrowsAnnotation : Node::Kind::ThrowsAnnotation);
        if (failure) throwing->addChild(copyTypeNode(factory, nativeNode(failure)), factory);
        function->addChild(throwing, factory);
    }
    if (flags & 0x40000000) function->addChild(factory.createNode(Node::Kind::ConcurrentFunctionType), factory);
    if (flags & 0x20000000) function->addChild(factory.createNode(Node::Kind::AsyncAnnotation), factory);
    auto inputs = factory.createNode(Node::Kind::ArgumentTuple);
    inputs->addChild(typedNode(factory, single ? single : tuple), factory);
    function->addChild(inputs, factory);
    auto output = factory.createNode(Node::Kind::ReturnType);
    output->addChild(typedNode(factory, copyTypeNode(factory, nativeNode(result))), factory);
    function->addChild(output, factory);
    syntax->root = typedNode(factory, function);
    return syntax.release();
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
        if (node->getKind() == Node::Kind::DependentGenericParamType)
            return factory.createNode(Node::Kind::ConstrainedExistentialSelf);
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
    size_t index = 0;
    auto parameterType = [&]() {
        auto type = factory.createNode(Node::Kind::Type);
        auto parameter = factory.createNode(Node::Kind::DependentGenericParamType);
        parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(0)), factory);
        parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(index++)), factory);
        type->addChild(parameter, factory);
        return type;
    };
    auto generalize = [&](auto &&copy, NodePointer node, bool superclass) -> NodePointer {
        NodePointer result = node->hasText() ? factory.createNode(node->getKind(), node->getText())
            : node->hasIndex() ? factory.createNode(node->getKind(), node->getIndex())
            : factory.createNode(node->getKind());
        for (size_t child = 0; child < node->getNumChildren(); ++child) {
            if (superclass && node->getKind() == Node::Kind::TypeList)
                result->addChild(parameterType(), factory);
            else result->addChild(copy(copy, node->getChild(child), superclass
                || (node->getKind() == Node::Kind::ProtocolListWithClass && child == 1)), factory);
        }
        return result;
    };
    auto existential = factory.createNode(Node::Kind::ConstrainedExistential);
    existential->addChild(generalize(generalize, source->getChild(0), false), factory);
    auto requirements = factory.createNode(Node::Kind::ConstrainedExistentialRequirementList);
    for (auto requirement : *source->getChild(1)) {
        if (requirement->getKind() != Node::Kind::DependentGenericSameTypeRequirement
            || requirement->getNumChildren() != 2) return nullptr;
        auto replacement = factory.createNode(requirement->getKind());
        replacement->addChild(copySubject(copySubject, requirement->getChild(0)), factory);
        replacement->addChild(parameterType(), factory);
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
    size_t constraintCount, bool classBound, const void *superclass) {
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
        auto result = mangleNode(node, [&](SymbolicReferenceKind kind, const void *address) -> NodePointer {
            if (kind != SymbolicReferenceKind::Context) return nullptr;
            uint32_t flags;
            std::memcpy(&flags, address, sizeof(flags));
            if ((flags & 0x1f) != 3) return nullptr;
            auto name = swift_getMangledTypeName(ABISwiftProtocolTypeMetadata(address));
            return name.data ? protocolNode(std::string(name.data, name.length).c_str()) : nullptr;
        });
        if (!result.isSuccess()) return {};
        auto name = result.result();
        return name.compare(0, 2, "$s") == 0 ? name.substr(2) : name;
    };
    struct Requirement {
        uint32_t flags;
        std::string subject, constraint;
        const void *protocol = nullptr;
        uint32_t payload = 0;
    };
    std::vector<Requirement> generalization, required;
    size_t superclassParameters = 0;
    auto base = source->getChild(0);
    while (base->getKind() == Node::Kind::Type && base->getNumChildren() == 1) base = base->getChild(0);
    NodePointer superclassType = base->getKind() == Node::Kind::ProtocolListWithClass ? base->getChild(1) : nullptr;
    if (bool(superclassType) != bool(superclass)) return nullptr;
    if (superclass) {
        std::unique_ptr<ABISwiftTypeMetadata, decltype(&ABIReleaseSwiftTypeMetadata)> context(
            ABICopySwiftTypeMetadata(superclass, nullptr), ABIReleaseSwiftTypeMetadata);
        if (!context || !ABIPrepareSwiftTypeMetadataContext(context.get(), nullptr)) return nullptr;
        superclassParameters = ABISwiftTypeMetadataArgumentCount(context.get());
        std::vector<std::string> references;
        for (size_t index = 0; index < superclassParameters; ++index) {
            if (ABISwiftTypeMetadataArgumentIsPack(context.get(), index)) return nullptr;
            std::string name = ABISwiftTypeMetadataParameterReference(context.get(), index);
            references.push_back(name.compare(0, 2, "$s") == 0 ? name.substr(2) : name);
        }
        auto substitute = [&](auto &&copy, NodePointer node) -> NodePointer {
            if (node->getKind() == Node::Kind::DependentGenericParamType) {
                auto name = spelling(node);
                auto found = std::find(references.begin(), references.end(), name);
                if (found == references.end()) return nullptr;
                auto parameter = factory.createNode(Node::Kind::DependentGenericParamType);
                parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(0)), factory);
                parameter->addChild(factory.createNode(Node::Kind::Index, uint64_t(found - references.begin())), factory);
                return parameter;
            }
            NodePointer result = node->hasText() ? factory.createNode(node->getKind(), node->getText())
                : node->hasIndex() ? factory.createNode(node->getKind(), node->getIndex())
                : factory.createNode(node->getKind());
            for (auto child : *node) {
                auto replacement = copy(copy, child);
                if (!replacement) return nullptr;
                result->addChild(replacement, factory);
            }
            return result;
        };
        // ExistentialGeneralization.cpp carries conformance substitutions from
        // the nominal context, but gives every written type argument a fresh
        // key parameter. Nominal same-type constraints do not merge these keys.
        for (size_t index = 0; index < ABISwiftTypeMetadataRequirementCount(context.get()); ++index) {
            auto address = static_cast<const char *>(ABISwiftTypeMetadataRequirement(context.get(), index));
            uint32_t flags;
            std::memcpy(&flags, address, sizeof(flags));
            const auto kind = flags & 0x1f;
            if (kind != 0 && kind != 5) continue;
            std::unique_ptr<ABISwiftSyntax, decltype(&ABIReleaseSwiftSyntax)> syntax(
                ABICopySwiftGenericRequirementTypeSyntax(address, false), ABIReleaseSwiftSyntax);
            if (!syntax) return nullptr;
            auto transformed = substitute(substitute, syntax->root);
            auto name = transformed ? spelling(transformed) : std::string();
            if (name.empty()) return nullptr;
            Requirement requirement{flags, name, {}};
            if (kind == 0) {
                requirement.protocol = ABISwiftProtocolRequirementDescriptor(address + 8);
                if (!requirement.protocol) return nullptr;
                required.push_back(requirement);
            } else std::memcpy(&requirement.payload, address + 8, sizeof(requirement.payload));
            generalization.push_back(std::move(requirement));
        }
    }
    auto existential = factory.createNode(Node::Kind::ConstrainedExistential);
    existential->addChild(source->getChild(0), factory);
    auto requirements = factory.createNode(Node::Kind::ConstrainedExistentialRequirementList);
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
        required.push_back({1, spelling(original->getChild(1)),
            spelling(subject(subject, original->getChild(0), declaring, true))});
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
    if (superclassType) required.push_back({2, "qd__", spelling(superclassType)});
    for (size_t index = 0; index < protocolCount; ++index)
        required.push_back({0x80, "qd__", {}, protocols[index]});
    const size_t parameterCount = superclassParameters + constraintCount;
    const size_t generalizationKeys = parameterCount + std::count_if(generalization.begin(), generalization.end(),
        [](const Requirement &requirement) { return requirement.flags & 0x80; });
    const size_t requirementKeys = parameterCount + 1 + std::count_if(required.begin(), required.end(),
        [](const Requirement &requirement) { return requirement.flags & 0x80; });
    if (requirementKeys > UINT16_MAX || generalizationKeys > UINT16_MAX
        || required.size() > UINT16_MAX || generalization.size() > UINT16_MAX) return nullptr;
    const size_t requirementCount = required.size();
    required.insert(required.end(), generalization.begin(), generalization.end());
    const size_t records = 28 + (metatypeDepth ? 4 : 0);
    size_t size = records + required.size() * 12;
    size_t protocolSlots = 0;
    for (const auto &requirement : required) {
        if (requirement.subject.empty()) return nullptr;
        size += requirement.subject.size() + 1;
        if ((requirement.flags & 0x1f) == 1 || (requirement.flags & 0x1f) == 2) {
            if (requirement.constraint.empty()) return nullptr;
            size += requirement.constraint.size() + 1;
        }
        protocolSlots += bool(requirement.protocol);
    }
    size += typeName.size() + 1;
    if (metatypeDepth) size += typeExpression.size() + 1;
    size = (size + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
    const size_t slots = size;
    size += (protocolSlots + 1) * sizeof(void *);
    auto memory = static_cast<char *>(std::calloc(1, size));
    auto put = [&](size_t at, auto value) { std::memcpy(memory + at, &value, sizeof(value)); };
    auto relative = [&](size_t at, size_t target, int tag = 0) {
        put(at, int32_t(target - at) | tag);
    };
    size_t cursor = records + required.size() * 12;
    auto string = [&](const std::string &text) {
        const size_t start = cursor;
        std::memcpy(memory + cursor, text.c_str(), text.size() + 1);
        cursor += text.size() + 1;
        return start;
    };
    relative(0, slots);
    put(4, uint32_t(0x1900 | (metatypeDepth ? 0x202 : classBound ? 1 : 0)));
    relative(8, string(typeName));
    put(12, uint16_t(parameterCount + 1));
    put(14, uint16_t(requirementCount));
    put(16, uint16_t(requirementKeys));
    put(20, uint16_t(parameterCount));
    put(22, uint16_t(generalization.size()));
    put(24, uint16_t(generalizationKeys));
    if (metatypeDepth) relative(28, string(typeExpression));
    size_t nextSlot = slots + sizeof(void *);
    for (size_t index = 0; index < required.size(); ++index) {
        const size_t entry = records + index * 12;
        const auto &requirement = required[index];
        put(entry, requirement.flags);
        relative(entry + 4, string(requirement.subject));
        if (requirement.protocol) {
            const size_t slot = nextSlot;
            nextSlot += sizeof(void *);
            relative(entry + 8, slot, 1);
            const void *protocol = requirement.protocol;
#if __has_feature(ptrauth_calls)
            protocol = ptrauth_sign_unauthenticated(protocol, ptrauth_key_process_independent_data,
                ptrauth_blend_discriminator(memory + slot, 0xae86));
#endif
            put(slot, protocol);
        } else if (!requirement.constraint.empty()) relative(entry + 8, string(requirement.constraint));
        else put(entry + 8, requirement.payload);
    }
    return memory;
}

void ABIReleaseSwiftExtendedExistentialShape(void *shape) { std::free(shape); }
