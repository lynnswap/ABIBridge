#include <ABIBridge/ImportedHookMonitoring.hpp>
#include <dlfcn.h>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <future>
#include <mutex>
#include <cstdio>

using namespace abi_bridge;
struct Events {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<imported_image_update> values;
    void append(const imported_image_update& value) {
        std::lock_guard lock(mutex); values.push_back(value); changed.notify_all();
    }
    void wait(int32_t kind, uint64_t after = 0) {
        std::unique_lock lock(mutex);
        assert(changed.wait_for(lock, std::chrono::seconds(10), [&] {
            return !values.empty() && values.back().state == kind && values.back().image.identity.load_generation > after;
        }));
    }
    uint64_t generation() { std::lock_guard lock(mutex); return values.back().image.identity.load_generation; }
};
int main(int argc, char **argv) {
    assert(argc == 4);
    const declaration query{"ABIImportedAdd",language::c};
    auto fail=[](const resolution_error&) noexcept { assert(false && "Unexpected invocation failure"); };
    auto unchanged=[](auto& call,int32_t a,int32_t b) { return call.proceed(a,b); };
    auto absent=std::make_shared<Events>();
    auto noMatch=monitor_imported_function<int32_t(int32_t,int32_t)>(query,image_selector::path(argv[1]),unchanged,fail,
        [absent](const imported_image_update& value) noexcept { absent->append(value); });
    uint64_t previous=0;
    for(int i=0;i<3;++i) {
        auto *provider=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(provider);
        absent->wait(ABIImportedImageNoMatch,previous); previous=absent->generation();
        assert(noMatch.images().size()==1);
        dlclose(provider);
        absent->wait(ABIImportedImageRemoved);
        assert(noMatch.images().empty());
    }
    noMatch.invalidate();

    auto events=std::make_shared<Events>();
    auto monitor=monitor_imported_function<int32_t(int32_t,int32_t)>(query,image_selector::path(argv[2]),
        [](auto& call,int32_t a,int32_t b) { return call.proceed(a,b)+1; },fail,
        [events](const imported_image_update& value) noexcept { events->append(value); });
    auto *provider=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(provider);
    auto *caller=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL); assert(caller);
    events->wait(ABIImportedImageInstalled);
    auto call=reinterpret_cast<int32_t(*)(int32_t,int32_t)>(dlsym(caller,"ABIMonitoredCall")); assert(call);
    assert(call(20,21)==42);
    monitor.invalidate(); assert(call(20,22)==42);

    auto cancelledEvents=std::make_shared<Events>();
    auto cancelled=monitor_imported_function<int32_t(int32_t,int32_t)>(query,image_selector::path(argv[3]),
        [](auto&,int32_t,int32_t) { assert(false && "Cancelled monitor entered its callback"); return int32_t(0); },fail,
        [cancelledEvents](const imported_image_update& value) noexcept { cancelledEvents->append(value); });
    auto set=reinterpret_cast<void(*)(void(*)(void*),void*)>(dlsym(provider,"ABISetImportedMonitorInitializer")); assert(set);
    set([](void *context) {
        auto *images=ABICopyLoadedImages(); assert(images && ABIImageListCount(images)); ABIFreeImageList(images);
        static_cast<imported_hook_monitor*>(context)->invalidate();
    },&cancelled);
    const std::string path=argv[3];
    auto loading=std::async(std::launch::async,[path] { return dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL); });
    assert(loading.wait_for(std::chrono::seconds(10))==std::future_status::ready);
    auto *cancelledCaller=loading.get(); assert(cancelledCaller);
    set(nullptr,nullptr);
    auto cancelledCall=reinterpret_cast<int32_t(*)(int32_t,int32_t)>(dlsym(cancelledCaller,"ABIMonitoredCall")); assert(cancelledCall);
    assert(cancelledCall(20,22)==42);
    cancelled.invalidate();
    dlclose(cancelledCaller); dlclose(caller); dlclose(provider);
    std::puts("Imported monitor consumer passed");
}
