#include <ABIBridge/ImportedHooks.h>
#include <ABIBridge/Memory.h>
#include "NativeValueType.hpp"
#include <atomic>
#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <pthread.h>
#include <string>
#include <vector>

namespace {
using Failure = std::unique_ptr<ABIResolutionFailure, decltype(&ABIReleaseResolutionFailure)>;
using Target = std::unique_ptr<ABIVirtualCallTarget, decltype(&ABIReleaseVirtualCallTarget)>;
using Interface = std::unique_ptr<ABICallInterface, decltype(&ABIReleaseCallInterface)>;
bool fail(ABIResolutionFailure **out, int32_t code, const char *message) {
    if (out) *out = ABICreateResolutionFailure(code, message);
    return false;
}
struct Callback {
    void *context;
    ABIImportedCallback callback;
    ABIImportedFailureHandler failure;
    ABIImportedContextRelease release;
    ~Callback() { release(context); }
};
using Chain = std::vector<std::shared_ptr<Callback>>;
struct Entry {
    ABIImportSlot slot;
    std::shared_ptr<ABIImportSelection> owner;
    Interface interface{nullptr, ABIReleaseCallInterface};
    Target target{nullptr, ABIReleaseVirtualCallTarget};
    ABICallClosure *closure = nullptr;
    uintptr_t original = 0, installed = 0;
    bool published = false, detached = false;
    std::vector<size_t> parameterSizes;
    size_t resultSize = 0;
    std::vector<size_t> contract;
    std::mutex mutex;
    std::shared_ptr<const Chain> chain = std::make_shared<Chain>();
    ~Entry() { if (closure && !published) ABIReleaseCallClosure(closure); }
};
struct Registry { std::mutex mutex; std::map<std::pair<uintptr_t,uint64_t>, std::unique_ptr<Entry>> entries; };
Registry& registry() { static auto *r = new Registry; return *r; }
struct Bytes {
    std::vector<std::max_align_t> storage;
    explicit Bytes(size_t count) : storage((std::max(count, sizeof(void *)) + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t)) {}
    void *data() { return storage.data(); }
};
void typeKey(const std::shared_ptr<abibridge::TypeStorage>& type, std::vector<size_t>& out) {
    out.push_back(type->native()->type); out.push_back(type->size()); out.push_back(type->native()->alignment);
    out.push_back(type->fields.size());
    for (const auto& field : type->fields) typeKey(field, out);
}
bool readBits(const Entry& entry, uintptr_t& bits) {
    return ABIReadMemory(entry.slot.slot, sizeof(bits), &bits).status == ABIMemoryReadComplete;
}
bool sameSchema(const Entry& entry, ABIImportSlot slot, const std::vector<size_t>& contract) {
    return entry.slot.key == slot.key && entry.slot.discriminator == slot.discriminator
        && entry.slot.addressDiversity == slot.addressDiversity && entry.contract == contract;
}
}

struct ABIImportedInvocation {
    Entry& entry;
    const Chain& chain;
    size_t next;
    void *const *arguments;
    pthread_t thread = pthread_self();
    Bytes result;
    Bytes candidate;
    bool proceeded = false, assigned = false;
    ABIImportedInvocation(Entry& entry, const Chain& chain, size_t next, void *const *arguments)
        : entry(entry), chain(chain), next(next), arguments(arguments), result(entry.resultSize), candidate(entry.resultSize) {}
};

namespace {
void invoke(Entry& entry, const Chain& chain, size_t count, void *const *args, void *output) {
    if (!count) {
        // Preparation establishes the full non-null call contract. No foreign
        // exception may unwind across this C/libffi boundary.
        ABIResolutionFailure *error = nullptr;
        const bool ok = ABIUnsafeInvokeCCallInterface(entry.interface.get(), ABIVirtualCallTargetFunction(entry.target.get()), output, args, &error);
        if (!ok) std::terminate(); // Internal prepared-call invariant.
        return;
    }
    auto& callback = *chain[count-1];
    ABIImportedInvocation call(entry, chain, count-1, args);
    ABIResolutionFailure *error = nullptr;
    const bool ok = callback.callback(callback.context, &call, &error);
    if (!ok) {
        Failure owned(error ? error : ABICreateResolutionFailure(ABIFailureOther, "The imported function callback failed."), ABIReleaseResolutionFailure);
        callback.failure(callback.context, owned.get());
    } else if (error) ABIReleaseResolutionFailure(error);
    if (ok && call.assigned) { if (entry.resultSize) std::memcpy(output, call.candidate.data(), entry.resultSize); }
    else if (call.proceeded) { if (entry.resultSize) std::memcpy(output, call.result.data(), entry.resultSize); }
    else invoke(entry, chain, count-1, args, output);
}
bool check(ABIImportedInvocation *call, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!call) return fail(error, ABIFailureInvalidRequest, "A live callback is required.");
    if (!pthread_equal(call->thread, pthread_self())) return fail(error, ABIFailureWrongThread, "Use the invocation on its callback thread.");
    return true;
}
}

