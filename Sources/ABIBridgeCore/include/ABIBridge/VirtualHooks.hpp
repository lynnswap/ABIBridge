#pragma once
#include <ABIBridge/VirtualHooks.h>
#include <ABIBridge/CallbackValues.hpp>
#include <array>
#include <optional>
#include <tuple>

namespace abi_bridge {
/// Copied registration state and immutable installation/rollback effects.
struct virtual_hook_slot {
    uintptr_t address;
    int32_t status;
    ABIPointerSlotResult mutation, rollback;
};

/// Copies share a callback; last-owner destruction invalidates it logically.
class virtual_hook_handle {
public:
    static virtual_hook_handle adopt(ABIVirtualHook *value) { return virtual_hook_handle(value); }
    ABIVirtualHook *native_handle() const noexcept { return value_.get(); }
    void invalidate() const { ABIInvalidateVirtualHook(value_.get()); }
    std::optional<virtual_hook_slot> slot() const {
        if (!ABIVirtualHookHasEntry(value_.get())) return std::nullopt;
        return virtual_hook_slot{ABIVirtualHookSlot(value_.get()), ABIVirtualHookStatus(value_.get()),
            ABIVirtualHookMutation(value_.get()), ABIVirtualHookRollback(value_.get())};
    }
private:
    explicit virtual_hook_handle(ABIVirtualHook *value): value_(value,ABIReleaseVirtualHook) {}
    std::shared_ptr<ABIVirtualHook> value_;
};

/// Preserves a failed installation and any partially published/rolled-back slot.
class virtual_hook_installation_error : public std::runtime_error {
public:
    explicit virtual_hook_installation_error(virtual_hook_handle handle):std::runtime_error(
        ABIResolutionFailureMessage(ABIVirtualHookFailure(handle.native_handle()))), handle_(std::move(handle)) {}
    int32_t code() const { return ABIResolutionFailureCode(ABIVirtualHookFailure(handle_.native_handle())); }
    const virtual_hook_handle& registration() const noexcept { return handle_; }
private:
    virtual_hook_handle handle_;
};

template<class Signature> class virtual_hook_invocation;
/// A borrowed continuation, usable only on the incoming callback thread before
/// return. Explicit arguments exclude this; proceed preserves the subobject.
template<class R,class... A> class virtual_hook_invocation<R(A...)> {
public:
    explicit virtual_hook_invocation(ABIVirtualInvocation *call):call_(call) {}
    virtual_hook_invocation(const virtual_hook_invocation&)=delete;
    virtual_hook_invocation& operator=(const virtual_hook_invocation&)=delete;
    void *receiver() const {
        ABIResolutionFailure *error=nullptr;
        auto *pointer=ABIVirtualInvocationReceiver(call_,&error);
        detail::callback_require(error==nullptr,error);
        return pointer;
    }
    R proceed(A... values) {
        std::array<void*,sizeof...(A)> pointers{static_cast<void*>(&values)...};
        ABIResolutionFailure *error=nullptr;
        const bool ok=ABIVirtualProceed(call_,pointers.data(),pointers.size(),&error);
        detail::callback_require(ok,error);
        if constexpr(!std::is_void_v<R>) {
            R result{}; error=nullptr;
            const bool copied=ABIVirtualCopyResult(call_,&result,sizeof(R),&error);
            detail::callback_require(copied,error);
            return result;
        }
    }
private:
    ABIVirtualInvocation *call_;
};

namespace detail {
template<class T> T virtual_read(ABIVirtualInvocation *call,size_t index) {
    T value{}; ABIResolutionFailure *error=nullptr;
    const bool ok=ABIVirtualReadArgument(call,index,&value,sizeof(T),&error);
    callback_require(ok,error); return value;
}
template<class Signature> struct virtual_installer;
template<class R,class... A> struct virtual_installer<R(A...)> {
    template<class Body,class OnFailure> static virtual_hook_handle install(
        ABIVirtualEntryInfo entry,std::shared_ptr<const void> owner,Body body,OnFailure failure) {
        static_assert(std::is_nothrow_invocable_v<OnFailure,const resolution_error&>,"Failure handlers must be noexcept.");
        auto result=callback_type<R>();
        std::array<std::shared_ptr<ABIValueType>,sizeof...(A)> types{callback_type<A>()...};
        std::array<const ABIValueType*,sizeof...(A)> parameters{};
        for(size_t i=0;i<parameters.size();++i) parameters[i]=types[i].get();
        struct State {
            Body body; OnFailure failure;
            State(Body b,OnFailure f):body(std::move(b)),failure(std::move(f)) {}
            static bool invoke(void *context,ABIVirtualInvocation *call,ABIResolutionFailure **error) noexcept {
                try {
                    auto& self=*static_cast<State*>(context);
                    virtual_hook_invocation<R(A...)> invocation(call);
                    auto values=[&]<size_t... I>(std::index_sequence<I...>) { return std::tuple<A...>{virtual_read<A>(call,I)...}; }(std::index_sequence_for<A...>{});
                    if constexpr(std::is_void_v<R>) {
                        std::apply([&](auto... args){ self.body(invocation,args...); },values);
                        return ABIVirtualSetResult(call,nullptr,0,error);
                    } else {
                        R output=std::apply([&](auto... args){ return self.body(invocation,args...); },values);
                        return ABIVirtualSetResult(call,&output,sizeof(output),error);
                    }
                } catch(const resolution_error& e) { *error=ABICreateResolutionFailure(e.code(),e.what()); }
                catch(const std::exception& e) { *error=ABICreateResolutionFailure(ABIFailureOther,e.what()); }
                catch(...) { *error=ABICreateResolutionFailure(ABIFailureOther,"Virtual C++ callback threw."); }
                return false;
            }
        };
        auto state=std::make_unique<State>(std::move(body),std::move(failure));
        auto storage=owner.use_count() ? std::make_unique<std::shared_ptr<const void>>(std::move(owner)) : nullptr;
        auto releaseStorage=storage ? +[](void *p) { delete static_cast<std::shared_ptr<const void>*>(p); } : nullptr;
        auto *handle=ABIInstallSharedVirtualHook(entry,storage.release(),releaseStorage,
            result.get(),parameters.data(),parameters.size(),state.release(),State::invoke,
            [](void *context,const ABIResolutionFailure *error) {
                static_cast<State*>(context)->failure(resolution_error(ABIResolutionFailureCode(error),ABIResolutionFailureMessage(error)));
            },[](void *context) { delete static_cast<State*>(context); });
        auto owned=virtual_hook_handle::adopt(handle);
        if(ABIVirtualHookFailure(handle)) throw virtual_hook_installation_error(owned);
        return owned;
    }
};
}

/// A selected slot. Named selections retain original image metadata; explicit
/// adapters provide ABIVirtualEntryInfo and any independent storage/code owner.
class virtual_entry {
public:
    explicit virtual_entry(ABIVirtualEntryInfo info,std::shared_ptr<const void> owner={}): info_(info), owner_(std::move(owner)) {}
    virtual_entry(const virtual_entry&)=default;
    virtual_entry(virtual_entry&&) noexcept=default;
    virtual_entry& operator=(virtual_entry other) noexcept {
        using std::swap;
        swap(info_,other.info_); owner_.swap(other.owner_); selected_.swap(other.selected_);
        return *this;
    }
    ABIVirtualEntryInfo native_info() const noexcept { return info_; }
    /// The callback describes explicit C-compatible arguments only. It runs on
    /// the incoming thread and affects every object dispatching through this
    /// shared entry. Table/code keepalives remain process-lived after publication.
    template<class Signature,class Body,class OnFailure>
    virtual_hook_handle hook_shared_calls(Body body,OnFailure onFailure) const {
        return detail::virtual_installer<Signature>::install(info_,owner_,std::move(body),std::move(onFailure));
    }
private:
    friend class virtual_table;
    // Destruction and copy-swap assignment release storage before its image.
    std::shared_ptr<ABIVirtualEntry> selected_;
    ABIVirtualEntryInfo info_;
    std::shared_ptr<const void> owner_;
};

/// A borrowed absolute address point with caller-established function bounds.
/// The view does not infer class layout or create per-object shadow tables.
class virtual_table {
public:
    virtual_table(const void *addressPoint,size_t count,std::shared_ptr<const void> owner={})
        :address_(addressPoint),count_(count),owner_(std::move(owner)) {}
    /// Lets Clang authenticate the vptr for this exact static base-subobject type.
    /// The caller supplies the accessible absolute entry count and a live object.
    template<class T> static virtual_table from(T& object,size_t count,std::shared_ptr<const void> owner={}) {
        static_assert(std::is_polymorphic_v<T>,"Use a live polymorphic subobject.");
        return virtual_table(__builtin_get_vtable_pointer(&object),count,std::move(owner));
    }
    /// Selects the original implementation declaration, including qualifiers;
    /// aliases/thunks follow the same rules as Swift NativeVTable.entry(named:).
    virtual_entry entry(const Runtime& runtime,const std::string& name) const {
        if(name.find('\0')!=std::string::npos) throw resolution_error(ABIFailureInvalidRequest,"Declaration contains a NUL.");
        ABIResolutionFailure *error=nullptr;
        std::shared_ptr<ABIVirtualEntry> selected(ABICopyVirtualEntry(runtime.native_handle(),address_,count_,name.c_str(),&error),ABIReleaseVirtualEntry);
        detail::callback_require(selected!=nullptr,error);
        virtual_entry result(ABIVirtualEntryGet(selected.get()),owner_);
        result.selected_=std::move(selected);
        return result;
    }
    /// Uses an explicit native adapter's slot and authentication schema.
    virtual_entry entry(size_t index,int32_t key,uintptr_t discriminator=0,bool addressDiversity=false) const {
        if(index>=count_) throw resolution_error(ABIFailureInvalidRequest,"Virtual entry is outside the declared table.");
        return virtual_entry({address_,count_,index,key,discriminator,addressDiversity},owner_);
    }
private:
    const void *address_;
    size_t count_;
    std::shared_ptr<const void> owner_;
};
}
