#pragma once
#include <ABIBridge/ImportedHooks.h>
#include <ABIBridge/Inspection.hpp>
#include <array>
#include <functional>
#include <tuple>
#include <type_traits>

namespace abi_bridge {
namespace detail {
inline void imported_require(bool ok, ABIResolutionFailure *owned) {
    std::unique_ptr<ABIResolutionFailure,decltype(&ABIReleaseResolutionFailure)> error(owned,ABIReleaseResolutionFailure);
    if (!ok) throw resolution_error(owned ? ABIResolutionFailureCode(owned) : ABIFailureOther,
        owned ? ABIResolutionFailureMessage(owned) : "Imported hook operation failed.");
}
}

/// Specialize make() to return an owned ABIValueType for a naturally laid-out,
/// trivially copyable C structure. Pointers remain borrowed; no ObjC ownership,
/// variadics, C++ references, nontrivial values or native exception unwinding.
template<class T> struct imported_hook_type {
    static ABIValueType *make() {
        using V=std::remove_cv_t<T>;
        int kind=ABIValueVoid;
        if constexpr(std::is_void_v<V>) kind=ABIValueVoid;
        else if constexpr(std::is_same_v<V,float>) kind=ABIValueFloat;
        else if constexpr(std::is_same_v<V,double>) kind=ABIValueDouble;
        else if constexpr(std::is_pointer_v<V>) kind=ABIValuePointer;
        else if constexpr(std::is_integral_v<V>) {
            static_assert(sizeof(V)<=8);
            if constexpr(sizeof(V)==1) kind=std::is_signed_v<V> ? ABIValueInt8 : ABIValueUInt8;
            if constexpr(sizeof(V)==2) kind=std::is_signed_v<V> ? ABIValueInt16 : ABIValueUInt16;
            if constexpr(sizeof(V)==4) kind=std::is_signed_v<V> ? ABIValueInt32 : ABIValueUInt32;
            if constexpr(sizeof(V)==8) kind=std::is_signed_v<V> ? ABIValueInt64 : ABIValueUInt64;
        } else static_assert(!sizeof(V),"Specialize imported_hook_type<T>::make() for this C representation.");
        ABIResolutionFailure *error=nullptr;
        auto *result=ABICreateScalarType(kind,&error); detail::imported_require(result!=nullptr,error); return result;
    }
};

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
        detail::imported_require(ok,error);
        if constexpr(!std::is_void_v<R>) {
            R result{}; error=nullptr;
            const bool copied=ABIImportedCopyResult(call_,&result,sizeof(R),&error);
            detail::imported_require(copied,error);
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
    imported_require(ok,error); return value;
}
template<class T> std::shared_ptr<ABIValueType> imported_type() {
    static_assert(std::is_void_v<T> || std::is_trivially_copyable_v<T>,"Use a native adapter for nontrivial values.");
    auto type=std::shared_ptr<ABIValueType>(imported_hook_type<T>::make(),ABIReleaseValueType);
    if constexpr(!std::is_void_v<T>) if(!type || ABIValueTypeSize(type.get())!=sizeof(T) || ABIValueTypeAlignment(type.get())!=alignof(T))
        throw resolution_error(ABIFailureSignatureMismatch,"C++ type and imported hook layout disagree.");
    return type;
}
template<class Signature> struct imported_installer;
template<class R,class... A> struct imported_installer<R(A...)> {
    template<class Body,class OnFailure> static imported_hook_handle install(const Runtime& runtime,const declaration& query,
        const image_selector& importer,const image_selector *provider,Body body,OnFailure onFailure) {
        static_assert(std::is_nothrow_invocable_v<OnFailure,const resolution_error&>,"Failure handlers must be noexcept.");
        if(query.name.find('\0')!=std::string::npos) throw resolution_error(ABIFailureInvalidRequest,"Declaration contains a NUL.");
        auto result=imported_type<R>(); std::array<std::shared_ptr<ABIValueType>,sizeof...(A)> parameters{imported_type<A>()...};
        std::array<const ABIValueType*,sizeof...(A)> pointers{};
        for(size_t i=0;i<pointers.size();++i) pointers[i]=parameters[i].get();
        struct State {
            Body body; OnFailure failure;
            static bool invoke(void *context,ABIImportedInvocation *call,ABIResolutionFailure **error) noexcept {
                try {
                    auto& self=*static_cast<State*>(context); imported_hook_invocation<R(A...)> invocation(call);
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
