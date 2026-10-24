#include <ABIBridge/VirtualHooks.h>
#include <ABIBridge/ManagedVirtualEntry.h>
#include "ManagedFunctionHooks.hpp"
#include <climits>

namespace {
ABIImportedHook *transport(ABIVirtualHook *hook) { return reinterpret_cast<ABIImportedHook*>(hook); }
const ABIImportedHook *transport(const ABIVirtualHook *hook) { return reinterpret_cast<const ABIImportedHook*>(hook); }
ABIImportedInvocation *transport(ABIVirtualInvocation *call) { return reinterpret_cast<ABIImportedInvocation*>(call); }
struct Callback {
    void *context;
    ABIVirtualCallback invoke;
    ABIVirtualFailureHandler failure;
    ABIVirtualContextRelease release;
    ~Callback() { release(context); }
};
ABIVirtualHook *failed(const char *message) {
    return reinterpret_cast<ABIVirtualHook*>(ABICreateFailedImportedHook(ABICreateResolutionFailure(ABIFailureInvalidRequest,message)));
}
}

ABIVirtualHook *ABIInstallSharedVirtualHook(ABIVirtualEntryInfo entry,
    void *storageContext, ABIVirtualContextRelease releaseStorage,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIVirtualCallback callback, ABIVirtualFailureHandler failure, ABIVirtualContextRelease release) {
    if (!release) return nullptr;
    abibridge::TransferredContext storage{storageContext,releaseStorage};
    // Create directly: a temporary Callback would release context on destruction.
    std::unique_ptr<Callback> state(new Callback{context,callback,failure,release});
    if ((count && !parameters) || count >= UINT_MAX) return failed("Invalid explicit virtual argument list.");
    ABIResolutionFailure *error=nullptr;
    std::unique_ptr<ABIValueType,decltype(&ABIReleaseValueType)> receiver(ABICreateScalarType(ABIValuePointer,&error),ABIReleaseValueType);
    if (!receiver) return reinterpret_cast<ABIVirtualHook*>(ABICreateFailedImportedHook(error));
    std::vector<const ABIValueType*> all{receiver.get()};
    if (count) all.insert(all.end(),parameters,parameters+count);
    const ABIManagedVirtualEntry selected{entry.addressPoint,entry.entryCount,entry.index,entry.key,entry.discriminator,entry.addressDiversity};
    storage.relinquish();
    return reinterpret_cast<ABIVirtualHook*>(ABICreateManagedVirtualHook(selected,storageContext,releaseStorage,
        result,all.data(),all.size(),state.release(),callback ? +[](void *context,ABIImportedInvocation *call,ABIResolutionFailure **error) {
            auto& state=*static_cast<Callback*>(context);
            return state.invoke(state.context,reinterpret_cast<ABIVirtualInvocation*>(call),error);
        } : nullptr, failure ? +[](void *context,const ABIResolutionFailure *error) {
            auto& state=*static_cast<Callback*>(context); state.failure(state.context,error);
        } : nullptr,[](void *context) { delete static_cast<Callback*>(context); }));
}
ABIVirtualHook *ABIRetainVirtualHook(ABIVirtualHook *hook) { return reinterpret_cast<ABIVirtualHook*>(ABIRetainImportedHook(transport(hook))); }
void ABIInvalidateVirtualHook(ABIVirtualHook *hook) { ABIInvalidateImportedHook(transport(hook)); }
void ABIReleaseVirtualHook(ABIVirtualHook *hook) { ABIReleaseImportedHook(transport(hook)); }
const ABIResolutionFailure *ABIVirtualHookGetFailure(const ABIVirtualHook *hook) { return ABIImportedHookGetFailure(transport(hook)); }
bool ABIVirtualHookHasEntry(const ABIVirtualHook *hook) { return ABIImportedHookGetSlotCount(transport(hook)) != 0; }
uintptr_t ABIVirtualHookGetSlot(const ABIVirtualHook *hook) { return ABIImportedHookGetSlot(transport(hook),0); }
int32_t ABIVirtualHookGetStatus(const ABIVirtualHook *hook) { return ABIImportedHookGetSlotStatus(transport(hook),0); }
ABIPointerSlotResult ABIVirtualHookGetMutation(const ABIVirtualHook *hook) { return ABIImportedHookGetMutation(transport(hook),0); }
ABIPointerSlotResult ABIVirtualHookGetRollback(const ABIVirtualHook *hook) { return ABIImportedHookGetRollback(transport(hook),0); }
void *ABIVirtualInvocationGetReceiver(ABIVirtualInvocation *call,ABIResolutionFailure **error) {
    void *receiver=nullptr;
    ABIImportedInvocationReadArgument(transport(call),0,&receiver,sizeof(receiver),error);
    return receiver;
}
bool ABIVirtualInvocationReadArgument(ABIVirtualInvocation *call,size_t index,void *bytes,size_t size,ABIResolutionFailure **error) {
    if (index == SIZE_MAX) {
        if (error) *error=ABICreateResolutionFailure(ABIFailureInvalidRequest,"Virtual argument index overflow.");
        return false;
    }
    return ABIImportedInvocationReadArgument(transport(call),index+1,bytes,size,error);
}
bool ABIVirtualInvocationProceed(ABIVirtualInvocation *call,const void *const *arguments,size_t count,ABIResolutionFailure **error) {
    if ((count && !arguments) || count >= UINT_MAX) {
        if (error) *error=ABICreateResolutionFailure(ABIFailureInvalidRequest,"Invalid explicit virtual arguments.");
        return false;
    }
    void *receiver=nullptr;
    if (!ABIImportedInvocationReadArgument(transport(call),0,&receiver,sizeof(receiver),error)) return false;
    std::vector<const void*> all{&receiver};
    if (count) all.insert(all.end(),arguments,arguments+count);
    return ABIImportedInvocationProceed(transport(call),all.data(),all.size(),error);
}
bool ABIVirtualInvocationProceedWithOriginalArguments(ABIVirtualInvocation *call, ABIResolutionFailure **error) {
    return ABIImportedInvocationProceedWithOriginalArguments(transport(call),error);
}
bool ABIVirtualInvocationReadResult(ABIVirtualInvocation *call,void *bytes,size_t size,ABIResolutionFailure **error) {
    return ABIImportedInvocationReadResult(transport(call),bytes,size,error);
}
bool ABIVirtualInvocationSetResult(ABIVirtualInvocation *call,const void *bytes,size_t size,ABIResolutionFailure **error) {
    return ABIImportedInvocationSetResult(transport(call),bytes,size,error);
}
