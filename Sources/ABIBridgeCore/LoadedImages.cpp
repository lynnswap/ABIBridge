#include <ABIBridgeCore.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <cxxabi.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <memory>
#include <iterator>
#include <utility>
#include <string>
#include <vector>

namespace {

struct Image {
    uintptr_t header;
    intptr_t slide;
    uint64_t generation;
    std::array<uint8_t, 16> uuid;
    std::string path;
    bool processLifetime;
    bool executable = false;
    std::string installName;
};

struct Catalog {
    std::mutex mutex;
    uint64_t generation = 0;
    std::vector<Image> images;
};

// dyld has no callback-unregistration API. The catalog and callback code must
// remain alive for the process lifetime, including when clients drop leases.
Catalog& catalog()
{
    static auto *value = new Catalog;
    return *value;
}

bool hasProcessLifetime(const mach_header *header)
{
    // Shared-cache images cannot unload. Their reported path need not be
    // reopenable by dlopen, notably with Simulator runtime prefixes.
    return header->filetype == MH_EXECUTE || (header->flags & MH_DYLIB_IN_CACHE) != 0;
}

void addedImage(const mach_header *header, intptr_t slide)
{
    Dl_info info {};
    if (!dladdr(header, &info) || !info.dli_fname)
        return;
    Image image { reinterpret_cast<uintptr_t>(header), slide, 0, {}, info.dli_fname,
                  hasProcessLifetime(header), header->filetype == MH_EXECUTE, {} };
    const size_t headerSize = header->magic == MH_MAGIC_64 ? sizeof(mach_header_64) : sizeof(mach_header);
    auto *command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(header) + headerSize);
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        if (command->cmd == LC_UUID) {
            const auto *uuid = reinterpret_cast<const uuid_command *>(command);
            std::copy(std::begin(uuid->uuid), std::end(uuid->uuid), image.uuid.begin());
        }
        if (command->cmd == LC_ID_DYLIB && command->cmdsize >= sizeof(dylib_command)) {
            const auto *dylib = reinterpret_cast<const dylib_command *>(command);
            const auto offset = dylib->dylib.name.offset;
            if (offset < command->cmdsize) {
                const auto *name = reinterpret_cast<const char *>(command) + offset;
                const auto length = strnlen(name, command->cmdsize - offset);
                if (length < command->cmdsize - offset) image.installName.assign(name, length);
            }
        }
        command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(command) + command->cmdsize);
    }
    auto& state = catalog();
    std::lock_guard lock(state.mutex);
    image.generation = ++state.generation;
    state.images.push_back(std::move(image));
}

void removedImage(const mach_header *header, intptr_t)
{
    auto& state = catalog();
    std::lock_guard lock(state.mutex);
    const auto address = reinterpret_cast<uintptr_t>(header);
    std::erase_if(state.images, [address](const Image& image) { return image.header == address; });
}

bool initialize()
{
    static std::once_flag once;
    static bool initialized = false;
    std::call_once(once, [] {
        // Dynamic consumers may unload themselves, but dyld will still call
        // these observers. Pin their image before registering the callbacks.
        Dl_info ownImage {};
        if (!dladdr(reinterpret_cast<const void *>(&ABICopyLoadedImages), &ownImage) || !ownImage.dli_fname)
            return;
        const auto *header = static_cast<const mach_header *>(ownImage.dli_fbase);
        if (!hasProcessLifetime(header)) {
            void *handle = dlopen(ownImage.dli_fname, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD | RTLD_NODELETE);
            if (!handle)
                return;
            dlclose(handle);
        }
        _dyld_register_func_for_remove_image(removedImage);
        _dyld_register_func_for_add_image(addedImage);
        initialized = true;
    });
    return initialized;
}

auto findGeneration(const std::vector<Image>& images, uint64_t generation)
{
    // Appending a new generation and erasing unloaded images preserve order.
    const auto found = std::lower_bound(images.begin(), images.end(), generation,
        [](const Image& image, uint64_t value) { return image.generation < value; });
    return found != images.end() && found->generation == generation ? found : images.end();
}

} // namespace

