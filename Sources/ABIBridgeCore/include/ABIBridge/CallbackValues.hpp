#pragma once
#include <ABIBridge/Invocation.h>
#include <ABIBridge/Inspection.hpp>
#include <type_traits>

namespace abi_bridge {
namespace detail {
inline void callback_require(bool ok, ABIResolutionFailure *owned) {
    std::unique_ptr<ABIResolutionFailure,decltype(&ABIReleaseResolutionFailure)> error(owned,ABIReleaseResolutionFailure);
    if (!ok) throw resolution_error(owned ? ABIResolutionFailureCode(owned) : ABIFailureOther,
        owned ? ABIResolutionFailureMessage(owned) : "Native callback operation failed.");
}
}

/// Specialize make() to return an owned ABIValueType for a naturally laid-out,
/// trivially copyable C structure. Pointers remain borrowed; no ObjC ownership,
/// variadics, C++ references, nontrivial values or native exception unwinding.
template<class T> struct callback_value_type {
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
        } else static_assert(!sizeof(V),"Specialize callback_value_type<T>::make() for this C representation.");
        ABIResolutionFailure *error=nullptr;
        auto *result=ABICreateScalarType(kind,&error); detail::callback_require(result!=nullptr,error); return result;
    }
};

namespace detail {
template<class T> std::shared_ptr<ABIValueType> callback_type() {
    static_assert(std::is_void_v<T> || std::is_trivially_copyable_v<T>,"Use a native adapter for nontrivial values.");
    auto type=std::shared_ptr<ABIValueType>(callback_value_type<T>::make(),ABIReleaseValueType);
    if constexpr(!std::is_void_v<T>) if(!type || ABIValueTypeSize(type.get())!=sizeof(T) || ABIValueTypeAlignment(type.get())!=alignof(T))
        throw resolution_error(ABIFailureSignatureMismatch,"C++ type and callback layout disagree.");
    return type;
}
}
}
