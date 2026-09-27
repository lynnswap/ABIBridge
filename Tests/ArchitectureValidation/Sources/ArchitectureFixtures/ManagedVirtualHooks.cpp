#include "include/ArchitectureFixtures.h"
#include "VirtualMutation.hpp"
#include <ABIBridge/ManagedVirtualEntry.h>
#include <ptrauth.h>
#include <mach/mach.h>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <string>

namespace {
using Hook = std::unique_ptr<ABIImportedHook,decltype(&ABIReleaseImportedHook)>;
using Type = std::unique_ptr<ABIValueType,decltype(&ABIReleaseValueType)>;
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void checked(bool ok, ABIResolutionFailure *error) {
    std::unique_ptr<ABIResolutionFailure,decltype(&ABIReleaseResolutionFailure)> owned(error,ABIReleaseResolutionFailure);
    if (!ok) throw std::runtime_error(error ? ABIResolutionFailureMessage(error) : "Virtual callback failed");
}
struct Statistics {
    std::atomic<unsigned> released{0}, failures{0}, storageReleased{0};
    std::atomic<bool> cleanupOrder{true};
};
struct Callback {
    std::shared_ptr<Statistics> statistics;
    std::function<void(ABIImportedInvocation*)> body;
    bool checkStorage = false;
    ~Callback() {
        if (checkStorage && statistics->storageReleased.load()) statistics->cleanupOrder=false;
        ++statistics->released;
        auto *snapshot=ABICopyLoadedImages(); ABIFreeImageList(snapshot);
    }
};
struct Storage {
    std::shared_ptr<Statistics> statistics;
    std::shared_ptr<uintptr_t> slot;
    ~Storage() { ++statistics->storageReleased; }
};
template<class T> T read(ABIImportedInvocation *call, size_t index) {
    T value{}; ABIResolutionFailure *error=nullptr;
    const bool ok=ABIImportedReadArgument(call,index,&value,sizeof(value),&error); checked(ok,error); return value;
}
template<class T> T proceed(ABIImportedInvocation *call, void *const *arguments=nullptr, size_t count=0) {
    ABIResolutionFailure *error=nullptr;
    const bool ok=ABIImportedProceed(call,arguments,count,&error); checked(ok,error);
    T value{}; error=nullptr;
    const bool copied=ABIImportedCopyResult(call,&value,sizeof(value),&error); checked(copied,error); return value;
}
template<class T> void result(ABIImportedInvocation *call, T value) {
    ABIResolutionFailure *error=nullptr;
    const bool ok=ABIImportedSetResult(call,&value,sizeof(value),&error); checked(ok,error);
}
Type scalar(int32_t kind) {
    ABIResolutionFailure *error=nullptr;
    Type type(ABICreateScalarType(kind,&error),ABIReleaseValueType); checked(bool(type),error); return type;
}
Hook install(ABIManagedVirtualEntry entry, const ABIValueType *output, const ABIValueType *const *parameters, size_t count,
    std::shared_ptr<Statistics> statistics, std::function<void(ABIImportedInvocation*)> body, Storage *storage=nullptr) {
    auto *callback=new Callback{statistics,std::move(body),storage!=nullptr};
    return Hook(ABICreateManagedVirtualHook(entry,storage,storage ? [](void *context){ delete static_cast<Storage*>(context); } : nullptr,
        output,parameters,count,callback,[](void *context,ABIImportedInvocation *call,ABIResolutionFailure **error) {
            try { static_cast<Callback*>(context)->body(call); return true; }
            catch (const std::exception& failure) { *error=ABICreateResolutionFailure(ABIFailureOther,failure.what()); return false; }
        },[](void *context,const ABIResolutionFailure*) { ++static_cast<Callback*>(context)->statistics->failures; },
        [](void *context) { delete static_cast<Callback*>(context); }),ABIReleaseImportedHook);
}
ABIManagedVirtualEntry entry(void *receiver, bool secondary, bool covariant=false) {
    const auto *point=secondary ? __builtin_get_vtable_pointer(static_cast<ABIVTable::Secondary*>(receiver))
        : __builtin_get_vtable_pointer(static_cast<ABIVTable::Primary*>(receiver));
    uintptr_t discriminator=0;
#if __has_feature(ptrauth_calls)
    discriminator=secondary ? (covariant ? ptrauth_string_discriminator("_ZN9ABIVTable9Secondary8identityEv")
        : ptrauth_string_discriminator("_ZNK9ABIVTable9Secondary8adjustedEi"))
        : ptrauth_string_discriminator("_ZNK9ABIVTable7Primary5valueEi");
#endif
    return {point,size_t(secondary ? 2 : 3),size_t(covariant ? 1 : 0),ABIUsesPointerAuthentication() ? ABIAuthenticationInstructionA : ABIAuthenticationUnsigned,
        discriminator,ABIUsesPointerAuthentication()};
}
void successful(const Hook& hook, const char *stage) {
    if (auto *error=ABIImportedHookFailure(hook.get())) {
        std::string detail=std::string(stage)+": "+ABIResolutionFailureMessage(error);
        if (ABIImportedHookCount(hook.get())) {
            const auto mutation=ABIImportedHookMutation(hook.get(),0);
            detail+=" status="+std::to_string(mutation.status)+" kernel="+std::to_string(mutation.systemErrorCode)
                +" flags="+std::to_string(mutation.regionFlags);
        }
        throw std::runtime_error(detail);
    }
}
int synthetic(void *receiver,int value) { return *static_cast<int*>(receiver)+value; }
}