struct ABIImageList {
    std::vector<Image> images;
};

struct ABIImageLease {
    void *handle;
    Image image;
};

ABIImageList *ABICopyLoadedImages(void)
{
    if (!initialize())
        return nullptr;
    auto& state = catalog();
    std::lock_guard lock(state.mutex);
    return new ABIImageList { state.images };
}

size_t ABIImageListCount(const ABIImageList *list)
{
    return list->images.size();
}

ABIImageInfo ABIImageListGet(const ABIImageList *list, size_t index)
{
    const auto& image = list->images.at(index);
    ABIImageInfo result { image.header, image.slide, image.generation, {}, image.path.c_str() };
    std::copy(image.uuid.begin(), image.uuid.end(), std::begin(result.uuid));
    return result;
}

void ABIFreeImageList(ABIImageList *list)
{
    delete list;
}

ABIImageLease *ABIRetainLoadedImage(uint64_t generation)
{
    if (!initialize())
        return nullptr;
    Image image {};
    {
        auto& state = catalog();
        std::lock_guard lock(state.mutex);
        auto found = findGeneration(state.images, generation);
        if (found == state.images.end())
            return nullptr;
        image = *found;
    }
    // Never call dlopen/dlclose while holding the catalog lock: dyld observers
    // acquire that lock while running under the loader's own lock.
    void *handle = image.processLifetime ? nullptr : dlopen(image.path.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
    if (!image.processLifetime && !handle)
        return nullptr;
    bool current;
    {
        auto& state = catalog();
        std::lock_guard lock(state.mutex);
        current = findGeneration(state.images, generation) != state.images.end();
    }
    if (!current) {
        if (handle)
            dlclose(handle);
        return nullptr;
    }
    return new ABIImageLease { handle, std::move(image) };
}

namespace {

std::vector<Image> imageSnapshot()
{
    auto& state = catalog();
    std::lock_guard lock(state.mutex);
    return state.images;
}

std::string canonicalPath(const std::string& path)
{
    std::unique_ptr<char, decltype(&std::free)> resolved(realpath(path.c_str(), nullptr), std::free);
    return resolved ? resolved.get() : path;
}

std::string leafName(const std::string& path)
{
    return path.substr(path.find_last_of('/') + 1);
}

void loadingFailure(ABIResolutionFailure **error, int32_t code, const std::string& message)
{
    if (error) *error = ABICreateResolutionFailure(code, message.c_str());
}

bool matchesHandle(const Image& image, void *handle)
{
    if (image.executable) return false;
    for (const auto& path : {image.path, image.installName}) {
        if (path.empty()) continue;
        void *probe = dlopen(path.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST | RTLD_NOLOAD);
        if (!probe) continue;
        const bool matches = probe == handle;
        dlclose(probe);
        if (matches) return true;
    }
    return false;
}

} // namespace

ABIImageLease *ABIOpenImage(const char *path, bool loadIfNeeded, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!initialize()) {
        loadingFailure(error, ABIFailureImageUnavailable, "The native image catalog is unavailable.");
        return nullptr;
    }
    const auto canonical = canonicalPath(path);
    // An executable cannot be opened as a dylib. It already owns process lifetime.
    for (const auto& image : imageSnapshot()) {
        if (image.executable && canonicalPath(image.path) == canonical)
            return new ABIImageLease { nullptr, image };
    }
    void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST | (loadIfNeeded ? 0 : RTLD_NOLOAD));
    if (!handle) {
        const char *message = dlerror();
        loadingFailure(error, loadIfNeeded ? ABIFailureImageLoadFailed : ABIFailureImageNotLoaded,
                       message ? message : "dlopen failed without a diagnostic.");
        return nullptr;
    }
    std::unique_ptr<void, decltype(&dlclose)> owner(handle, dlclose);
    // Catalog callbacks have completed when dlopen returns. Do not identify the
    // image from dlsym: a re-export can belong to a dependency, and local-only
    // libraries need not export an anchor or Mach-O header symbol.
    const auto images = imageSnapshot();
    const auto leaf = leafName(canonical);
    const Image *matched = nullptr;
    for (int pass = 0; pass < 2 && !matched; ++pass) {
        for (const auto& image : images) {
            const bool likely = leafName(image.path) == leaf || leafName(image.installName) == leaf;
            if ((pass == 0) != likely || !matchesHandle(image, handle)) continue;
            if (matched) {
                loadingFailure(error, ABIFailureMetadataUnavailable, "The loader handle matches multiple cataloged images.");
                return nullptr;
            }
            matched = &image;
        }
    }
    if (!matched) {
        loadingFailure(error, ABIFailureMetadataUnavailable, "The acquired image could not be identified in the dyld catalog.");
        return nullptr;
    }
    auto *lease = new ABIImageLease { handle, *matched };
    owner.release();
    return lease;
}

