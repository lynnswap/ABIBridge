#include <ABIBridge/Backend/ImageObservation.h>
#include <dlfcn.h>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>

struct Context {
    std::mutex mutex;
    std::condition_variable changed;
    std::string path;
    bool initialized = false, released = false;
    uint64_t generation = 0;
};

template<class Predicate> void wait(Context& state, Predicate predicate) {
    std::unique_lock lock(state.mutex);
    assert(state.changed.wait_for(lock, std::chrono::seconds(10), predicate));
}

int main(int argc, char **argv) {
    assert(argc == 4);
    Context state;
    state.path = argv[1];
    ABIResolutionFailure *error = nullptr;
    auto *observation = ABIObserveLoadedImages(&state, [](void *context, const ABIImageList *images) {
        auto& state = *static_cast<Context *>(context);
        uint64_t generation = 0;
        for (size_t i = 0; i < ABIImageListGetCount(images); ++i) {
            const auto image = ABIImageListGetImage(images, i);
            if (std::string(image.path).ends_with(state.path)) generation = image.generation;
        }
        std::lock_guard lock(state.mutex);
        state.initialized = true;
        state.generation = generation;
        state.changed.notify_all();
    }, [](void *context) {
        auto& state = *static_cast<Context *>(context);
        std::lock_guard lock(state.mutex);
        state.released = true;
        state.changed.notify_all();
    }, &error);
    assert(observation && !error);
    wait(state, [&] { return state.initialized; });
    uint64_t previous = 0;
    for (unsigned i = 0; i < 3; ++i) {
        auto *before = ABICopyLoadedImages();
        auto *unchanged = ABICopyLoadedImages();
        assert(before && unchanged && ABIImageListGetRevision(before) == ABIImageListGetRevision(unchanged));
        const auto beforeCount = ABIImageListGetCount(before);
        const auto beforeRevision = ABIImageListGetRevision(before);
        ABIReleaseImageList(unchanged);
        auto *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(library);
        wait(state, [&] { return state.generation > previous; });
        { std::lock_guard lock(state.mutex); previous = state.generation; }
        auto *loaded = ABICopyLoadedImages();
        assert(loaded && ABIImageListGetRevision(loaded) > beforeRevision);
        assert(ABIImageListGetCount(before) == beforeCount && ABIImageListGetRevision(before) == beforeRevision);
        ABIImageInfo saved{};
        for (size_t index = 0; index < ABIImageListGetCount(loaded); ++index) {
            auto entry = ABIImageListGetImage(loaded, index);
            if (entry.generation == previous) saved = entry;
        }
        assert(saved.generation == previous);
        const std::string path(saved.path);
        assert(dlclose(library) == 0);
        wait(state, [&] { return state.generation == 0; });
        assert(ABIAcquireImageLease(previous) == nullptr);
        auto *removed = ABICopyLoadedImages();
        assert(removed && ABIImageListGetRevision(removed) > ABIImageListGetRevision(loaded));
        assert(std::string(saved.path) == path); // Snapshot strings survive unload.
        ABIReleaseImageList(before);
        ABIReleaseImageList(loaded);
        ABIReleaseImageList(removed);
    }
    void *libraries[3];
    uint64_t generations[3]{};
    for (unsigned i = 0; i < 3; ++i) {
        libraries[i] = dlopen(argv[i + 1], RTLD_NOW | RTLD_LOCAL);
        assert(libraries[i]);
        auto *list = ABICopyLoadedImages();
        for (size_t j = 0; j < ABIImageListGetCount(list); ++j) {
            auto image = ABIImageListGetImage(list, j);
            if (std::string(image.path).ends_with(argv[i + 1])) generations[i] = image.generation;
        }
        ABIReleaseImageList(list);
        assert(generations[i] && (!i || generations[i] > generations[i - 1]));
    }
    assert(dlclose(libraries[1]) == 0);
    for (auto generation : {uint64_t(0), generations[1], UINT64_MAX}) {
        assert(ABIAcquireImageLease(generation) == nullptr);
    }
    for (auto index : {0, 2}) {
        auto *lease = ABIAcquireImageLease(generations[index]);
        assert(lease);
        ABIReleaseImageLease(lease);
        assert(dlclose(libraries[index]) == 0);
    }
    ABIReleaseImageObservation(observation);
    wait(state, [&] { return state.released; });
    std::puts("Image observation unload/reload fixture passed");
}
