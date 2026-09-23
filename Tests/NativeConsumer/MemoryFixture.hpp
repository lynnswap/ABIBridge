#pragma once
#include <ABIBridge/Memory.hpp>
#include <cassert>
#include <sys/mman.h>
#include <unistd.h>

inline void checkMemoryReads() {
    using namespace abi_bridge;
    const auto page = static_cast<std::size_t>(getpagesize());
    auto* mapped = mmap(nullptr, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(mapped != MAP_FAILED);
    auto owner = std::shared_ptr<void>(mapped, [page](void* p) { munmap(p, page * 2); });
    std::weak_ptr<void> weakOwner = owner;
    auto* bytes = static_cast<std::byte*>(mapped);
    bytes[page - 3] = std::byte{0x51};
    assert(mprotect(bytes + page, page, PROT_NONE) == 0);
    memory_read_result saved{};
    {
        memory_region region(reinterpret_cast<std::uintptr_t>(bytes + page - 3), 6, owner);
        owner.reset();
        assert(!weakOwner.expired());
        saved = region.read();
        assert(saved.status == ABIMemoryReadPartial && saved.bytes.size() == 3);
        assert(saved.system_error != 0 && saved.bytes.front() == std::byte{0x51});
        const auto failed = region.read(3, 3);
        assert(failed.status == ABIMemoryReadFailed && failed.bytes.empty());
        assert(region.read(6, 0).is_complete());
        try { region.read(6, 1); assert(false); } catch (const std::out_of_range&) {}
    }
    assert(weakOwner.expired() && saved.bytes.front() == std::byte{0x51});
    try { memory_region(UINTPTR_MAX, 1); assert(false); } catch (const std::invalid_argument&) {}
    assert(memory_region(UINTPTR_MAX, 0).read().is_complete());
}
