#include <ABIBridge/ImportedHookMonitoring.h>
#include <ABIBridge/ImageObservation.h>
#include "NativeValueType.hpp"
#include <atomic>
#include <map>
#include <mutex>
#include <set>
#include <string>

namespace {
using Failure = std::shared_ptr<ABIResolutionFailure>;
using Hook = std::shared_ptr<ABIImportedHook>;
using Query = std::unique_ptr<ABIImportedQuery, decltype(&ABIReleaseImportedQuery)>;
struct Behavior {
    std::atomic<bool> enabled{true};
    void *context;
    ABIImportedCallback callback;
    ABIImportedFailureHandler failure;
    ABIImportedImageHandler update;
    ABIImportedContextRelease release;
    Behavior(void *c, ABIImportedCallback b, ABIImportedFailureHandler f, ABIImportedImageHandler u, ABIImportedContextRelease r)
        : context(c), callback(b), failure(f), update(u), release(r) {}
    ~Behavior() { release(context); }
};
struct ImageResult {
    ABIImageInfo image;
    std::string path;
    int32_t state;
    Hook hook;
    Failure failure;
    ABIImportedImageUpdate view() const {
        auto info = image; info.path = path.c_str();
        return {info, state, hook.get(), failure.get()};
    }
};
struct Monitor {
    std::mutex mutex;
    std::shared_ptr<Behavior> behavior;
    std::map<uint64_t, std::shared_ptr<ImageResult>> images;
    Query query{nullptr, ABIReleaseImportedQuery};
    ABIValueType result;
    std::vector<ABIValueType> parameters;
    // Accessed only by the observation's serial worker; removed loads are pruned.
    std::set<uint64_t> processed;
};
void deliver(const std::shared_ptr<Behavior>& behavior, const ImageResult& result) {
    if (behavior->enabled.load()) behavior->update(behavior->context, result.view());
}
void process(const std::shared_ptr<Monitor>& monitor, const ABIImageList *snapshot) {
    std::shared_ptr<Behavior> behavior;
    { std::lock_guard lock(monitor->mutex); behavior = monitor->behavior; }
    if (!behavior || !behavior->enabled.load()) return;
    std::set<uint64_t> current;
    for (size_t i = 0; i < ABIImageListCount(snapshot); ++i) current.insert(ABIImageListGet(snapshot, i).generation);
    std::erase_if(monitor->processed, [&](uint64_t generation) { return !current.contains(generation); });
    std::vector<std::shared_ptr<ImageResult>> removed;
    {
        std::lock_guard lock(monitor->mutex);
        for (auto i = monitor->images.begin(); i != monitor->images.end();) {
            if (current.contains(i->first)) { ++i; continue; }
            removed.push_back(std::move(i->second)); i = monitor->images.erase(i);
        }
    }
    for (const auto& previous : removed) {
        auto update = *previous; update.state = ABIImportedImageRemoved;
        deliver(behavior, update);
    }
    for (size_t i = 0; i < ABIImageListCount(snapshot) && behavior->enabled.load(); ++i) {
        const auto image = ABIImageListGet(snapshot, i);
        if (!monitor->processed.insert(image.generation).second) continue;
        ABIResolutionFailure *error = nullptr;
        std::unique_ptr<ABIImportSelection, decltype(&ABIReleaseImportSelection)> selection(
            ABICopyImportedSelectionForImage(monitor->query.get(), image, &error), ABIReleaseImportSelection);
        auto result = std::make_shared<ImageResult>();
        result->image = image; result->path = image.path;
        result->failure = Failure(error, ABIReleaseResolutionFailure);
        if (!selection) {
            if (!error) continue; // The importing-image scope did not match.
            if (ABIResolutionFailureCode(error) == ABIFailureDeclarationNotFound) {
                result->state = ABIImportedImageNoMatch; result->failure.reset();
            } else result->state = ABIImportedImageFailed;
        } else {
            if (!behavior->enabled.load()) break;
            std::vector<const ABIValueType *> parameters;
            for (auto& value : monitor->parameters) parameters.push_back(&value);
            auto context = std::make_unique<std::shared_ptr<Behavior>>(behavior);
            auto *installed = ABICreateImportedHook(selection.get(), &monitor->result, parameters.data(), parameters.size(), context.release(),
                [](void *context, ABIImportedInvocation *call, ABIResolutionFailure **error) {
                    auto& behavior = **static_cast<std::shared_ptr<Behavior> *>(context);
                    // Preparation may have raced invalidation. An entry published
                    // afterwards must remain pass-through, even before cleanup.
                    return !behavior.enabled.load() || behavior.callback(behavior.context, call, error);
                }, [](void *context, const ABIResolutionFailure *error) {
                    auto& behavior = **static_cast<std::shared_ptr<Behavior> *>(context);
                    behavior.failure(behavior.context, error);
                }, [](void *context) { delete static_cast<std::shared_ptr<Behavior> *>(context); });
            result->hook = Hook(installed, ABIReleaseImportedHook);
            if (auto failure = ABIImportedHookFailure(installed)) {
                result->state = ABIImportedImageFailed;
                result->failure = Failure(ABICreateResolutionFailure(ABIResolutionFailureCode(failure), ABIResolutionFailureMessage(failure)), ABIReleaseResolutionFailure);
            } else result->state = ABIImportedImageInstalled;
        }
        bool accepted;
        {
            std::lock_guard lock(monitor->mutex);
            accepted = monitor->behavior != nullptr;
            if (accepted) monitor->images.emplace(image.generation, result);
        }
        if (!accepted) {
            if (result->hook) ABIInvalidateImportedHook(result->hook.get());
            break;
        }
        deliver(behavior, *result);
    }
}
}

