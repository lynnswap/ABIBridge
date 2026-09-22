#include <ABIBridgeCore.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <cxxabi.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <mutex>
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
    bool executable;
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

void addedImage(const mach_header *header, intptr_t slide)
{
    Dl_info info {};
    if (!dladdr(header, &info) || !info.dli_fname)
        return;
    Image image { reinterpret_cast<uintptr_t>(header), slide, 0, {}, info.dli_fname,
                  header->filetype == MH_EXECUTE };
    const size_t headerSize = header->magic == MH_MAGIC_64 ? sizeof(mach_header_64) : sizeof(mach_header);
    auto *command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(header) + headerSize);
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        if (command->cmd == LC_UUID) {
            const auto *uuid = reinterpret_cast<const uuid_command *>(command);
            std::copy(std::begin(uuid->uuid), std::end(uuid->uuid), image.uuid.begin());
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
        if (header->filetype != MH_EXECUTE) {
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

} // namespace

struct ABIImageList {
    std::vector<Image> images;
};

struct ABIImageLease {
    void *handle;
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
        auto found = std::find_if(state.images.begin(), state.images.end(),
                                 [generation](const Image& item) { return item.generation == generation; });
        if (found == state.images.end())
            return nullptr;
        image = *found;
    }
    // Never call dlopen/dlclose while holding the catalog lock: dyld observers
    // acquire that lock while running under the loader's own lock.
    void *handle = image.executable ? nullptr : dlopen(image.path.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
    if (!image.executable && !handle)
        return nullptr;
    bool current;
    {
        auto& state = catalog();
        std::lock_guard lock(state.mutex);
        current = std::any_of(state.images.begin(), state.images.end(),
                             [generation](const Image& item) { return item.generation == generation; });
    }
    if (!current) {
        if (handle)
            dlclose(handle);
        return nullptr;
    }
    return new ABIImageLease { handle };
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
