#include <ABIBridge/Inspection.hpp>
#include "../../MemoryFixture.hpp"
#include "../../PointerSearchFixture.hpp"
#include <cassert>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <thread>
#include <vector>

int main(int argc, char **argv) {
    assert(argc == 2);
    checkMemoryReads();
    checkPointerSearch();
    using namespace abi_bridge;
    Runtime::current().remove_cached_results();
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    const auto scope = image_selector::path(argv[1]);
    const declaration tableQuery("vtable for ABIBridgeFixture::VirtualCounter", language::cxx, symbol_kind::vtable);
    const declaration counterQuery("ABIBridgeFixture::counter", language::cxx, symbol_kind::data);
    std::optional<resolved_symbol> retained;
    std::optional<image_lease> lease;
    std::optional<resolution_error> savedError;
    image_description copiedDescription{};
    {
        Runtime runtime;
        auto copy = runtime;
        auto moved = std::move(copy);
        assert(runtime && moved && !copy);
        copy = runtime;
        assert(copy);
        auto table = moved.resolve(tableQuery, scope);
        assert(table.unsafe_address() == dlsym(library, "_ZTVN16ABIBridgeFixture14VirtualCounterE"));
        auto tableCopy = table;
        auto tableMoved = std::move(tableCopy);
        assert(!tableCopy && tableMoved && tableMoved.image() == table.image());
        tableCopy = tableMoved;
        assert(tableCopy.unsafe_address() == table.unsafe_address());
        auto snapshots = image_snapshot::capture();
        auto snapshotCopy = snapshots;
        auto snapshotMoved = std::move(snapshotCopy);
        assert(!snapshotCopy && snapshotMoved.size() == snapshots.size());
        bool found = false;
        for (std::size_t i = 0; i < snapshots.size(); ++i) {
            auto entry = snapshotMoved.at(i);
            if (entry.identity == table.image()) {
                copiedDescription = std::move(entry);
                found = true;
            }
        }
        assert(found && copiedDescription.path == table.image_path());
        try {
            (void)snapshots.at(snapshots.size());
            assert(false && "Invalid snapshot indices must throw");
        } catch (const std::out_of_range&) {}
        lease = image_lease::acquire(table.image().load_generation);
        assert(lease && *lease);
        auto leaseCopy = *lease;
        auto leaseMoved = std::move(leaseCopy);
        assert(!leaseCopy && leaseMoved);
        leaseCopy = leaseMoved;
        assert(leaseCopy);
        try {
            runtime.resolve({"ABIBridgeCppInspectionMissing", language::c}, scope);
            assert(false && "Missing declarations must throw");
        } catch (const resolution_error& error) {
            assert(error.code() == ABIFailureDeclarationNotFound);
            savedError = error;
        }

        for (int invalidField = 0; invalidField < 2; ++invalidField) {
            auto invalidQuery = counterQuery;
            auto invalidScope = scope;
            if (invalidField == 0) invalidQuery.name += std::string("\0suffix", 7);
            else invalidScope = image_selector::path(std::string(argv[1]) + std::string("\0suffix", 7));
            try {
                runtime.resolve(invalidQuery, invalidScope);
                assert(false && "Embedded NULs must not resolve a truncated name or path");
            } catch (const resolution_error& error) {
                assert(error.code() == ABIFailureInvalidRequest);
            }
        }

        std::vector<std::thread> threads;
        for (int i = 0; i < 2; ++i) {
            threads.emplace_back([runtime, scope, counterQuery] {
                for (int j = 0; j < 3; ++j) {
                    auto symbol = runtime.resolve(counterQuery, scope);
                    assert(*static_cast<const int*>(symbol.unsafe_address()) == 42);
                }
            });
        }
        for (auto& thread : threads) thread.join();

        retained = runtime.resolve(counterQuery, scope);
        assert(dlclose(library) == 0);
        runtime.remove_cached_results();
    }

    assert(savedError && std::strstr(savedError->what(), "ABIBridgeCppInspectionMissing"));
    auto copiedError = *savedError;
    savedError.reset();
    assert(copiedError.code() == ABIFailureDeclarationNotFound);
    assert(std::strstr(copiedError.what(), "ABIBridgeCppInspectionMissing"));
    assert(!copiedDescription.path.empty()); // Owned even after the snapshot is gone.
    const auto *counter = static_cast<const int*>(retained->unsafe_address());
    assert(*counter == 42);
    retained.reset();
    assert(*counter == 42); // The independent lease still keeps the image loaded.
    lease.reset();
    assert(!image_lease::acquire(copiedDescription.identity.load_generation));
    std::cout << "C++ inspection consumer passed: public wrappers, copy/move ownership, errors, and leases.\n";
}
