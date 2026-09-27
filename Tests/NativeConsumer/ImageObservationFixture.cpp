#include <ABIBridge/ImageObservation.h>
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
    assert(argc == 2);
    Context state;
    state.path = argv[1];
    ABIResolutionFailure *error = nullptr;
    auto *observation = ABIObserveLoadedImages(&state, [](void *context, const ABIImageList *images) {
        auto& state = *static_cast<Context *>(context);
        uint64_t generation = 0;
        for (size_t i = 0; i < ABIImageListCount(images); ++i) {
            const auto image = ABIImageListGet(images, i);
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
        assert(before && unchanged && ABIImageListRevision(before) == ABIImageListRevision(unchanged));
        const auto beforeCount = ABIImageListCount(before);
        const auto beforeRevision = ABIImageListRevision(before);
        ABIFreeImageList(unchanged);
        auto *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(library);
        wait(state, [&] { return state.generation > previous; });
        { std::lock_guard lock(state.mutex); previous = state.generation; }
        auto *loaded = ABICopyLoadedImages();
        assert(loaded && ABIImageListRevision(loaded) > beforeRevision);
        assert(ABIImageListCount(before) == beforeCount && ABIImageListRevision(before) == beforeRevision);
        ABIImageInfo saved{};
        for (size_t index = 0; index < ABIImageListCount(loaded); ++index) {
            auto entry = ABIImageListGet(loaded, index);
            if (entry.generation == previous) saved = entry;
        }
        assert(saved.generation == previous);
        const std::string path(saved.path);
        assert(dlclose(library) == 0);
        wait(state, [&] { return state.generation == 0; });
        assert(ABIRetainLoadedImage(previous) == nullptr);
        auto *removed = ABICopyLoadedImages();
        assert(removed && ABIImageListRevision(removed) > ABIImageListRevision(loaded));
        assert(std::string(saved.path) == path); // Snapshot strings survive unload.
        ABIFreeImageList(before);
        ABIFreeImageList(loaded);
        ABIFreeImageList(removed);
    }
    ABIReleaseImageObservation(observation);
    wait(state, [&] { return state.released; });
    std::puts("Image observation unload/reload fixture passed");
}
