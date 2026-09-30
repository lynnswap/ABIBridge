#include <ABIBridge/ObjectiveCHooks.hpp>
#include <HookFixture.h>
#include <cassert>
#include <cstdio>
#include <objc/message.h>

int main() {
    int failures = 0;
    auto failed = [&](const abi_bridge::resolution_error&) noexcept { ++failures; };
    @autoreleasepool {
        ABINativeHookFixture *object = [[ABINativeHookFixture alloc] initWithSeed:0];
        abi_bridge::objc_hook_options ordinary;
        ordinary.returns_retained = false;
        ordinary.consumes_receiver = false;
        for (const char *name : {"ordinaryValue", "initNamedValue", "allocNamedValue"}) {
            auto invoke = [&] {
                return reinterpret_cast<NSObject *(*)(id, SEL)>(objc_msgSend)(object, sel_registerName(name));
            };
            assert(invoke() == object);
            int calls = 0;
            auto hook = abi_bridge::objc_method_hook<NSObject *()>(ABINativeHookFixture.class, name,
                [&](auto& call) { ++calls; return call.proceed(); }, failed, ordinary);
            assert(invoke() == object && calls == 1);
            hook.invalidate();
        }
        ordinary.returns_retained = true;
        auto retained = abi_bridge::objc_method_hook<NSObject *()>(ABINativeHookFixture.class, "initRetainedValue",
            [](auto& call) { return call.proceed(); }, failed, ordinary);
        {
            NSObject *value = [object initRetainedValue];
            assert(value == object);
#if !__has_feature(objc_arc)
            [value release];
#endif
        }
        retained.invalidate();
        auto copies = abi_bridge::objc_method_hook<ABINativeHookResult *()>(ABINativeHookFixture.class, "copyObject",
            [](auto& call) {
                ABINativeHookResult *first = call.proceed();
                ABINativeHookResult *second = call.proceed();
                assert(first != second && ABINativeHookResult.liveObjects == 2);
                return first;
            }, failed);
        {
            ABINativeHookResult *result = [object copyObject];
            assert(result != nil);
#if !__has_feature(objc_arc)
            [result release];
#endif
        }
        copies.invalidate();
        using Block = int32_t (^)(int32_t);
        auto blocks = abi_bridge::objc_method_hook<Block()>(ABINativeHookFixture.class, "block",
            [](auto& call) -> Block {
                Block original = call.proceed();
                Block changed = ^(int32_t value) { return original(value) + 2; };
#if __has_feature(objc_arc)
                return changed;
#else
                return [[changed copy] autorelease];
#endif
            }, failed);
        Block block = [object block];
        assert(block(39) == 42);
        blocks.invalidate();
        auto scoped = abi_bridge::objc_object_hook<int32_t(int32_t, int32_t)>(object, "add:to:",
            [](auto& call, int32_t a, int32_t b) { assert(call.receiver()); return call.proceed(a,b) + 1; }, failed);
        ABINativeHookFixture *other = [[ABINativeHookFixture alloc] initWithSeed:0];
        assert([object add:20 to:21] == 42 && [other add:20 to:21] == 41);
        scoped.invalidate();
        auto initializer = abi_bridge::objc_initializer_hook<ABINativeHookFixture *(int32_t)>(
            ABINativeHookFixture.class, "initWithSeed:", [](int32_t seed) { return seed < 0 ? seed : seed + 1; },
            [](ABINativeHookFixture *result) { if (result) result.seed += 40; }, failed);
        ABINativeHookFixture *initialized = [[ABINativeHookFixture alloc] initWithSeed:1];
        assert(initialized.seed == 42 && [[ABINativeHookFixture alloc] initWithSeed:-1] == nil);
        initializer.invalidate();
        auto coordinated = abi_bridge::install_objc_hooks({
            abi_bridge::objc_hook_request::method<ABINativeHookResult *()>(ABINativeHookFixture.class, "copyObject",
                [](auto& call) { return call.proceed(); }, failed)
        });
        {
            ABINativeHookResult *value = [object copyObject];
            assert(value);
#if !__has_feature(objc_arc)
            [value release];
#endif
        }
        coordinated.clear();
#if !__has_feature(objc_arc)
        [initialized release]; [other release]; [object release];
#endif
    }
    assert(ABINativeHookResult.liveObjects == 0 && failures == 0);
#if __has_feature(objc_arc)
    std::puts("ARC Objective-C++ hook consumer passed");
#else
    std::puts("MRC Objective-C++ hook consumer passed");
#endif
}
