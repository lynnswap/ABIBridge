#include "include/ArchitectureFixtures.h"
#include "VirtualMutation.hpp"
#include <ABIBridge/VirtualHooks.hpp>
#include <mach/mach.h>
#include <string>
#include <stdexcept>

namespace {
bool doubleResult(void *,ABIVirtualInvocation *call,ABIResolutionFailure **error) {
    int value=0;
    if(!ABIVirtualReadArgument(call,0,&value,sizeof(value),error)) return false;
    void *arguments[]={&value};
    if(!ABIVirtualProceed(call,arguments,1,error)) return false;
    int result=0;
    if(!ABIVirtualCopyResult(call,&result,sizeof(result),error)) return false;
    result*=2;
    return ABIVirtualSetResult(call,&result,sizeof(result),error);
}
}
const char *ABIValidatePublicVirtualHooks(bool requireWritable,bool *published) {
    static thread_local std::string message;
    *published=false;
    using namespace abi_bridge;
    ABIVTable::Derived first(40), second(100);
    auto runtime=Runtime::current();
    int errors=0;
    auto failure=[&](const resolution_error&) noexcept { ++errors; };
    try {
        auto table=virtual_table::from(static_cast<ABIVTable::Primary&>(first),1);
        auto entry=table.entry(runtime,"ABIVTable::Derived::value(int) const");
        auto primary=entry.hook_shared_calls<int(int)>([&](auto& call,int value) {
            if(call.receiver()!=static_cast<ABIVTable::Primary*>(&first) && call.receiver()!=static_cast<ABIVTable::Primary*>(&second))
                throw std::runtime_error("Public virtual receiver changed");
            return call.proceed(value+1)+10;
        },failure);
        *published=true;
        if(ABIVTable::primaryOracle(&first,2)!=53 || ABIVTable::primaryOracle(&second,2)!=113)
            return "C++ shared-table callback mismatch";
        ABIResolutionFailure *error=nullptr;
        auto integer=std::unique_ptr<ABIValueType,decltype(&ABIReleaseValueType)>(ABICreateScalarType(ABIValueInt32,&error),ABIReleaseValueType);
        if(!integer) { ABIReleaseResolutionFailure(error); return "Public virtual scalar preparation failed"; }
        const ABIValueType *parameters[]={integer.get()};
        auto raw=virtual_hook_handle::adopt(ABIInstallSharedVirtualHook(entry.native_info(),nullptr,nullptr,
            integer.get(),parameters,1,&errors,doubleResult,
            [](void *context,const ABIResolutionFailure*) { ++*static_cast<int*>(context); },[](void*) {}));
        if(ABIVirtualHookFailure(raw.native_handle())) throw virtual_hook_installation_error(raw);
        if(ABIVTable::primaryOracle(&first,2)!=106 || raw.slot()->mutation.didWrite) return "C/C++ callbacks did not share one entry";
        primary.invalidate();
        if(ABIVTable::primaryOracle(&first,2)!=84) return "C++ independent invalidation failed";
        raw.invalidate();
        if(ABIVTable::primaryOracle(&first,2)!=42) return "C independent invalidation failed";
        auto secondary=virtual_table::from(static_cast<ABIVTable::Secondary&>(first),2);
        auto adjusted=secondary.entry(runtime,"ABIVTable::Derived::adjusted(int) const").hook_shared_calls<int(int)>([&](auto& call,int value) {
            if(call.receiver()!=static_cast<ABIVTable::Secondary*>(&first)) throw std::runtime_error("Secondary receiver changed");
            return call.proceed(value)+1;
        },failure);
        auto covariant=secondary.entry(runtime,"ABIVTable::Derived::identity()").hook_shared_calls<ABIVTable::Secondary*()>([](auto& call) { return call.proceed(); },failure);
        if(ABIVTable::secondaryOracle(&first,2)!=63 || ABIVTable::covariantOracle(&first)!=static_cast<ABIVTable::Secondary*>(&first) || errors)
            return "Public secondary/covariant callback mismatch";
        return nullptr;
    } catch(const virtual_hook_installation_error& error) {
        auto slot=error.registration().slot();
        if(!requireWritable && !*published && slot && !slot->mutation.didWrite
            && slot->mutation.status==ABIPointerSlotProtectFailed && slot->mutation.systemErrorCode==KERN_PROTECTION_FAILURE
            && (slot->mutation.regionFlags & VM_REGION_FLAG_TPRO_ENABLED)
            && ABIVTable::primaryOracle(&first,2)==42 && !errors) return nullptr;
        message=error.what(); return message.c_str();
    } catch(const std::exception& error) { message=error.what(); return message.c_str(); }
}
