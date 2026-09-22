#include <ABIBridge/ABIBridge.hpp>
#include <cassert>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace ABIBridgeFixture {
struct LargeResult { long words[8]; };
}

static bool unloadCallbackRan = false;
static void onLibraryUnload() {
    abi_bridge::Runtime::current().remove_cached_results();
    unloadCallbackRan = true;
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string path = argv[1];
    const auto scope = abi_bridge::image_selector::path(path);
    auto runtime = abi_bridge::Runtime::current();
    auto pid = runtime.c_function<pid_t()>("getpid");
    assert(pid.unsafe_invoke() == getpid());

    try {
        runtime.c_function<int(int, int)>("ABIBridgeFixtureCAdd", scope);
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
                abi_bridge::Runtime temporary;
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
    std::cout << "Native consumer passed: C/C++, references, values, image lifetime, concurrent resolution.\n";
}
