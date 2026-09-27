#pragma once
#include <ABIBridge/ImportedHookMonitoring.h>
#include <ABIBridge/ImportedHooks.hpp>
#include <optional>
#include <algorithm>

namespace abi_bridge {
/// Copied asynchronous image outcome. Hook owners preserve partial effects.
struct imported_image_update {
    image_description image;
    int32_t state;
    std::optional<imported_hook_handle> hook;
    std::optional<resolution_error> failure;

    explicit imported_image_update(ABIImportedImageUpdate value)
        : image{{value.image.header, value.image.slide, value.image.generation}, {}, value.image.path}, state(value.state) {
        std::copy_n(value.image.uuid, 16, image.uuid.begin());
        if (value.hook) hook = imported_hook_handle::adopt(ABIRetainImportedHook(value.hook));
        if (value.failure) failure.emplace(ABIResolutionFailureCode(value.failure), ABIResolutionFailureMessage(value.failure));
    }
};

/// Copies share the monitor; last-owner destruction stops future application.
class imported_hook_monitor {
public:
    static imported_hook_monitor adopt(ABIImportedHookMonitor *value) { return imported_hook_monitor(value); }
    void invalidate() const { ABIInvalidateImportedHookMonitor(value_.get()); }
    std::vector<imported_image_update> images() const {
        std::unique_ptr<ABIImportedImageList, decltype(&ABIReleaseImportedImageList)> snapshot(
            ABICopyImportedHookMonitorImages(value_.get()), ABIReleaseImportedImageList);
        std::vector<imported_image_update> result;
        for (size_t i=0; i<ABIImportedImageListCount(snapshot.get()); ++i) result.emplace_back(ABIImportedImageListGet(snapshot.get(), i));
        return result;
    }
    ABIImportedHookMonitor *native_handle() const noexcept { return value_.get(); }
private:
    explicit imported_hook_monitor(ABIImportedHookMonitor *value):value_(value, ABIReleaseImportedHookMonitor) {}
    std::shared_ptr<ABIImportedHookMonitor> value_;
};

namespace detail {
template<class Signature> struct imported_monitor_factory;
template<class R,class... A> struct imported_monitor_factory<R(A...)> {
    template<class Body,class OnFailure,class OnImageUpdate>
    static imported_hook_monitor create(const declaration& query, const image_selector& importer,
        const image_selector *provider, Body body, OnFailure onFailure, OnImageUpdate onImageUpdate) {
        static_assert(std::is_nothrow_invocable_v<OnFailure,const resolution_error&>, "Failure handlers must be noexcept.");
        static_assert(std::is_nothrow_invocable_v<OnImageUpdate,const imported_image_update&>, "Image handlers must be noexcept.");
        if (query.name.find('\0') != std::string::npos) throw resolution_error(ABIFailureInvalidRequest, "Declaration contains a NUL.");
        auto result = callback_type<R>();
        std::array<std::shared_ptr<ABIValueType>,sizeof...(A)> parameters{callback_type<A>()...};
        std::array<const ABIValueType*,sizeof...(A)> pointers{};
        for (size_t i=0; i<pointers.size(); ++i) pointers[i]=parameters[i].get();
        using Callback = imported_callback_state<R(A...),Body,OnFailure>;
        struct State : Callback { OnImageUpdate update; };
        auto state = std::make_unique<State>(State{Callback{std::move(body),std::move(onFailure)},std::move(onImageUpdate)});
        const ABIDeclaration native{query.name.c_str(),static_cast<int32_t>(query.source_language),static_cast<int32_t>(query.kind),static_cast<int32_t>(query.form)};
        auto importing=importer.native_selector(); auto defining=provider ? provider->native_selector() : ABIImageSelector{};
        ABIResolutionFailure *error=nullptr;
        auto *handle=ABIMonitorImportedFunction(&native, importing, provider ? &defining : nullptr,
            result.get(), pointers.data(), pointers.size(), state.release(),
            [](void *context, ABIImportedInvocation *call, ABIResolutionFailure **error) {
                return Callback::invoke(static_cast<Callback*>(static_cast<State*>(context)),call,error);
            }, [](void *context, const ABIResolutionFailure *error) {
                static_cast<State*>(context)->failure(resolution_error(ABIResolutionFailureCode(error),ABIResolutionFailureMessage(error)));
            }, [](void *context, ABIImportedImageUpdate update) {
                static_cast<State*>(context)->update(imported_image_update(update));
            }, [](void *context) { delete static_cast<State*>(context); }, &error);
        callback_require(handle != nullptr, error);
        return imported_hook_monitor::adopt(handle);
    }
};
}

/// Applies hooks asynchronously to selected current and future imports. Image
/// callbacks run serially, outside dyld notifications, and may begin before
/// return. Constructor calls and transient loads can precede installation.
template<class Signature,class Body,class OnFailure,class OnImageUpdate>
imported_hook_monitor monitor_imported_function(const declaration& query, const image_selector& importer,
    Body body, OnFailure onFailure, OnImageUpdate onImageUpdate, const image_selector *provider=nullptr) {
    return detail::imported_monitor_factory<Signature>::create(query,importer,provider,
        std::move(body),std::move(onFailure),std::move(onImageUpdate));
}
}
