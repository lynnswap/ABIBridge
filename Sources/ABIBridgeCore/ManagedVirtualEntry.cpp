#include <ABIBridge/ManagedVirtualEntry.h>
#include "ManagedFunctionHooks.hpp"
#include "ImageOwner.hpp"

namespace {
struct TableOwner {
    std::unique_ptr<ABIImageLease,decltype(&ABIReleaseImage)> image{nullptr,ABIReleaseImage};
    void *context = nullptr;
    ABIImportedContextRelease release = nullptr;
    ~TableOwner() { if (release) release(context); }
};
}

ABIImportedHook *ABICreateManagedVirtualHook(ABIManagedVirtualEntry entry,
    void *storageContext, ABIImportedContextRelease releaseStorage,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIImportedCallback callback, ABIImportedFailureHandler failure,
    ABIImportedContextRelease release) {
    if (!release) return nullptr;
    abibridge::TransferredContext storageOwner{storageContext,releaseStorage}, callbackOwner{context,release};
    auto reject = [](int32_t code, const char *message) {
        return ABICreateFailedImportedHook(ABICreateResolutionFailure(code,message));
    };
    const auto base=reinterpret_cast<uintptr_t>(entry.addressPoint);
    if (!base || entry.index>=entry.entryCount || entry.entryCount>SIZE_MAX/sizeof(uintptr_t)
        || base>UINTPTR_MAX-entry.entryCount*sizeof(uintptr_t)) {
        return reject(ABIFailureInvalidRequest,"The virtual entry lies outside the declared absolute table.");
    }
    if (!count || !parameters || !parameters[0] || !ABIValueTypeIsPointer(parameters[0])) {
        return reject(ABIFailureSignatureMismatch,"A virtual call requires the incoming subobject pointer as parameter zero.");
    }
    auto *slot=static_cast<const char*>(entry.addressPoint)+entry.index*sizeof(uintptr_t);
    auto owner=std::make_shared<TableOwner>();
    ABIResolutionFailure *error=nullptr;
    // Loader calls and owner cleanup stay outside the shared registry lock.
    owner->image.reset(abibridge::copyContainingImage(slot,&error));
    if (error) return ABICreateFailedImportedHook(error);
    owner->context=storageContext; owner->release=releaseStorage; storageOwner.relinquish();
    const auto generation=owner->image ? ABIImageLeaseGet(owner->image.get()).generation : 0;
    std::vector<abibridge::ManagedFunctionSlot> slots;
    slots.push_back({{reinterpret_cast<uintptr_t>(slot),generation,entry.key,entry.discriminator,entry.addressDiversity},
        std::move(owner),releaseStorage!=nullptr});
    callbackOwner.relinquish();
    return abibridge::createManagedFunctionHook(std::move(slots),result,parameters,count,context,callback,failure,release);
}
