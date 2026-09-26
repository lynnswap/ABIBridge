#include <ABIBridge/ObjectiveCHooks.hpp>
#include <HookFixture.h>
#include <cassert>
#include <atomic>
#include <cstdio>
#include <thread>
#include <future>
namespace abi_bridge {
template <> struct objc_hook_type<ABIHookPair> { static const char *encoding() { return "{ABIHookPair=dd}"; } };
}

int main() {
    std::atomic<int> failures{0};
    auto failed = [&](const abi_bridge::resolution_error&) noexcept { ++failures; };
    auto object = std::shared_ptr<void>(ABIHookFixtureCreate(0), ABIHookFixtureRelease);
    auto capture = std::make_shared<int>(1);
    std::weak_ptr<int> observed = capture;
    auto first = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [capture](auto& call, int32_t a, int32_t b) { return call.proceed(a, b) + *capture; }, failed);
    capture.reset();
    auto second = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [](auto& call, int32_t a, int32_t b) { return call.proceed(a, b) * 2; }, failed);
    auto copied = second;
    auto moved = std::move(second);
    assert(!second && ABIHookFixtureAdd(object.get(), 20, 21) == 84);
    moved.invalidate();
    assert(copied.status() == abi_bridge::objc_hook_status::invalidated);
    assert(ABIHookFixtureAdd(object.get(), 20, 21) == 42);
    first.invalidate(); assert(observed.expired());
    auto checked = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [](auto& call, int32_t a, int32_t b) {
            bool rejected = false;
            std::thread other([&] {
                try { (void)call.receiver(); }
                catch (const abi_bridge::resolution_error& error) { rejected = error.code() == ABIFailureWrongThread; }
            }); other.join(); assert(rejected);
            return call.proceed(a, b);
        }, failed);
    assert(ABIHookFixtureAdd(object.get(), 20, 22) == 42); checked.invalidate();
    auto throws = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [](auto& call, int32_t a, int32_t b) -> int32_t { (void)call.proceed(a,b); throw std::runtime_error("callback"); }, failed);
    const auto calls = ABIHookFixtureCalls(object.get());
    assert(ABIHookFixtureAdd(object.get(), 20, 22) == 42 && ABIHookFixtureCalls(object.get()) == calls + 1);
    throws.invalidate(); assert(failures == 1);
    auto aggregate = abi_bridge::objc_method_hook<ABIHookPair(ABIHookPair)>(ABIHookFixtureClass(), "shift:",
        [](auto& call, ABIHookPair value) { auto result = call.proceed(value); result.x += 1; return result; }, failed);
    const auto pair = ABIHookFixtureShift(object.get(), {20,20});
    assert(pair.x == 22 && pair.y == 22); aggregate.invalidate();
    auto held = std::make_shared<int>(1); std::weak_ptr<int> weak = held;
    std::promise<void> entered, resume;
    auto wait = resume.get_future().share();
    auto live = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [held, &entered, wait](auto& call, int32_t a, int32_t b) {
            entered.set_value(); wait.wait(); return call.proceed(a,b) + *held;
        }, failed);
    held.reset();
    std::thread caller([&] { assert(ABIHookFixtureAdd(object.get(), 20,21) == 42); });
    entered.get_future().wait(); live.invalidate(); live = {};
    assert(!weak.expired()); resume.set_value(); caller.join(); assert(weak.expired());
    abi_bridge::objc_hook_options main;
    main.requires_main_thread = true;
    auto onlyMain = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIHookFixtureClass(), "add:to:",
        [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) + 1; }, failed, main);
    std::thread background([&] { assert(ABIHookFixtureAdd(object.get(), 20,22) == 42); }); background.join();
    assert(failures == 2); onlyMain.invalidate();
    auto initializer = abi_bridge::objc_initializer_hook<id(int32_t)>(ABIHookFixtureClass(), "initWithSeed:",
        [](int32_t seed) { return seed < 0 ? seed : seed + 1; },
        [](id value) { if (value) ABIHookFixtureSetSeed(value, ABIHookFixtureSeed(value) + 40); }, failed);
    auto result = std::shared_ptr<void>(ABIHookFixtureCreate(1), ABIHookFixtureRelease);
    assert(ABIHookFixtureSeed(result.get()) == 42 && ABIHookFixtureCreate(-1) == nullptr);
    initializer.invalidate();
    auto requests = std::vector<abi_bridge::objc_hook_request>{
        abi_bridge::objc_hook_request::method<int32_t(int32_t,int32_t)>(ABIHookFixtureClass(), "add:to:",
            [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) + 1; }, failed)
    };
    auto coordinated = abi_bridge::install_objc_hooks(requests);
    assert(ABIHookFixtureAdd(object.get(),20,21) == 42);
    coordinated.clear();
    assert(ABIHookFixtureAdd(object.get(),20,22) == 42);
    std::puts("C++ hook consumer passed");
}
