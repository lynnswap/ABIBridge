#include <ABIBridge/ABIBridge.hpp>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "../../FixtureTypes.hpp"

struct ABIBridgeLocalCounter {
    int value;
    int add(int delta);
};
int ABIBridgeLocalCounter::add(int delta) { return value += delta; }

static bool unloadCallbackRan = false;
static void onLibraryUnload() {
    abi_bridge::InvocationRuntime::current().remove_cached_results();
    unloadCallbackRan = true;
}

namespace ABIBridgeReadinessFixture {
int shared() { return 41; }
}

static std::string constructorPath;
static uint64_t constructorGeneration = 0;
extern "C" void ABIBridgeTestConstructorEntered(const void *initializer) {
    Dl_info info{};
    assert(dladdr(initializer, &info) && info.dli_fbase);
    auto* images = ABICopyLoadedImages();
    assert(images);
    for (size_t i = 0; i < ABIImageListCount(images); ++i) {
        const auto image = ABIImageListGet(images, i);
        if (image.header == reinterpret_cast<uintptr_t>(info.dli_fbase)) constructorGeneration = image.generation;
    }
    ABIFreeImageList(images);
    assert(constructorGeneration != 0);
    abi_bridge::InvocationRuntime::current().remove_cached_results();
    std::thread worker([] {
        auto runtime = abi_bridge::InvocationRuntime::current();
        assert(runtime.c_function<pid_t()>("getpid").unsafe_invoke() == getpid());
        assert(runtime.cxx_function<int()>(abi_bridge::declaration("ABIBridgeReadinessFixture::shared()"))
                   .unsafe_invoke() == 41);
        const abi_bridge::declaration pending("ABIBridgeReadinessFixture::pendingOnly()");
        for (const auto& scope : {abi_bridge::image_selector::automatic(), abi_bridge::image_selector::path(constructorPath)}) {
            try {
                runtime.resolve(pending, scope, abi_bridge::image_loading::loaded_only);
                assert(false && "An initializing image is not available to this thread");
            } catch (const abi_bridge::resolution_error& error) {
                assert(error.code() == ABIFailureImageUnavailable);
            }
        }
        const abi_bridge::declaration absent("ABIBridgeReadinessFixture::absentAlias()");
        const abi_bridge::declaration pid("getpid", abi_bridge::language::c);
        abi_bridge::symbol_request available{pid};
        available.alternatives = {absent};
        abi_bridge::symbol_request alias{absent};
        alias.alternatives = {pid};
        abi_bridge::symbol_request unavailable{pending};
        auto batch = abi_bridge::Runtime::current().resolve(std::vector{available, alias, unavailable});
        assert(std::holds_alternative<abi_bridge::resolved_symbol>(batch[0]));
        assert(std::holds_alternative<abi_bridge::resolved_symbol>(batch[1]));
        assert(std::get<abi_bridge::resolution_error>(batch[2]).code() == ABIFailureImageUnavailable);
    });
    // Hold initialization open until every lookup has finished, without a race
    // against a sleep duration. The watchdog detects any accidental loader wait.
    worker.join();
}