const char *ABIValidateManagedVirtualHooks(bool requireWritable, bool *published) {
    static thread_local std::string failure;
    if (!published) return "Missing managed virtual probe output";
    *published=false;
    try {
        using namespace ABIVTable;
        Derived first(40), second(100);
        auto *primary=static_cast<Primary*>(&first); auto *secondary=static_cast<Secondary*>(&first);
        const auto primaryEntry=entry(primary,false), secondaryEntry=entry(secondary,true), covariantEntry=entry(secondary,true,true);
        auto pointer=scalar(ABIValuePointer), integer=scalar(ABIValueInt32);
        const ABIValueType *arguments[]={pointer.get(),integer.get()};
        auto stats=std::make_shared<Statistics>();
        auto firstHook=install(primaryEntry,integer.get(),arguments,2,stats,[](auto *call) {
            auto *receiver=read<void*>(call,0); auto input=read<int>(call,1)+1;
            void *arguments[]={&receiver,&input}; result(call,proceed<int>(call,arguments,2)+10);
        });
        if (ABIImportedHookFailure(firstHook.get())) {
            require(ABIImportedHookCount(firstHook.get())==1,"Virtual installation failed before slot selection");
            const auto write=ABIImportedHookMutation(firstHook.get(),0);
            require(!requireWritable && !write.didWrite && write.status==ABIPointerSlotProtectFailed
                && write.systemErrorCode==KERN_PROTECTION_FAILURE && (write.regionFlags & VM_REGION_FLAG_TPRO_ENABLED),"Unexpected managed virtual publication failure");
            require(primaryOracle(primary,2)==42 && stats->released==1,"Failed virtual install changed dispatch or retained callback");
            return nullptr;
        }
        *published=true;
        require(primaryOracle(primary,2)==53 && primaryOracle(&second,2)==113,"Shared-table callback mismatch");
        auto secondStats=std::make_shared<Statistics>();
        auto secondHook=install(primaryEntry,integer.get(),arguments,2,secondStats,[](auto *call) {
            auto *receiver=read<void*>(call,0); auto input=read<int>(call,1)*2;
            void *arguments[]={&receiver,&input}; result(call,proceed<int>(call,arguments,2)+100);
        });
        successful(secondHook,"overlap"); require(primaryOracle(primary,2)==155,"Virtual callback ordering mismatch");
        ABIInvalidateImportedHook(secondHook.get()); require(primaryOracle(primary,2)==53 && secondStats->released==1,"Independent invalidation mismatch");
        ABIInvalidateImportedHook(firstHook.get()); require(primaryOracle(primary,2)==42 && stats->released==1,"Virtual pass-through/capture cleanup mismatch");

        auto secondaryStats=std::make_shared<Statistics>();
        auto secondaryHook=install(secondaryEntry,integer.get(),arguments,2,secondaryStats,[secondary](auto *call) {
            require(read<void*>(call,0)==secondary,"Secondary receiver was adjusted before callback");
            result(call,proceed<int>(call)+1);
        });
        successful(secondaryHook,"secondary"); require(secondaryOracle(secondary,2)==63 && primaryOracle(primary,2)==42,"Secondary thunk behavior mismatch");
        ABIInvalidateImportedHook(secondaryHook.get());
        auto covariantStats=std::make_shared<Statistics>();
        auto covariantHook=install(covariantEntry,pointer.get(),arguments,1,covariantStats,[secondary](auto *call) {
            const auto pointer=proceed<void*>(call); require(pointer==secondary,"Covariant result lost its subobject adjustment"); result(call,pointer);
        });
        successful(covariantHook,"covariant"); require(covariantOracle(secondary)==secondary,"Covariant callback result mismatch");
        ABIResolutionFailure *error=nullptr;
        auto *saved=ABICopyVirtualCallTarget(static_cast<const uintptr_t*>(covariantEntry.addressPoint)+covariantEntry.index,
            covariantEntry.key,covariantEntry.discriminator,covariantEntry.addressDiversity,&error);
        checked(saved!=nullptr,error);
        ABIInvalidateImportedHook(covariantHook.get());
        const auto callSaved=reinterpret_cast<Secondary*(*)(Secondary*)>(ABIVirtualCallTargetFunction(saved));
        require(callSaved(secondary)==secondary,"Saved virtual entry lost its predecessor"); ABIReleaseVirtualCallTarget(saved);

        std::mutex mutex; std::condition_variable changed; bool entered=false, finish=false;
        auto flightStats=std::make_shared<Statistics>();
        auto flight=install(primaryEntry,integer.get(),arguments,2,flightStats,[&](auto *call) {
            { std::unique_lock lock(mutex); entered=true; changed.notify_all(); changed.wait(lock,[&]{return finish;}); }
            result(call,proceed<int>(call)+1);
        }); successful(flight,"in-flight");
        int actual=0; std::thread worker([&]{ actual=primaryOracle(primary,2); });
        { std::unique_lock lock(mutex); changed.wait(lock,[&]{return entered;}); }
        ABIInvalidateImportedHook(flight.get());
        const bool snapshotHeld=flightStats->released==0 && primaryOracle(primary,2)==42;
        { std::lock_guard lock(mutex); finish=true; changed.notify_all(); }
        worker.join(); require(snapshotHeld && actual==43 && flightStats->released==1,"In-flight virtual snapshot lifetime mismatch");

        auto *syntheticFunction=reinterpret_cast<ABIUnmanagedFunction>(&synthetic);
        uintptr_t raw=0;
        auto slot=std::make_shared<uintptr_t>(0);
        require(ABIEncodePointerSlotFunction(syntheticFunction,slot.get(),ABIAuthenticationUnsigned,0,false,&raw),"Synthetic slot encoding failed"); *slot=raw;
        ABIManagedVirtualEntry owned{slot.get(),1,0,ABIAuthenticationUnsigned,0,false};
        auto borrowedStats=std::make_shared<Statistics>(), ownedStats=std::make_shared<Statistics>();
        auto borrowed=install(owned,integer.get(),arguments,2,borrowedStats,[](auto *call){result(call,proceed<int>(call));}); successful(borrowed,"borrowed heap slot");
        auto owning=install(owned,integer.get(),arguments,2,ownedStats,[](auto *call){result(call,proceed<int>(call));},new Storage{ownedStats,slot}); successful(owning,"owned heap slot");
        std::weak_ptr<uintptr_t> weak=slot; slot.reset();
        ABIInvalidateImportedHook(owning.get()); ABIInvalidateImportedHook(borrowed.get());
        require(!weak.expired() && ownedStats->storageReleased==0 && ownedStats->released==1,"Joining an existing entry lost its explicit storage owner");

        auto displacementStats=std::make_shared<Statistics>();
        auto storage=weak.lock();
        auto displaced=install(owned,integer.get(),arguments,2,displacementStats,[](auto *call){result(call,proceed<int>(call)+1);}); successful(displaced,"displacement");
        const auto installed=*storage;
        const auto external=ABICompareExchangePointerSlot(storage.get(),installed,raw);
        require(external.didWrite && ABIImportedHookStatus(displaced.get(),0)==ABIImportedDisplaced,"Virtual displacement was not reported");
        ABIInvalidateImportedHook(displaced.get());
        require(*storage==raw && displacementStats->released==1,"Virtual invalidation overwrote an external value");

        for (bool badBounds : {true,false}) {
            auto cleanup=std::make_shared<Statistics>(); auto request=primaryEntry; if (badBounds) request.index=999;
            auto rejected=install(request,badBounds ? integer.get() : nullptr,arguments,2,cleanup,[](auto*){},new Storage{cleanup,{}});
            require(ABIImportedHookFailure(rejected.get()) && cleanup->released==1 && cleanup->storageReleased==1 && cleanup->cleanupOrder,
                "Failed virtual preparation released storage before callback cleanup");
        }
        return nullptr;
    } catch (const std::exception& error) { failure=error.what(); return failure.c_str(); }
}
