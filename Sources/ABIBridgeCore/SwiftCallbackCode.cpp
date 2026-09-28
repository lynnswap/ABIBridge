#include "SwiftCallbackCode.hpp"
#include <mach/mach.h>
#include <mach/machine/vm_param.h>
#include <ptrauth.h>
#include <cstring>
#include <algorithm>
#include <mutex>
#include <vector>

extern "C" void ABISwiftCallbackCodePage(void);
extern "C" void ABISwiftCallbackAssembly(void);

namespace {
// The code and configuration have matching 32-byte strides on every target,
// including arm64_32. Only data is written; executable bytes come from __TEXT.
struct Configuration { uint64_t context, entry, discriminator, closure; };
static_assert(sizeof(Configuration) == 32);
constexpr size_t entryCount = PAGE_MAX_SIZE / sizeof(Configuration);
struct Page {
    vm_address_t base = 0;
    std::vector<size_t> free;
    ~Page() { if (base) vm_deallocate(mach_task_self(), base, PAGE_MAX_SIZE * 2); }
};
struct PageRegistry {
    std::mutex mutex;
    std::vector<std::weak_ptr<Page>> pages;
};
PageRegistry &pageRegistry() {
    // Callback owners may be destroyed by another translation unit's static
    // cleanup. Keep the registry alive independently of destruction order.
    static auto *registry = new PageRegistry;
    return *registry;
}

std::shared_ptr<Page> allocatePage(ABIResolutionFailure **error) {
    auto page = std::make_shared<Page>();
    auto status = vm_allocate(mach_task_self(), &page->base, PAGE_MAX_SIZE * 2, VM_FLAGS_ANYWHERE);
    if (status != KERN_SUCCESS) {
        if (error) *error = ABICreateResolutionFailure(ABIFailureOther, mach_error_string(status));
        return {};
    }
    auto code = page->base + PAGE_MAX_SIZE;
    auto source = reinterpret_cast<void *>(&ABISwiftCallbackCodePage);
#if __has_feature(ptrauth_calls)
    source = ptrauth_auth_data(source, ptrauth_key_function_pointer,
        ptrauth_function_pointer_type_discriminator(void(void)));
#endif
    vm_prot_t current = 0, maximum = 0;
    status = vm_remap(mach_task_self(), &code, PAGE_MAX_SIZE, 0, VM_FLAGS_OVERWRITE,
        mach_task_self(), reinterpret_cast<vm_address_t>(source), FALSE, &current, &maximum, VM_INHERIT_SHARE);
    if (status != KERN_SUCCESS || !(current & VM_PROT_EXECUTE)) {
        if (error) *error = ABICreateResolutionFailure(ABIFailureOther,
            status == KERN_SUCCESS ? "The remapped Swift callback page is not executable." : mach_error_string(status));
        return {};
    }
    page->free.reserve(entryCount);
    for (size_t index = entryCount; index != 0; --index) page->free.push_back(index - 1);
    return page;
}
}

namespace abibridge {
struct SwiftCallbackCode::Storage {
    std::shared_ptr<Page> page;
    size_t index;
    ~Storage() {
        std::lock_guard lock(pageRegistry().mutex);
        page->free.push_back(index);
    }
};

SwiftCallbackCode::SwiftCallbackCode(void *context, ABIResolutionFailure **error, bool closure) {
    if (error) *error = nullptr;
    auto &registry = pageRegistry();
    std::lock_guard lock(registry.mutex);
    auto &pages = registry.pages;
    std::shared_ptr<Page> page;
    for (auto iterator = pages.begin(); iterator != pages.end();) {
        auto candidate = iterator->lock();
        if (!candidate) { iterator = pages.erase(iterator); continue; }
        if (!candidate->free.empty()) { page = std::move(candidate); break; }
        ++iterator;
    }
    if (!page) {
        page = allocatePage(error);
        if (!page) return;
        pages.push_back(page);
    }
    const auto index = page->free.back();
    page->free.pop_back();
    storage = std::make_unique<Storage>();
    storage->page = std::move(page);
    storage->index = index;
    auto *configuration = reinterpret_cast<Configuration *>(storage->page->base) + index;
    *configuration = {};
    configuration->context = reinterpret_cast<uintptr_t>(context);
    configuration->closure = closure;
    ABIUnmanagedFunction entry = ABISwiftCallbackAssembly;
    std::memcpy(&configuration->entry, &entry, sizeof(entry));
#if __has_feature(ptrauth_calls)
    configuration->discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
}

void *SwiftCallbackCode::closureContext(ABIUnmanagedFunction function) {
    if (!function) return nullptr;
    const void *pointer;
    std::memcpy(&pointer, &function, sizeof(pointer));
#if __has_feature(ptrauth_calls)
    pointer = ptrauth_auth_data(pointer, ptrauth_key_function_pointer,
        ptrauth_function_pointer_type_discriminator(void(void)));
#endif
    const auto address = reinterpret_cast<uintptr_t>(pointer);
    auto &registry = pageRegistry();
    std::lock_guard lock(registry.mutex);
    for (const auto &weak : registry.pages) {
        auto page = weak.lock();
        if (!page) continue;
        const auto start = page->base + PAGE_MAX_SIZE;
        if (address < start || address - start >= PAGE_MAX_SIZE) continue;
        const auto offset = address - start;
        if (offset % sizeof(Configuration)) return nullptr;
        const auto index = offset / sizeof(Configuration);
        if (std::find(page->free.begin(), page->free.end(), index) != page->free.end()) return nullptr;
        const auto *configuration = reinterpret_cast<const Configuration *>(page->base) + index;
        return configuration->closure ? reinterpret_cast<void *>(configuration->context) : nullptr;
    }
    return nullptr;
}

SwiftCallbackCode::~SwiftCallbackCode() = default;
ABIUnmanagedFunction SwiftCallbackCode::function() const {
    if (!storage) return nullptr;
    const auto address = storage->page->base + PAGE_MAX_SIZE + storage->index * sizeof(Configuration);
    return ABIUnsafeFunctionAtAddress(reinterpret_cast<const void *>(address));
}
}
