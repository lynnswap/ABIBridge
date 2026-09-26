#pragma once

#include <cstdint>
#include <string_view>
#include <ABIBridge/Inspection.hpp>

namespace abi_bridge {

enum class ownership : std::uint8_t {
    borrowed,
    owned,
    unowned,
    custom,
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

#include <ABIBridge/ObjectiveCHooks.hpp>
