#include <ABIBridge/ABIBridge.hpp>
#include <cassert>
#include <atomic>
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

static std::thread constructorWorker;
extern "C" void ABIBridgeTestConstructorEntered() {
    std::atomic<bool> started = false;
    constructorWorker = std::thread([&] {
        started.store(true);
        try {
            auto function = abi_bridge::InvocationRuntime::current().c_function<pid_t()>("getpid");
            assert(function.unsafe_invoke() == getpid());
        } catch (const abi_bridge::resolution_error& error) {
            // The catalog may include the library whose constructor has not
            // finished, so acquiring its lease may report imageChanged.
            assert(error.code() == ABIFailureImageChanged);
        }
    });
    while (!started.load()) std::this_thread::yield();
    // Give the other thread an opportunity to enter the loader while this
    // constructor still owns dyld's lock.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    abi_bridge::InvocationRuntime::current().remove_cached_results();
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
        if (!watchdogCondition.wait_for(lock, std::chrono::seconds(10), [&] { return constructorFinished; })) {
            std::cerr << "Constructor/reentrant resolution timed out.\n";
            std::_Exit(1);
        }
    });
    runtime.remove_cached_results();
    void* constructorLibrary = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    assert(constructorLibrary);
    constructorWorker.join();
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