struct ABIImportedHookMonitor {
    std::shared_ptr<Monitor> state;
    ABIImageObservation *observation = nullptr;
};
struct ABIImportedImageList { std::vector<std::shared_ptr<ImageResult>> images; };

ABIImportedHookMonitor *ABICreateImportedHookMonitor(ABIImportedQuery *query, const ABIValueType *result,
    const ABIValueType *const *parameters, size_t count, void *context, ABIImportedCallback callback,
    ABIImportedFailureHandler failure, ABIImportedImageHandler update, ABIImportedContextRelease release,
    ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    Query ownedQuery(query, ABIReleaseImportedQuery);
    auto reject = [&](const char *message) -> ABIImportedHookMonitor * {
        if (error) *error = ABICreateResolutionFailure(ABIFailureInvalidRequest, message);
        return nullptr;
    };
    if (!release) return reject("A context release callback is required.");
    auto behavior = std::make_shared<Behavior>(context, callback, failure, update, release);
    if (!query || !callback || !failure || !update) return reject("A query, callback, failure handler and image handler are required.");
    std::unique_ptr<ABICallInterface, decltype(&ABIReleaseCallInterface)> prepared(
        ABICreateCCallInterface(result, parameters, count, error), ABIReleaseCallInterface);
    if (!prepared) return nullptr;
    auto monitor = std::make_shared<Monitor>();
    monitor->behavior = behavior; monitor->query = std::move(ownedQuery); monitor->result = *result;
    for (size_t i = 0; i < count; ++i) monitor->parameters.push_back(*parameters[i]);
    auto owner = std::make_unique<ABIImportedHookMonitor>(ABIImportedHookMonitor{monitor});
    // The observation keeps only a weak monitor reference; the worker retains a
    // live monitor for its own invocation, without creating an ownership cycle.
    auto weak = std::make_unique<std::weak_ptr<Monitor>>(monitor);
    owner->observation = ABIObserveLoadedImages(weak.release(), [](void *context, const ABIImageList *snapshot) {
        if (auto monitor = static_cast<std::weak_ptr<Monitor> *>(context)->lock()) process(monitor, snapshot);
    }, [](void *context) { delete static_cast<std::weak_ptr<Monitor> *>(context); }, error);
    return owner->observation ? owner.release() : nullptr;
}

void ABIInvalidateImportedHookMonitor(ABIImportedHookMonitor *owner) {
    if (!owner) return;
    auto monitor = owner->state;
    std::shared_ptr<Behavior> retired;
    std::vector<Hook> hooks;
    {
        std::lock_guard lock(monitor->mutex);
        retired = std::move(monitor->behavior);
        if (!retired) return;
        retired->enabled.store(false);
        for (const auto& item : monitor->images) if (item.second->hook) hooks.push_back(item.second->hook);
    }
    ABIInvalidateImageObservation(owner->observation);
    for (const auto& hook : hooks) ABIInvalidateImportedHook(hook.get());
}
void ABIReleaseImportedHookMonitor(ABIImportedHookMonitor *owner) {
    if (!owner) return;
    ABIInvalidateImportedHookMonitor(owner);
    ABIReleaseImageObservation(owner->observation);
    delete owner;
}
ABIImportedImageList *ABICopyImportedHookMonitorImages(const ABIImportedHookMonitor *owner) {
    auto result = std::make_unique<ABIImportedImageList>();
    std::lock_guard lock(owner->state->mutex);
    for (const auto& item : owner->state->images) result->images.push_back(item.second);
    return result.release();
}
size_t ABIImportedImageListCount(const ABIImportedImageList *list) { return list->images.size(); }
ABIImportedImageUpdate ABIImportedImageListGet(const ABIImportedImageList *list, size_t i) { return list->images.at(i)->view(); }
void ABIReleaseImportedImageList(ABIImportedImageList *list) { delete list; }
