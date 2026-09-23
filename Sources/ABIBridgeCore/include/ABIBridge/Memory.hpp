#pragma once

#include <ABIBridge/Memory.h>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>

namespace abi_bridge {

/// Owned copied bytes, independent of the source region's lifetime.
/// Even a complete read is not atomic and does not prove pointee validity.
struct memory_read_result final {
    std::uintptr_t source_address;
    std::size_t requested_byte_count;
    std::vector<std::byte> bytes;
    /// One of the ABIMemoryRead constants.
    std::int32_t status;
    /// Original kern_return_t, or zero without an OS error.
    std::int32_t system_error;
    bool is_complete() const noexcept { return status == ABIMemoryReadComplete; }
};

/// A bounded current-process address range, not a promise of readable memory.
/// Copies retain the optional owner. The caller supplies allocation bounds,
/// pointee ownership, and synchronization; retaining an owner alone does not
/// prevent its storage from moving or being destroyed explicitly.
class memory_region final {
public:
    /// Throws invalid_argument if the half-open address range overflows.
    memory_region(std::uintptr_t address, std::size_t byte_count,
                  std::shared_ptr<void> owner = {})
        : address_(address), byte_count_(byte_count), owner_(std::move(owner)) {
        if (byte_count > std::numeric_limits<std::uintptr_t>::max() - address) {
            throw std::invalid_argument("Memory range overflows the address space.");
        }
    }
    std::uintptr_t address() const noexcept { return address_; }
    std::size_t byte_count() const noexcept { return byte_count_; }

    /// Copies a prefix up to the first failed page. Failure is in the result;
    /// allocation failures propagate as standard C++ allocation exceptions.
    memory_read_result read() const { return read(0, byte_count_); }

    /// Reads a bounded subrange, throwing out_of_range before any access when
    /// the subrange exceeds this region. The result never retains the owner.
    memory_read_result read(std::size_t offset, std::size_t count) const {
        if (offset > byte_count_ || count > byte_count_ - offset) {
            throw std::out_of_range("Memory read exceeds the region.");
        }
        memory_read_result result{address_ + offset, count, std::vector<std::byte>(count), 0, 0};
        const auto read = ABIReadMemory(result.source_address, count, result.bytes.data());
        result.bytes.resize(read.byteCount);
        result.status = read.status;
        result.system_error = read.systemError;
        return result;
    }

private:
    std::uintptr_t address_;
    std::size_t byte_count_;
    std::shared_ptr<void> owner_;
};

} // namespace abi_bridge