bool ABIImportedReadArgument(ABIImportedInvocation *call, size_t index, void *bytes, size_t size, ABIResolutionFailure **error) {
    if (!check(call,error)) return false;
    if (index >= call->entry.parameterSizes.size() || size != call->entry.parameterSizes[index] || (size && !bytes))
        return fail(error, ABIFailureInvalidRequest, "Argument storage does not match the signature.");
    if (size) std::memcpy(bytes, call->arguments[index], size);
    return true;
}
bool ABIImportedProceed(ABIImportedInvocation *call, void *const *args, size_t count, ABIResolutionFailure **error) {
    if (!check(call,error)) return false;
    if (args && count != call->entry.parameterSizes.size()) return fail(error, ABIFailureInvalidRequest, "Argument count does not match.");
    if (args) for (size_t i=0; i<count; ++i) if (!args[i]) return fail(error, ABIFailureInvalidRequest, "Argument storage is missing.");
    if (!args && count) return fail(error, ABIFailureInvalidRequest, "Use null/zero to preserve original arguments.");
    invoke(call->entry, call->chain, call->next, args ? args : call->arguments, call->result.data());
    call->proceeded = true;
    return true;
}
bool ABIImportedCopyResult(ABIImportedInvocation *call, void *bytes, size_t size, ABIResolutionFailure **error) {
    if (!check(call,error)) return false;
    if (!call->proceeded || size != call->entry.resultSize || (size && !bytes)) return fail(error, ABIFailureInvalidRequest, "A completed continuation and matching result storage are required.");
    if (size) std::memcpy(bytes, call->result.data(), size);
    return true;
}
bool ABIImportedSetResult(ABIImportedInvocation *call, const void *bytes, size_t size, ABIResolutionFailure **error) {
    if (!check(call,error)) return false;
    if (size != call->entry.resultSize || (size && !bytes)) return fail(error, ABIFailureInvalidRequest, "Result storage does not match.");
    if (size) std::memcpy(call->candidate.data(),bytes,size);
    call->assigned = true;
    return true;
}

struct ABIImportedHook {
    std::atomic<size_t> references{1};
    std::mutex mutex;
    bool active = false;
    Callback *identity = nullptr;
    struct Slot { ABIImportSlot description; Entry *entry = nullptr; ABIPointerSlotResult mutation{}, rollback{}; };
    std::vector<Slot> slots;
    Failure failure{nullptr, ABIReleaseResolutionFailure};
    size_t failedIndex = SIZE_MAX;
};

ABIImportedHook *ABICreateFailedImportedHook(ABIResolutionFailure *error) {
    auto hook = std::make_unique<ABIImportedHook>(); hook->failure.reset(error); return hook.release();
}

