#pragma once
#include <ABIBridge/ImportedHooks.h>
#include <ABIBridge/Inspection.hpp>
#include <ABIBridge/CallbackValues.hpp>
#include <array>
#include <functional>
#include <tuple>
#include <type_traits>

namespace abi_bridge {
/// Copies share a registration; destroying the last owner logically invalidates.
class imported_hook_handle {
public:
    static imported_hook_handle adopt(ABIImportedHook *value) { return imported_hook_handle(value); }
    ABIImportedHook *native_handle() const noexcept { return value_.get(); }
    void invalidate() const { ABIInvalidateImportedHook(value_.get()); }
    size_t size() const { return ABIImportedHookCount(value_.get()); }
    int32_t status(size_t i) const { return ABIImportedHookStatus(value_.get(),i); }
private:
    explicit imported_hook_handle(ABIImportedHook *value):value_(value,ABIReleaseImportedHook) {}
    std::shared_ptr<ABIImportedHook> value_;
};
/// Holds installation failure and the invalidated owner's per-slot effects.
class imported_hook_installation_error : public std::runtime_error {
public:
    explicit imported_hook_installation_error(imported_hook_handle handle):std::runtime_error(
        ABIResolutionFailureMessage(ABIImportedHookFailure(handle.native_handle()))),handle_(std::move(handle)) {}
    size_t failed_index() const { return ABIImportedHookFailedIndex(handle_.native_handle()); }
    const imported_hook_handle& registration() const noexcept { return handle_; }
private:
    imported_hook_handle handle_;
};

template<class Signature> class imported_hook_invocation;
template<class R,class... A> class imported_hook_invocation<R(A...)> {
public:
    explicit imported_hook_invocation(ABIImportedInvocation *call):call_(call) {}
    imported_hook_invocation(const imported_hook_invocation&)=delete;
    imported_hook_invocation& operator=(const imported_hook_invocation&)=delete;
    R proceed(A... values) {
        std::array<void*,sizeof...(A)> pointers{static_cast<void*>(&values)...};
        ABIResolutionFailure *error=nullptr;
        const bool ok=ABIImportedProceed(call_,pointers.data(),pointers.size(),&error);
        detail::callback_require(ok,error);
        if constexpr(!std::is_void_v<R>) {
            R result{}; error=nullptr;
            const bool copied=ABIImportedCopyResult(call_,&result,sizeof(R),&error);
            detail::callback_require(copied,error);
            return result;
        }
    }
private:
    ABIImportedInvocation *call_;
};

namespace detail {
template<class T> T imported_read(ABIImportedInvocation *call,size_t index) {
    T value{}; ABIResolutionFailure *error=nullptr;
    const bool ok=ABIImportedReadArgument(call,index,&value,sizeof(T),&error);
    callback_require(ok,error); return value;
}
template<class Signature,class Body,class OnFailure> struct imported_callback_state;
template<class R,class... A,class Body,class OnFailure>
struct imported_callback_state<R(A...), Body, OnFailure> {
    Body body; OnFailure failure;
    static bool invoke(void *context,ABIImportedInvocation *call,ABIResolutionFailure **error) noexcept {
        try {
            auto& self=*static_cast<imported_callback_state*>(context); imported_hook_invocation<R(A...)> invocation(call);
            auto values=[&]<size_t... I>(std::index_sequence<I...>) { return std::tuple<A...>{imported_read<A>(call,I)...}; }(std::index_sequence_for<A...>{});
            if constexpr(std::is_void_v<R>) {
                std::apply([&](auto... args){ self.body(invocation,args...); },values);
                return ABIImportedSetResult(call,nullptr,0,error);
            } else {
                R output=std::apply([&](auto... args){ return self.body(invocation,args...); },values);
                return ABIImportedSetResult(call,&output,sizeof(output),error);
            }
        } catch(const resolution_error& e) { *error=ABICreateResolutionFailure(e.code(),e.what()); }
        catch(const std::exception& e) { *error=ABICreateResolutionFailure(ABIFailureOther,e.what()); }
        catch(...) { *error=ABICreateResolutionFailure(ABIFailureOther,"Imported C++ callback threw."); }
        return false;
    }
};
template<class Signature> struct imported_installer;
template<class R,class... A> struct imported_installer<R(A...)> {
    template<class Body,class OnFailure> static imported_hook_handle install(const Runtime& runtime,const declaration& query,
        const image_selector& importer,const image_selector *provider,Body body,OnFailure onFailure) {
        static_assert(std::is_nothrow_invocable_v<OnFailure,const resolution_error&>,"Failure handlers must be noexcept.");
        if(query.name.find('\0')!=std::string::npos) throw resolution_error(ABIFailureInvalidRequest,"Declaration contains a NUL.");
        auto result=callback_type<R>(); std::array<std::shared_ptr<ABIValueType>,sizeof...(A)> parameters{callback_type<A>()...};
        std::array<const ABIValueType*,sizeof...(A)> pointers{};
        for(size_t i=0;i<pointers.size();++i) pointers[i]=parameters[i].get();
        using State = imported_callback_state<R(A...), Body, OnFailure>;
        auto state=std::make_unique<State>(State{std::move(body),std::move(onFailure)});
        const ABIDeclaration native{query.name.c_str(),static_cast<int32_t>(query.source_language),static_cast<int32_t>(query.kind),static_cast<int32_t>(query.form)};
        auto importing=importer.native_selector(); auto defining=provider ? provider->native_selector() : ABIImageSelector{};
        auto *handle=ABIInstallImportedFunctionHook(runtime.native_handle(),&native,importing,provider ? &defining : nullptr,
            result.get(),pointers.data(),pointers.size(),state.release(),State::invoke,
            [](void *context,const ABIResolutionFailure *error) {
                static_cast<State*>(context)->failure(resolution_error(ABIResolutionFailureCode(error),ABIResolutionFailureMessage(error)));
            },[](void *context){ delete static_cast<State*>(context); });
        auto owned=imported_hook_handle::adopt(handle);
        if(ABIImportedHookFailure(handle)) throw imported_hook_installation_error(owned);
        return owned;
    }
};
}

/// Hooks the selected imported C ABI references. The callback receives a scoped
/// continuation and ordinary values; it must respect the target's caller thread.
template<class Signature,class Body,class OnFailure>
imported_hook_handle hook_imported_function(const Runtime& runtime,const declaration& query,const image_selector& importer,
    Body body,OnFailure onFailure,const image_selector *provider=nullptr) {
    return detail::imported_installer<Signature>::install(runtime,query,importer,provider,std::move(body),std::move(onFailure));
}
}
