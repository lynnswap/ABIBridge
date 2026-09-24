#include <ABIBridge/Inspection.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <cassert>

static bool rejectRetains = false;
static unsigned retainAttempts = 0;

// LoadedImages.cpp is compiled separately with dlopen renamed to this shim.
// Force the loader failure independently of host OS/path behavior while using
// real dyld catalog entries, headers, and unload notifications.
extern "C" void *ABIImageLeaseTestDlopen(const char *path, int mode)
{
    ++retainAttempts;
    assert((mode & RTLD_NOLOAD) != 0);
    return rejectRetains ? nullptr : dlopen(path, mode);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    auto address = reinterpret_cast<uintptr_t (*)(int)>(dlsym(library, "ABIFixtureAddress"));
    assert(address);
    Dl_info fixtureInfo {};
    assert(dladdr(reinterpret_cast<const void *>(address), &fixtureInfo));
    ABIImageList *list = ABICopyLoadedImages();
    assert(list);
    uint64_t fixtureGeneration = 0;
    unsigned cachedImages = 0;
    unsigned executables = 0;
    rejectRetains = true;
    for (size_t index = 0; index < ABIImageListCount(list); ++index) {
        ABIImageInfo info = ABIImageListGet(list, index);
        const auto *header = reinterpret_cast<const mach_header *>(info.header);
        if (info.header == reinterpret_cast<uintptr_t>(fixtureInfo.dli_fbase))
            fixtureGeneration = info.generation;
        if (header->filetype != MH_EXECUTE && !(header->flags & MH_DYLIB_IN_CACHE))
            continue;
        cachedImages += (header->flags & MH_DYLIB_IN_CACHE) != 0;
        executables += header->filetype == MH_EXECUTE;
        ABIImageLease *first = ABIRetainLoadedImage(info.generation);
        ABIImageLease *second = ABIRetainLoadedImage(info.generation);
        assert(first && second);
        ABIReleaseImage(first);
        ABIReleaseImage(second);
    }
    ABIFreeImageList(list);
    assert(cachedImages > 0 && executables == 1);
    assert(retainAttempts == 0);
    assert(fixtureGeneration != 0);
    assert(ABIRetainLoadedImage(fixtureGeneration) == nullptr);
    assert(retainAttempts == 1);

    rejectRetains = false;
    ABIImageLease *lease = ABIRetainLoadedImage(fixtureGeneration);
    assert(lease && retainAttempts == 2);
    dlclose(library);
    assert(*reinterpret_cast<const int *>(address(1)) == 42);
    ABIReleaseImage(lease);
    assert(ABIRetainLoadedImage(fixtureGeneration) == nullptr);
    assert(retainAttempts == 2);
}
