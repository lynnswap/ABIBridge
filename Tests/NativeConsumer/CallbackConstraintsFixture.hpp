#pragma once
#include <ABIBridge/ObjectiveCHooks.hpp>
#include <ABIBridge/ImportedHookMonitoring.hpp>
#include <ABIBridge/VirtualHooks.hpp>

// Stored callbacks are lvalues even when their owners were constructed from temporaries.
struct LvalueFailureHandler {
    void operator()(const abi_bridge::resolution_error&) & noexcept {}
};
struct LvalueImageHandler {
    void operator()(const abi_bridge::imported_image_update&) & noexcept {}
};

// Instantiating these public templates must accept the same stored-lvalue handler.
// This function is a compile contract; no registrations are installed by the fixture.
inline void compileStoredCallbackHandlers(
    const abi_bridge::runtime& runtime, const abi_bridge::declaration& declaration,
    const abi_bridge::image_selector& scope, const abi_bridge::virtual_entry& entry, Class type) {
    auto body = [](auto& call, int value) { return call.proceed(value); };
    auto objc = abi_bridge::hook_objc_method<int(int)>(type, "value:", body, LvalueFailureHandler{});
    auto imported = abi_bridge::hook_imported_function<int(int)>(runtime, declaration, scope, body, LvalueFailureHandler{});
    auto virtualHook = entry.hook_shared_calls<int(int)>(body, LvalueFailureHandler{});
    auto monitor = abi_bridge::monitor_imported_function<int(int)>(
        declaration, scope, body, LvalueFailureHandler{}, LvalueImageHandler{});
}