ABIImportedHook *ABICreateImportedHook(ABIImportSelection *selection, const ABIValueType *resultType,
    const ABIValueType *const *parameters, size_t count, void *context, ABIImportedCallback callback,
    ABIImportedFailureHandler onFailure, ABIImportedContextRelease release) {
    if (!release) return nullptr;
    auto behavior = std::shared_ptr<Callback>(new Callback{context,callback,onFailure,release});
    auto hook = std::make_unique<ABIImportedHook>();
    if (!selection || !callback || !onFailure) {
        hook->failure.reset(ABICreateResolutionFailure(ABIFailureInvalidRequest, "A selection, callback and failure handler are required.")); return hook.release();
    }
    ABIResolutionFailure *failure = nullptr;
    Interface interface(ABICreateCCallInterface(resultType,parameters,count,&failure), ABIReleaseCallInterface);
    if (!interface) { hook->failure.reset(failure); return hook.release(); }
    std::vector<size_t> contract; typeKey(resultType->storage,contract); contract.push_back(count);
    for (size_t i=0;i<count;++i) typeKey(parameters[i]->storage,contract);
    const auto slots = ABIImportSelectionCount(selection);
    if (!slots) { hook->failure.reset(ABICreateResolutionFailure(ABIFailureDeclarationNotFound,"No matching imported function slots.")); return hook.release(); }
    ABIRetainImportSelection(selection);
    auto owner = std::shared_ptr<ABIImportSelection>(selection, ABIReleaseImportSelection);
    hook->slots.reserve(slots);
    std::vector<std::unique_ptr<Entry>> candidates(slots);
    // Capturing/retaining target images may enter dyld. Do that before writer locks.
    for (size_t i=0;i<slots;++i) {
        const auto slot = ABIImportSelectionGet(selection,i);
        hook->slots.push_back({slot});
        auto entry = std::make_unique<Entry>(); entry->slot = slot; entry->owner = owner;
        entry->contract = contract; entry->resultSize = ABIValueTypeSize(resultType);
        for (size_t p=0;p<count;++p) entry->parameterSizes.push_back(ABIValueTypeSize(parameters[p]));
        ABIRetainCallInterface(interface.get()); entry->interface.reset(interface.get());
        if (!readBits(*entry, entry->original) || !entry->original) {
            hook->failedIndex=i; hook->failure.reset(ABICreateResolutionFailure(ABIFailureInvalidAddress,"An imported function slot is unreadable or null.")); return hook.release();
        }
        entry->target.reset(ABICopyVirtualCallTarget(reinterpret_cast<void*>(slot.slot),slot.key,slot.discriminator,slot.addressDiversity,&failure));
        if (!entry->target) { hook->failedIndex=i; hook->failure.reset(failure); return hook.release(); }
        entry->chain = std::make_shared<Chain>(Chain{behavior});
        entry->closure = ABICreateCallClosure(interface.get(), [](void *context, void *result, void *const *args) {
            auto& entry = *static_cast<Entry*>(context);
            std::shared_ptr<const Chain> snapshot;
            { std::lock_guard lock(entry.mutex); snapshot = entry.chain; }
            invoke(entry,*snapshot,snapshot->size(),args,result);
        }, entry.get(), &failure);
        if (!entry->closure) { hook->failedIndex=i; hook->failure.reset(failure); return hook.release(); }
        if (!ABIEncodePointerSlotFunction(ABICallClosureFunction(entry->closure),reinterpret_cast<void*>(slot.slot),slot.key,slot.discriminator,slot.addressDiversity,&entry->installed)) {
            hook->failedIndex=i; hook->failure.reset(ABICreateResolutionFailure(ABIFailureInvalidRequest,"Invalid import authentication schema.")); return hook.release();
        }
        candidates[i]=std::move(entry);
    }
    // Allocate every new chain, rollback snapshot, registry node and diagnostic
    // before the first publication. Activation/recovery never grow containers.
    struct Plan {
        Entry *entry = nullptr;
        bool inserted = false, activated = false;
        std::shared_ptr<const Chain> before, after;
    };
    std::vector<Plan> plans(slots);
    const auto empty = std::make_shared<const Chain>();
    Failure changedError(ABICreateResolutionFailure(ABIFailureHookDisplaced,"Another writer displaced the imported hook."),ABIReleaseResolutionFailure);
    Failure contractError(ABICreateResolutionFailure(ABIFailureSignatureMismatch,"Existing import hook uses a different signature or authentication schema."),ABIReleaseResolutionFailure);
    Failure mutationError(ABICreateResolutionFailure(ABIFailureOther,"Imported slot publication or protection restoration failed; inspect the mutation result."),ABIReleaseResolutionFailure);
    hook->identity = behavior.get();
    {
        auto& r=registry(); std::lock_guard writer(r.mutex);
        // Nodes inserted here are unpublished; if allocation fails, remove them
        // while moving their owners out of the lock before exception unwinding.
        try {
            for (size_t i=0;i<slots;++i) {
                auto& state=hook->slots[i]; auto& plan=plans[i];
                const auto key=std::make_pair(state.description.slot,state.description.generation);
                auto found=r.entries.find(key);
                if (found!=r.entries.end()) {
                    auto& entry=*found->second;
                    uintptr_t current=0;
                    if (!sameSchema(entry,state.description,contract)) hook->failure=std::move(contractError);
                    else if (!readBits(entry,current) || (current!=entry.installed && !(entry.detached && current==entry.original))) hook->failure=std::move(changedError);
                    if (hook->failure) { hook->failedIndex=i; break; }
                    plan.entry=&entry;
                    std::lock_guard lock(entry.mutex);
                    plan.before=entry.chain;
                    auto next=std::make_shared<Chain>(*entry.chain); next->push_back(behavior); plan.after=next;
                } else {
                    plan.before=empty; plan.after=candidates[i]->chain;
                    const auto position=r.entries.emplace(key,std::move(candidates[i])).first;
                    plan.entry=position->second.get(); plan.inserted=true;
                }
            }
        } catch (...) {
            for(size_t i=0;i<slots;++i) if(plans[i].inserted) {
                const auto key=std::make_pair(hook->slots[i].description.slot,hook->slots[i].description.generation);
                auto found=r.entries.find(key); candidates[i]=std::move(found->second); r.entries.erase(found);
            }
            throw;
        }
        if(!hook->failure) for(size_t i=0;i<slots;++i) {
            auto& state=hook->slots[i]; auto& plan=plans[i]; auto& entry=*plan.entry;
            uintptr_t current=0;
            const bool publish=plan.inserted || entry.detached;
            if(!readBits(entry,current) || current!=(publish ? entry.original : entry.installed)) {
                hook->failure=std::move(changedError); hook->failedIndex=i; break;
            }
            { std::lock_guard lock(entry.mutex); entry.chain=plan.after; }
            plan.activated=true; state.entry=&entry;
            if(publish) {
                state.mutation=ABICompareExchangePointerSlot(reinterpret_cast<void*>(entry.slot.slot),entry.original,entry.installed);
                if(state.mutation.didWrite) { entry.published=true; entry.detached=false; }
                if(state.mutation.status!=ABIPointerSlotComplete) {
                    hook->failure=state.mutation.status==ABIPointerSlotDisplaced ? std::move(changedError) : std::move(mutationError);
                    hook->failedIndex=i; break;
                }
            }
        }
        if(hook->failure) {
            for(size_t remaining=slots;remaining;--remaining) {
                const auto i=remaining-1; auto& plan=plans[i]; auto& state=hook->slots[i];
                if(plan.activated) {
                    auto& entry=*plan.entry;
                    { std::lock_guard lock(entry.mutex); entry.chain=plan.before; }
                    if(state.mutation.didWrite) {
                        state.rollback=ABICompareExchangePointerSlot(reinterpret_cast<void*>(entry.slot.slot),entry.installed,entry.original);
                        if(state.rollback.didWrite) entry.detached=true;
                    }
                }
                if(plan.inserted && !plan.entry->published) {
                    const auto key=std::make_pair(state.description.slot,state.description.generation);
                    auto found=r.entries.find(key); candidates[i]=std::move(found->second); r.entries.erase(found);
                    state.entry=nullptr;
                }
            }
        } else hook->active=true;
    }
    return hook.release();
}

