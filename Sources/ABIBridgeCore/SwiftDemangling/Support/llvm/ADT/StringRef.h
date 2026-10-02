#pragma once

#include <algorithm>
#include <cassert>
#include <cstring>
#include <functional>
#include <string>
#include <string_view>

// The vendored demangler only needs these StringRef operations. Keep its
// parser unchanged while using the C++ standard library instead of libLLVM.
namespace llvm {
class StringRef : public std::string_view {
public:
    using std::string_view::string_view;
    constexpr StringRef() = default;
    constexpr StringRef(std::string_view value) : std::string_view(value) {}
    StringRef(const std::string &value) : std::string_view(value) {}

    std::string str() const { return std::string(*this); }
    constexpr StringRef substr(size_t start, size_t count = npos) const {
        return std::string_view::substr(std::min(start, size()), count);
    }
    constexpr StringRef slice(size_t start, size_t end) const {
        assert(start <= end);
        return substr(start, end - start);
    }
    constexpr StringRef drop_front(size_t count = 1) const { return substr(count); }
    constexpr StringRef drop_back(size_t count = 1) const {
        assert(count <= size());
        return substr(0, size() - count);
    }
    constexpr StringRef take_back(size_t count = 1) const {
        return substr(size() - std::min(size(), count));
    }
    bool consume_front(StringRef prefix) {
        if (!starts_with(prefix)) return false;
        remove_prefix(prefix.size());
        return true;
    }
    template<class Predicate> StringRef drop_while(Predicate predicate) const {
        size_t count = 0;
        while (count < size() && predicate((*this)[count])) ++count;
        return drop_front(count);
    }
    template<class Allocator> StringRef copy(Allocator &allocator) const {
        if (empty()) return {};
        char *memory = allocator.template Allocate<char>(size());
        std::memcpy(memory, data(), size());
        return {memory, size()};
    }
};
using StringLiteral = StringRef;
template<class Signature> using function_ref = std::function<Signature>;
}
