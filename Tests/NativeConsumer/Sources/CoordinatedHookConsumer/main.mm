#include <ABIBridge/ObjectiveCHooks.hpp>
#include <HookFixture.h>
#include <CoordinationFixture.h>
#include <cassert>
#include <atomic>
#include <cstdio>
#include <future>
#include <thread>

@interface ABIBatchActivationFixture : ABINativeHookFixture @end
@implementation ABIBatchActivationFixture @end

static std::atomic<int> released{0};
static void releaseContext(void *) { ++released; }
static void noFailure(void *, const ABIResolutionFailure *) { assert(false); }
static bool pass(void *, ABIObjCHookInvocation *call, ABIResolutionFailure **error) {
    return ABIObjCHookProceed(call, nullptr, 0, error);
}
int main() {
    auto failed = [](const abi_bridge::resolution_error&) noexcept { assert(false); };
    @autoreleasepool {
        auto request = abi_bridge::objc_hook_request::method<int32_t(int32_t,int32_t)>(ABIHookFixtureClass(), "add:to:",
            [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) + 1; }, failed);
        auto invalid = abi_bridge::objc_hook_request::method<int32_t()>(ABIHookFixtureClass(), "absentSelector", [](auto&) { return 0; }, failed);
        const auto method = class_getInstanceMethod(ABIHookFixtureClass(), sel_registerName("add:to:"));
        const auto original = method_getImplementation(method);
        try { (void)abi_bridge::install_objc_hooks({request,invalid}); assert(false); }
        catch (const abi_bridge::objc_hook_installation_error& error) {
            assert(error.failed_index() == 1 && error.phase() == ABIObjCHookPreparation);
            assert(error.invalidated_hooks().empty() && error.cause().code() == ABIFailureDeclarationNotFound);
        }
        assert(method_getImplementation(method) == original);
        auto hooks = abi_bridge::install_objc_hooks({request,request});
        auto overlap = abi_bridge::install_objc_hooks({request});
        auto object = std::shared_ptr<void>(ABIHookFixtureCreate(0), ABIHookFixtureRelease);
        assert(ABIHookFixtureAdd(object.get(),20,19) == 42);
        for (auto& hook : hooks) hook.invalidate();
        assert(ABIHookFixtureAdd(object.get(),20,21) == 42);
        overlap.clear();
        assert(ABIHookFixtureAdd(object.get(),20,22) == 42);
        assert(abi_bridge::install_objc_hooks({}).empty());
        const auto saved = method_getImplementation(method);
        for (int i = 0; i != 4; ++i) {
            auto again = abi_bridge::install_objc_hooks({request});
            assert(method_getImplementation(method) == saved);
        }
        auto initializer = abi_bridge::objc_hook_request::initializer<ABINativeHookFixture *(int32_t)>(ABIHookFixtureClass(), "initWithSeed:",
            [](int32_t value) { return value + 1; }, [](ABINativeHookFixture *value) { value.seed += 1; }, failed);
        auto mixed = abi_bridge::install_objc_hooks({request,initializer});
        assert([[ABINativeHookFixture alloc] initWithSeed:40].seed == 42);
        mixed.clear();

        auto existing = abi_bridge::objc_method_hook<int32_t()>(ABIBatchActivationFixture.class, "seed", [](auto& call) { return call.proceed() + 1; }, failed);
        Method seedMethod = class_getInstanceMethod(ABIBatchActivationFixture.class, @selector(seed));
        IMP seedOriginal = method_getImplementation(seedMethod);
        IMP external = imp_implementationWithBlock(^int32_t(id value) { return 99; });
        ABICoordinationOwner *owner = [ABICoordinationOwner new];
        abi_bridge::objc_hook_options options; options.fallback_owner = owner;
        auto first = abi_bridge::objc_hook_request::method<int32_t(int32_t,int32_t)>(ABIBatchActivationFixture.class, "add:to:",
            [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) + 1; }, failed, options);
        auto second = abi_bridge::objc_hook_request::method<int32_t()>(ABIBatchActivationFixture.class, "seed", [](auto& call) { return call.proceed() + 2; }, failed);
        std::vector<abi_bridge::objc_hook_request> batch{first,second};
        owner.onRetain = ^{ method_setImplementation(seedMethod, external); };
        try { (void)abi_bridge::install_objc_hooks(batch); assert(false); }
        catch (const abi_bridge::objc_hook_installation_error& error) {
            if (error.failed_index() != 1 || error.phase() != ABIObjCHookActivation)
                std::fprintf(stderr, "Activation case failed at %zu, phase %d: %s\n", error.failed_index(), error.phase(), error.what());
            assert(error.failed_index() == 1 && error.phase() == ABIObjCHookActivation);
            assert(error.invalidated_hooks().size() == 1 && error.invalidated_hooks()[0].status() == abi_bridge::objc_hook_status::invalidated);
            assert(error.cause().code() == ABIFailureHookDisplaced);
        }
        assert(existing.status() == abi_bridge::objc_hook_status::displaced && method_getImplementation(seedMethod) == external);
        method_setImplementation(seedMethod,seedOriginal); imp_removeBlock(external);
        assert(existing.status() == abi_bridge::objc_hook_status::active);
        assert([[ABIBatchActivationFixture alloc] initWithSeed:41].seed == 42);
        existing.invalidate();

        ABIObjCHookValueType integer{"i",4,4};
        ABIObjCHookValueType parameters[]{integer,integer};
        ABIObjCHookSignature signature{integer,parameters,2};
        ABIObjCHookRequest native[3]{};
        for (auto& value : native) {
            value.type = ABIHookFixtureClass(); value.selector = "add:to:"; value.signature = &signature;
            value.callback = pass; value.onFailure = noFailure; value.releaseContext = releaseContext;
        }
        native[1].selector = "absentSelector";
        auto result = ABIInstallObjCHooks(native,3);
        assert(ABIObjCHookInstallationFailure(result) && ABIObjCHookInstallationFailedIndex(result) == 1);
        assert(ABIObjCHookInstallationCount(result) == 0 && released == 3);
        ABIReleaseObjCHookInstallation(result);
        native[1].selector = "add:to:";
        result = ABIInstallObjCHooks(native,3);
        assert(!ABIObjCHookInstallationFailure(result) && ABIObjCHookInstallationFailedIndex(result) == SIZE_MAX);
        assert(ABIObjCHookInstallationCount(result) == 3);
        auto alias = ABIRetainObjCMethodHook(ABIObjCHookInstallationGet(result,0));
        ABIInvalidateObjCHookInstallation(result); ABIInvalidateObjCHookInstallation(result);
        assert(released == 6 && ABIObjCMethodHookStatus(alias) == ABIObjCHookInvalidated);
        ABIReleaseObjCHookInstallation(result); ABIReleaseObjCMethodHook(alias);
        native[1].releaseContext = nullptr;
        result = ABIInstallObjCHooks(native,3);
        assert(ABIObjCHookInstallationFailure(result) && released == 6);
        ABIReleaseObjCHookInstallation(result);
    }
    std::puts("Coordinated C/C++ hook consumer passed");
}
