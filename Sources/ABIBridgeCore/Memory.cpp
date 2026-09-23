#include <ABIBridge/Memory.h>
#include <algorithm>
#include <mach/mach.h>

ABIMemoryReadResult ABIReadMemory(uintptr_t address, size_t byteCount, void* destination) {
    if (byteCount == 0) return {ABIMemoryReadComplete, 0, 0};
    if (byteCount > UINTPTR_MAX - address || !destination) {
        return {ABIMemoryReadInvalidRange, 0, 0};
    }

    size_t copied = 0;
    while (copied < byteCount) {
        const auto current = address + copied;
        const auto chunk = std::min(byteCount - copied, size_t(vm_page_size - current % vm_page_size));
        vm_size_t received = 0;
        const auto code = vm_read_overwrite(
            mach_task_self(), current, chunk,
            reinterpret_cast<vm_address_t>(static_cast<unsigned char*>(destination) + copied),
            &received);
        // Mach only defines outsize on success. Never publish bytes from a
        // failed operation, even if the destination was partially overwritten.
        if (code != KERN_SUCCESS) {
            return {copied ? ABIMemoryReadPartial : ABIMemoryReadFailed, copied, code};
        }
        copied += received;
        if (received != chunk) return {ABIMemoryReadPartial, copied, 0};
    }
    return {ABIMemoryReadComplete, copied, 0};
}
