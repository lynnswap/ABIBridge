#pragma once
#include <ABIBridge/Inspection.h>
#include <dlfcn.h>
#include <memory>

namespace abibridge {
// A null lease without an error means caller-owned storage/code outside a
// loader image. A known image that cannot be retained is a distinct failure.
inline ABIImageLease *copyContainingImage(const void *address, ABIResolutionFailure **error) {
    *error = nullptr;
    Dl_info info{};
    if (!dladdr(address,&info) || !info.dli_fbase) return nullptr;
    std::unique_ptr<ABIImageList,decltype(&ABIFreeImageList)> images(ABICopyLoadedImages(),ABIFreeImageList);
    if (!images) { *error=ABICreateResolutionFailure(ABIFailureImageUnavailable,"The loaded image catalog is unavailable."); return nullptr; }
    for (size_t index=0; index<ABIImageListCount(images.get()); ++index) {
        const auto image=ABIImageListGet(images.get(),index);
        if (image.header!=reinterpret_cast<uintptr_t>(info.dli_fbase)) continue;
        if (auto *lease=ABIRetainLoadedImage(image.generation)) return lease;
        break;
    }
    *error=ABICreateResolutionFailure(ABIFailureImageChanged,"The containing image could not be retained.");
    return nullptr;
}
}
