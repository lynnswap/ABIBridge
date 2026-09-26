#include <ABIBridge/Inspection.hpp>
#include <ABIBridge/NativeInvocation.hpp>
#include <atomic>
#include <cassert>
#include <iostream>
#include <thread>
#include <unistd.h>
#include <vector>

static std::atomic<unsigned> initializationCount = 0;
extern "C" __attribute__((used)) void ABIBridgeLoadingDidInitialize() {
    // Reenter the same resolver while dyld is executing the new library's
    // constructor. Neither the catalog nor index lock may span dlopen.
    auto runtime = abi_bridge::Runtime::current();
    auto pid = abi_bridge::function<pid_t()>(runtime.resolve({"getpid", abi_bridge::language::c}));
    assert(pid.unsafe_invoke() == getpid());
    runtime.remove_cached_results();
    ++initializationCount;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    using namespace abi_bridge;
    auto runtime = Runtime::current();
    const auto scope = image_selector::install_name("@rpath/libLoadingFixture.dylib");
    const declaration query("ABIBridgeLoadedValue", language::c);
    try {
        runtime.resolve(query, scope, image_loading::loaded_only);
        assert(false && "An unopened install name must not load in inspection mode");
    } catch (const resolution_error& error) { assert(error.code() == ABIFailureImageNotLoaded); }
    assert(initializationCount == 0);
    auto symbol = runtime.resolve(query, scope);
    auto value = function<int()>(symbol);
    assert(value.unsafe_invoke() == 42 && initializationCount == 1);
    auto absolute = runtime.resolve(query, image_selector::path(argv[1]));
    assert(absolute.image().load_generation == symbol.image().load_generation);
    auto hidden = function<int()>(runtime.resolve({"ABIBridgeLoading::hiddenValue()"}, scope));
    assert(hidden.unsafe_invoke() == 42);
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 4; ++i) {
        threads.emplace_back([&] {
            for (unsigned j = 0; j < 20; ++j) {
                auto function = abi_bridge::function<int()>(runtime.resolve(query, scope));
                assert(function.unsafe_invoke() == 42);
            }
        });
    }
    for (auto& thread : threads) thread.join();
    runtime.remove_cached_results();
    assert(value.unsafe_invoke() == 42 && hidden.unsafe_invoke() == 42);
    assert(initializationCount == 1);
    std::cout << "Automatic loading consumer passed: rpath, initialization, reentrancy, concurrency, local symbols, and lifetime.\n";
}