int main(int argc, char** argv) {
    assert(argc == 3);
    const std::string path = argv[1];
    const auto scope = abi_bridge::image_selector::path(path);
    auto runtime = abi_bridge::InvocationRuntime::current();
    auto pid = runtime.c_function<pid_t()>("getpid");
    assert(pid.unsafe_invoke() == getpid());

    std::mutex watchdogMutex;
    std::condition_variable watchdogCondition;
    bool constructorFinished = false;
    std::thread watchdog([&] {
        std::unique_lock lock(watchdogMutex);
        if (!watchdogCondition.wait_for(lock, std::chrono::seconds(30), [&] { return constructorFinished; })) {
            std::cerr << "Constructor/reentrant resolution timed out.\n";
            std::_Exit(1);
        }
    });
    constructorPath = argv[2];
    void* constructorLibrary = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    assert(constructorLibrary);
    // No cache clearing or image reload separates the two phases.
    {
        auto initialized = runtime.cxx_function<int()>(abi_bridge::declaration("ABIBridgeReadinessFixture::pendingOnly()"));
        assert(initialized.unsafe_invoke() == 29);
        assert(initialized.symbol().image().load_generation == constructorGeneration);
        try {
            runtime.resolve(abi_bridge::declaration("ABIBridgeReadinessFixture::shared()"));
            assert(false && "Both initialized definitions must now be ambiguous");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureAmbiguousDeclaration);
        }
    }
    assert(runtime.c_function<pid_t()>("getpid").unsafe_invoke() == getpid());
    assert(dlclose(constructorLibrary) == 0);
    {
        std::lock_guard lock(watchdogMutex);
        constructorFinished = true;
    }
    watchdogCondition.notify_one();
    watchdog.join();
    runtime.remove_cached_results();

    try {
        runtime.c_function<int(int, int)>("ABIBridgeFixtureCAdd", scope, abi_bridge::image_loading::loaded_only);
        assert(false && "Unloaded images must be reported");
    } catch (const abi_bridge::resolution_error& error) {
        assert(error.code() == ABIFailureImageNotLoaded);
    }

    void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(library);
    {
        auto retained = [&] {
            runtime.c_function<void(void (*)())>("ABIBridgeFixtureSetUnloadCallback", scope)
                .unsafe_invoke(onLibraryUnload);
            auto add = runtime.cxx_function<int(int, int)>(
                abi_bridge::declaration("ABIBridgeFixture::add(int, int)"), scope);
            assert(add.unsafe_invoke(20, 22) == 42);
            assert(add.symbol().image().load_generation != 0);
            assert(std::filesystem::equivalent(add.symbol().image_path(), path));
            auto cAdd = runtime.c_function<int(int, int)>("ABIBridgeFixtureCAdd", scope);
            assert(cAdd.unsafe_invoke(20, 22) == 42);
            auto multiply = runtime.cxx_function<double(double, double)>(
                abi_bridge::declaration("ABIBridgeFixture::multiply(double, double)"), scope);
            assert(multiply.unsafe_invoke(1.5, 2.0) == 3.0);

            int value = 41;
            auto increment = runtime.cxx_function<void(int&)>(
                abi_bridge::declaration("ABIBridgeFixture::increment(int&)"), scope);
            increment.unsafe_invoke(value);
            assert(value == 42);
            auto identity = runtime.cxx_function<int&(int&)>(
                abi_bridge::declaration("ABIBridgeFixture::identity(int&)"), scope);
            assert(&identity.unsafe_invoke(value) == &value);

            const std::string stringType = "std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char>>";
            auto greet = runtime.cxx_function<std::string(std::string)>(
                abi_bridge::declaration("ABIBridgeFixture::greet(" + stringType + ")"), scope);
            assert(greet.unsafe_invoke("world") == "Hello, world");
            auto consume = runtime.cxx_function<std::string(std::string&&)>(
                abi_bridge::declaration("ABIBridgeFixture::consume(" + stringType + "&&)"), scope);
            std::string input = "native value";
            assert(consume.unsafe_invoke(std::move(input)) == "native value");
            assert(input == "consumed");

            auto addValue = runtime.cxx_method<int(int)>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::add(int)"), scope);
            auto current = runtime.cxx_method<int() const>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::current() const"), scope);
            ABIBridgeFixture::Counter counter{40};
            assert(addValue.unsafe_invoke(&counter, 2) == 42);
            assert(current.unsafe_invoke(&counter) == 42);
            auto reference = runtime.cxx_method<int&()>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::reference()"), scope);
            assert(&reference.unsafe_invoke(&counter) == &counter.value);
            auto describe = runtime.cxx_method<std::string(std::string) const>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::describe(" + stringType + ") const"), scope);
            assert(describe.unsafe_invoke(&counter, "value: ") == "value: 42");
            auto memberLarge = runtime.cxx_method<ABIBridgeFixture::LargeResult() const>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::large() const"), scope);
            assert(memberLarge.unsafe_invoke(&counter).words[7] == 49);

            int extra = 3;
            auto many = runtime.cxx_method<double(int, int, int, int, int, int, int, int, int, int, double, const int&) const>(
                abi_bridge::declaration("ABIBridgeFixture::Counter::many(int, int, int, int, int, int, int, int, int, int, double, int const&) const"), scope);
            assert(many.unsafe_invoke(&counter, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5, extra) == 50.0);

            int destroyed = 0;
            std::weak_ptr<ABIBridgeFixture::Combined> weakOwner;
            {
                auto owner = std::shared_ptr<ABIBridgeFixture::Combined>(
                    new ABIBridgeFixture::Combined{}, [&](auto* object) { ++destroyed; delete object; });
                owner->value = 40;
                weakOwner = owner;
                auto* receiver = static_cast<ABIBridgeFixture::Counter*>(owner.get());
                assert(static_cast<void*>(receiver) != static_cast<void*>(owner.get()));
                auto alias = std::shared_ptr<ABIBridgeFixture::Counter>(owner, receiver);
                auto bound = addValue.bind(alias);
                auto getter = current.bind(std::shared_ptr<const ABIBridgeFixture::Counter>(alias));
                owner.reset();
                alias.reset();
                assert(!weakOwner.expired());
                auto copy = bound;
                assert(copy.unsafe_invoke(2) == 42);
                assert(getter.unsafe_invoke() == 42);
            }
            assert(weakOwner.expired() && destroyed == 1);
            try {
                addValue.bind(std::shared_ptr<ABIBridgeFixture::Counter>{});
                assert(false && "An empty shared pointer cannot bind a receiver");
            } catch (const abi_bridge::resolution_error& error) {
                assert(error.code() == ABIFailureInvalidRequest);
            }

            auto large = runtime.cxx_function<ABIBridgeFixture::LargeResult(long)>(
                abi_bridge::declaration("ABIBridgeFixture::large(long)"), scope);
            auto result = large.unsafe_invoke(35);
            assert(result.words[0] == 35 && result.words[7] == 42);

            try {
                runtime.cxx_function<int()>(abi_bridge::declaration("ABIBridgeFixture::counter"), scope);
                assert(false && "Data must not be callable");
            } catch (const abi_bridge::resolution_error& error) {
                assert(error.code() == ABIFailureInvalidAddress);
            }
            try {
                runtime.c_function<int()>("ABIBridgeFixtureMissing", scope);
                assert(false && "Missing symbols must be reported");
            } catch (const abi_bridge::resolution_error& error) {
                assert(error.code() == ABIFailureDeclarationNotFound);
                assert(std::strstr(error.what(), "ABIBridgeFixtureMissing"));
            }

            std::vector<std::thread> threads;
            for (int i = 0; i < 4; ++i) {
                threads.emplace_back([&] {
                    for (int iteration = 0; iteration < 10; ++iteration) {
                        auto function = runtime.cxx_function<int(int, int)>(
                            abi_bridge::declaration("ABIBridgeFixture::add(int, int)"), scope);
                        assert(function.unsafe_invoke(20, 22) == 42);
                        runtime.remove_cached_results();
                    }
                });
            }
            for (auto& thread : threads) thread.join();

            auto independent = [&] {
                abi_bridge::InvocationRuntime temporary;
                return temporary.cxx_function<int(int, int)>(
                    abi_bridge::declaration("ABIBridgeFixture::add(int, int)"), scope);
            }();
            return independent;
        }();
        assert(dlclose(library) == 0);
        runtime.remove_cached_results();
        auto copy = retained;
        assert(copy.unsafe_invoke(20, 22) == 42);
        runtime.resolve(abi_bridge::declaration("ABIBridgeFixture::add(int, int)"), scope);
    }
    runtime.remove_cached_results();
    assert(unloadCallbackRan);

    // Assignment must release the old receiver while its method image is still
    // loaded, since a receiver's destructor may itself live in that image.
    void* reloaded = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(reloaded);
    bool receiverDestroyed = false;
    auto oldBinding = [&] {
        auto method = runtime.cxx_method<int(int)>(
            abi_bridge::declaration("ABIBridgeFixture::Counter::add(int)"), scope);
        auto owner = std::shared_ptr<ABIBridgeFixture::Counter>(
            new ABIBridgeFixture::Counter{40}, [&](auto* object) {
                void* held = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);
                assert(held && "Receiver destruction requires the old code image");
                assert(dlclose(held) == 0);
                receiverDestroyed = true;
                delete object;
            });
        return method.bind(owner);
    }();
    auto local = runtime.cxx_method<int(int)>(
        abi_bridge::declaration("ABIBridgeLocalCounter::add(int)"))
        .bind(std::make_shared<ABIBridgeLocalCounter>(ABIBridgeLocalCounter{0}));
    assert(dlclose(reloaded) == 0);
    runtime.remove_cached_results();
    oldBinding = local;
    assert(receiverDestroyed);
    assert(oldBinding.unsafe_invoke(2) == 2);
    std::cout << "Native consumer passed: C/C++, references, values, image lifetime, concurrent resolution.\n";
}
