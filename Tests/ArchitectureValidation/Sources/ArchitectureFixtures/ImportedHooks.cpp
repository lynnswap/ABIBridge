#include "ArchitectureFixtures.h"
#include <ABIBridge/ImportedHooks.hpp>
#include <unistd.h>
#include <dlfcn.h>
#include <ptrauth.h>

static uid_t (*volatile uidSlot)() = getuid;
uint32_t ABIImportedUIDCall() { return uidSlot(); }
const char *ABIValidateImportedHookFrontend(const char *importer,uint32_t expected) {
    static thread_local std::string failure;
    try {
        abi_bridge::Runtime runtime;
        auto hook=abi_bridge::hook_imported_function<uint32_t()>(runtime,{"getuid",abi_bridge::language::c},
            abi_bridge::image_selector::path(importer),[](auto& call) { return call.proceed()+2; },
            [](const abi_bridge::resolution_error&) noexcept {});
        if(ABIImportedUIDCall()!=expected+2) return "Native imported callback chain failed";
        hook.invalidate();
        if(ABIImportedUIDCall()!=expected) return "Native imported callback invalidation failed";
        return nullptr;
    } catch(const std::exception& error) { failure=error.what(); return failure.c_str(); }
}
