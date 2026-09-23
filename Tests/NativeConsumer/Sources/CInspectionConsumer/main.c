#include <ABIBridge/Inspection.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    ABISymbolRuntime *shared = ABICopySharedSymbolRuntime();
    ABIRuntimeRemoveCachedResults(shared);
    ABIReleaseSymbolRuntime(shared);

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    ABISymbolRuntime *runtime = ABICreateSymbolRuntime();
    ABIResolutionFailure *failure = NULL;
    ABIResolvedSymbol *missing = ABIResolveSymbol(
        runtime, "ABIBridgeFixtureMissing", ABILanguageC, ABISymbolFunction,
        ABIImagePath, argv[1], &failure);
    assert(!missing && failure);
    assert(ABIResolutionFailureCode(failure) == ABIFailureDeclarationNotFound);
    ABIResolutionFailure *saved_failure = failure;

    ABIResolvedSymbol *table = ABIResolveSymbol(
        runtime, "vtable for ABIBridgeFixture::VirtualCounter",
        ABILanguageCXX, ABISymbolVTable, ABIImagePath, argv[1], &failure);
    assert(table && !failure);
    // Independent address oracle for this compiler-generated fixture.
    assert(ABIResolvedSymbolAddress(table) ==
           dlsym(library, "_ZTVN16ABIBridgeFixture14VirtualCounterE"));
    ABIImageInfo image;
    ABIResolvedSymbolImage(table, &image);
    assert(image.header && image.generation && image.path);

    ABIImageList *images = ABICopyLoadedImages();
    assert(images);
    int found = 0;
    for (size_t i = 0; i < ABIImageListCount(images); ++i) {
        ABIImageInfo entry = ABIImageListGet(images, i);
        if (entry.generation == image.generation) {
            assert(entry.header == image.header && entry.slide == image.slide);
            assert(memcmp(entry.uuid, image.uuid, sizeof(image.uuid)) == 0);
            assert(strcmp(entry.path, image.path) == 0);
            found = 1;
        }
    }
    assert(found);
    ABIImageLease *lease = ABIRetainLoadedImage(image.generation);
    assert(lease);
    ABIFreeImageList(images);
    assert(strlen(image.path) > 0); // This path is owned by the symbol, not the list.

    ABIResolvedSymbol *counter = ABIResolveSymbol(
        runtime, "ABIBridgeFixture::counter", ABILanguageCXX, ABISymbolData,
        ABIImagePath, argv[1], &failure);
    assert(counter && !failure);
    assert(!ABIResolveSymbol(runtime, "missing", ABILanguageC, ABISymbolData,
                             ABIImagePath, NULL, &failure));
    assert(ABIResolutionFailureCode(failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(failure);
    failure = NULL;
    assert(!ABIResolveSymbol(runtime, "missing", -1, ABISymbolData,
                             ABIImageAutomatic, NULL, NULL));

    assert(dlclose(library) == 0);
    ABIRuntimeRemoveCachedResults(runtime);
    ABIReleaseSymbolRuntime(runtime);
    assert(strstr(ABIResolutionFailureMessage(saved_failure), "ABIBridgeFixtureMissing"));
    ABIReleaseResolutionFailure(saved_failure);
    assert(*(const int *)ABIResolvedSymbolAddress(counter) == 42);
    assert(strlen(image.path) > 0);

    const int *borrowed = ABIResolvedSymbolAddress(counter);
    ABIReleaseResolvedSymbol(counter);
    ABIReleaseResolvedSymbol(table);
    // An independent lease protects addresses but does not own a symbol's path.
    assert(*borrowed == 42);
    ABIReleaseImage(lease);
    assert(!ABIRetainLoadedImage(image.generation));
    ABIFreeImageList(NULL);
    ABIReleaseImage(NULL);
    ABIReleaseResolutionFailure(NULL);
    puts("C inspection consumer passed: public header, vtable lookup, leases, and errors.");
    return 0;
}