ABIImageLease *ABIOpenLoadedImage(uint64_t generation, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!initialize()) {
        loadingFailure(error, ABIFailureImageUnavailable, "The native image catalog is unavailable.");
        return nullptr;
    }
    for (const auto& image : imageSnapshot()) {
        if (image.generation != generation) continue;
        if (image.executable) return new ABIImageLease { nullptr, image };
        std::string messages;
        for (const auto& path : {image.path, image.installName}) {
            if (path.empty() || (path == image.installName && image.installName == image.path && !messages.empty())) continue;
            ABIResolutionFailure *failure = nullptr;
            auto *lease = ABIOpenImage(path.c_str(), true, &failure);
            if (lease) {
                if (lease->image.generation == generation) return lease;
                ABIReleaseImage(lease);
                loadingFailure(error, ABIFailureImageChanged, "The loader acquired a different image generation.");
                return nullptr;
            }
            const auto code = ABIResolutionFailureCode(failure);
            messages += (messages.empty() ? "" : "\n") + path + ": " + ABIResolutionFailureMessage(failure);
            ABIReleaseResolutionFailure(failure);
            if (code != ABIFailureImageLoadFailed) {
                loadingFailure(error, code, messages);
                return nullptr;
            }
            // A Simulator cache image can report a host-prefixed path that
            // dyld only recognizes by the same image's logical install name.
        }
        loadingFailure(error, ABIFailureImageLoadFailed, messages);
        return nullptr;
    }
    loadingFailure(error, ABIFailureImageChanged, "The requested image generation is no longer loaded.");
    return nullptr;
}

ABIImageInfo ABIImageLeaseGet(const ABIImageLease *lease)
{
    const auto& image = lease->image;
    ABIImageInfo result { image.header, image.slide, image.generation, {}, image.path.c_str() };
    std::copy(image.uuid.begin(), image.uuid.end(), std::begin(result.uuid));
    return result;
}

bool ABIImageIsInSharedCache(const char *path)
{
    return _dyld_shared_cache_contains_path(path);
}

void ABIReleaseImage(ABIImageLease *lease)
{
    if (!lease)
        return;
    if (lease->handle)
        dlclose(lease->handle);
    delete lease;
}

char *ABICopyDemangledCXXName(const char *name)
{
    if (std::strncmp(name, "__Z", 3) == 0)
        ++name;
    if (std::strncmp(name, "_Z", 2) != 0)
        return nullptr;
    return abi::__cxa_demangle(name, nullptr, nullptr, nullptr);
}

// Swift consumers and the native runtime product link libswiftCore. A weak
// reference also permits the low-level target to be used without Swift, and
// avoids lazy dlsym/once locks inside a resolver's index critical section.
extern "C" char *swift_demangle(const char *, size_t, char *, size_t *, uint32_t)
    __attribute__((weak_import));

char *ABICopyDemangledSwiftName(const char *name)
{
    if (name[0] == '_')
        ++name;
    if (std::strncmp(name, "$s", 2) != 0 && std::strncmp(name, "$S", 2) != 0)
        return nullptr;
    return swift_demangle ? swift_demangle(name, std::strlen(name), nullptr, nullptr, 0) : nullptr;
}

void ABIFreeString(char *string)
{
    std::free(string);
}