ABIImportedHook *ABIRetainImportedHook(ABIImportedHook *hook) { if(hook) ++hook->references; return hook; }
void ABIInvalidateImportedHook(ABIImportedHook *hook) {
    if(!hook) return;
    std::vector<std::shared_ptr<const Chain>> retired;
    { std::lock_guard own(hook->mutex);
      if(!hook->active) return;
      retired.reserve(hook->slots.size());
      auto& r=registry(); std::lock_guard writer(r.mutex);
      for(auto& state:hook->slots) { if(!state.entry) continue; auto& entry=*state.entry; std::lock_guard lock(entry.mutex);
          auto chain=std::make_shared<Chain>();
          for(auto& cb:*entry.chain) if(cb.get()!=hook->identity) chain->push_back(cb);
          retired.push_back(std::move(entry.chain)); entry.chain=chain;
      }
      hook->active=false;
    }
}
void ABIReleaseImportedHook(ABIImportedHook *hook) { if(hook && --hook->references==0) { ABIInvalidateImportedHook(hook); delete hook; } }
const ABIResolutionFailure *ABIImportedHookFailure(const ABIImportedHook *h) { return h->failure.get(); }
size_t ABIImportedHookFailedIndex(const ABIImportedHook *h) { return h->failedIndex; }
size_t ABIImportedHookCount(const ABIImportedHook *h) { return h->slots.size(); }
uintptr_t ABIImportedHookSlot(const ABIImportedHook *h,size_t i) { return h->slots[i].description.slot; }
int32_t ABIImportedHookStatus(const ABIImportedHook *h,size_t i) {
    auto *hook=const_cast<ABIImportedHook*>(h); std::lock_guard lock(hook->mutex);
    if(!hook->active) return ABIImportedInactive;
    uintptr_t bits=0; auto *entry=h->slots[i].entry;
    if(!entry || !readBits(*entry,bits)) return ABIImportedUnreadable;
    return bits==entry->installed ? ABIImportedActive : ABIImportedDisplaced;
}
ABIPointerSlotResult ABIImportedHookMutation(const ABIImportedHook *h,size_t i) { return h->slots[i].mutation; }
ABIPointerSlotResult ABIImportedHookRollback(const ABIImportedHook *h,size_t i) { return h->slots[i].rollback; }
