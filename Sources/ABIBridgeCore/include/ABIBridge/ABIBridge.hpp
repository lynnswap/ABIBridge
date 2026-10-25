#pragma once

#include <cstdint>
#include <string_view>
#include <ABIBridge/Inspection.hpp>

namespace abi_bridge {

/// Stable package identity used by native consumers and fixture checks.
inline constexpr std::string_view package_name = "ABIBridgeCore";

} // namespace abi_bridge

#include <ABIBridge/NativeInvocation.hpp>

#include <ABIBridge/ObjectiveCHooks.hpp>
#include <ABIBridge/ImportedHooks.hpp>
#include <ABIBridge/ImportedHookMonitoring.hpp>

#include <ABIBridge/VirtualHooks.hpp>
