#pragma once
#include <ABIBridge/NativeInvocation.hpp>
#include "FixtureTypes.hpp"
#include <cassert>
#include <dlfcn.h>

inline void checkPublicNativeInvocation(const char *path) {
    using namespace abi_bridge;
    std::uint64_t generation = 0;
    {
        void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        assert(library);
        const auto scope = image_selector::path(path);
        Runtime runtime;
        auto symbol = runtime.resolve(declaration("ABIBridgeFixture::add(int, int)"), scope);
        generation = symbol.image().load_generation;
        // C handles use the same path for symbols transferred from Swift.
        auto *native = ABIRetainResolvedSymbol(symbol.native_handle());
        function<int(int, int)> add(resolved_symbol::retain(native));
        ABIReleaseResolvedSymbol(native);
        function<int(int, int)> cAdd(runtime.resolve(declaration("ABIBridgeFixtureCAdd", language::c), scope));
        function<void(int&)> increment(runtime.resolve(declaration("ABIBridgeFixture::increment(int&)"), scope));
        function<int&(int&)> identity(runtime.resolve(declaration("ABIBridgeFixture::identity(int&)"), scope));
        const std::string stringType = "std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char>>";
        function<std::string(std::string)> greet(runtime.resolve(declaration("ABIBridgeFixture::greet(" + stringType + ")"), scope));
        function<std::string(std::string&&)> consume(runtime.resolve(declaration("ABIBridgeFixture::consume(" + stringType + "&&)"), scope));
        function<ABIBridgeFixture::LargeResult(long)> large(runtime.resolve(declaration("ABIBridgeFixture::large(long)"), scope));
        method<int(int)> addValue(runtime.resolve(declaration("ABIBridgeFixture::Counter::add(int)"), scope));
        method<std::string(std::string) const> describe(runtime.resolve(
            declaration("ABIBridgeFixture::Counter::describe(" + stringType + ") const"), scope));

        for (const auto& query : {
            declaration("ABIBridgeFixture::counter", language::cxx, symbol_kind::data),
            declaration::vtable_for("ABIBridgeFixture::VirtualCounter")
        }) {
            auto invalid = runtime.resolve(query, scope);
            try { function<void()> call(invalid); assert(false); }
            catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }
            try { method<void()> call(invalid); assert(false); }
            catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }
        }
        // Exact names preserve source-language metadata even when the symbol is C.
        auto wrongABI = runtime.resolve(declaration::linker_name("ABIBridgeFixtureCAdd", language::swift), scope);
        try { function<int(int, int)> call(wrongABI); assert(false); }
        catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }
        auto moved = std::move(symbol);
        try { function<int(int, int)> call(std::move(symbol)); assert(false); }
        catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }

        assert(dlclose(library) == 0);
        runtime.remove_cached_results();
        // Every callable independently retains its image after cache/loader release.
        auto copy = add;
        assert(copy.unsafe_invoke(20, 22) == 42 && cAdd.unsafe_invoke(20, 22) == 42);
        int value = 41;
        increment.unsafe_invoke(value);
        assert(value == 42 && &identity.unsafe_invoke(value) == &value);
        assert(greet.unsafe_invoke("world") == "Hello, world");
        std::string input = "native";
        assert(consume.unsafe_invoke(std::move(input)) == "native" && input == "consumed");
        assert(large.unsafe_invoke(35).words[7] == 42);
        ABIBridgeFixture::Counter receiver{40};
        assert(addValue.unsafe_invoke(&receiver, 2) == 42);
        assert(describe.unsafe_invoke(&receiver, "value: ") == "value: 42");
        std::weak_ptr<ABIBridgeFixture::Combined> weak;
        {
            auto owner = std::make_shared<ABIBridgeFixture::Combined>();
            owner->value = 40;
            weak = owner;
            auto bound = addValue.bind(std::shared_ptr<ABIBridgeFixture::Counter>(owner, static_cast<ABIBridgeFixture::Counter*>(owner.get())));
            owner.reset();
            assert(!weak.expired() && bound.unsafe_invoke(2) == 42);
        }
        assert(weak.expired());
        // Construct outside a resolver's lifetime as well as after clearing it.
        auto independent = [&] {
            Runtime temporary;
            return function<int(int, int)>(temporary.resolve(declaration("ABIBridgeFixture::add(int, int)"), scope));
        }();
        assert(independent.unsafe_invoke(20, 22) == 42);
    }
    assert(!image_lease::acquire(generation));
}
