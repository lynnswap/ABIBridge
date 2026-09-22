#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>

namespace abi_bridge {

enum class language : std::uint8_t {
    swift,
    objective_c,
    c,
    cxx,
};

enum class symbol_kind : std::uint8_t {
    function,
    data,
    vtable,
};

enum class ownership : std::uint8_t {
    borrowed,
    owned,
    unowned,
    custom,
};

struct image_identity final {
    std::uint64_t header_address = 0;
    std::int64_t slide = 0;
    std::uint64_t load_generation = 0;

    friend constexpr bool operator==(const image_identity&, const image_identity&) = default;
};

struct declaration final {
    std::string name;
    language source_language = language::cxx;
    symbol_kind kind = symbol_kind::function;

    declaration() = default;
    declaration(std::string name, language source_language = language::cxx,
                symbol_kind kind = symbol_kind::function)
        : name(std::move(name)), source_language(source_language), kind(kind) {}
};

struct call_plan final {
    language source_language = language::cxx;
    ownership result_ownership = ownership::borrowed;
    bool has_receiver = false;
    bool has_indirect_result = false;
};

/// Stable package identity used by native consumers and fixture checks.
inline constexpr std::string_view package_name = "ABIBridgeCore";

} // namespace abi_bridge

#include <ABIBridge/Runtime.hpp>
