#include <ABIBridge/Inspection.h>
#include <ABIBridge/VirtualEntries.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "../../LazyLibraryFixture.h"

static void test_lazy_libraries(void) {
    char path[] = "/tmp/abibridge-lazy-c-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    unsigned char *bytes = ABITestLazyCreate(1, 0);
    assert(bytes && ABITestLazyWrite(path, bytes));
    free(bytes);
    ABIResolutionFailure *error = NULL;
    ABILazyLibraryList *list = ABICopyLazyLibrariesInFile(path, &error);
    unlink(path);
    assert(list && !error && ABILazyLibraryListGetCount(list) == 3);
    ABILazyLibraryInfo info = ABILazyLibraryListGetLibrary(list, 0);
    assert(info.isOptional == ABIDiagnosticTrue && info.isInitialized == ABIDiagnosticUnknown);
    assert(info.symbolCount == 3 && strcmp(info.path, "@rpath/Example.dylib") == 0);
    assert(strcmp(ABILazyLibraryListGetSymbol(list, 0, 0).name, "Example::Renderer::refresh()") == 0);
    assert(ABILazyLibraryListGetLibrary(list, 2).symbolsAvailable == ABIDiagnosticFalse);
    ABIReleaseLazyLibraryList(list);
    assert(!ABICopyLazyLibrariesForImage(UINT64_MAX, &error));
    assert(error && ABIResolutionFailureGetCode(error) == ABIFailureImageChanged);
    ABIReleaseResolutionFailure(error);
}

int main(int argc, char **argv) {
    test_lazy_libraries();
    assert(argc == 2);
    unsigned char source[] = {1, 2, 3, 4};
    unsigned char copied[3] = {0};
    ABIMemoryReadResult read = ABIReadMemory((uintptr_t)(source + 1), 3, copied);
    assert(read.status == ABIMemoryReadComplete && read.byteCount == 3);
    assert(read.systemError == 0 && memcmp(copied, source + 1, 3) == 0);
    assert(ABIReadMemory(UINTPTR_MAX, 1, copied).status == ABIMemoryReadInvalidRange);
    assert(ABIReadMemory(0, 1, copied).status == ABIMemoryReadFailed);
    assert(ABIReadMemory(0, 1, NULL).status == ABIMemoryReadInvalidRange);
    assert(ABIReadMemory(UINTPTR_MAX, 0, NULL).status == ABIMemoryReadComplete);
    uintptr_t vtable = 123;
    uintptr_t object[] = {vtable};
    uintptr_t references[] = {0, (uintptr_t)object, (uintptr_t)object};
    ABIPointerSearchOptions options = ABIDefaultPointerSearchOptions();
    assert(options.normalization == ABIPointerNormalizationAutomatic);
    options.address = (uintptr_t)references;
    options.byteCount = sizeof(references);
    options.vtableAddressPoint = vtable;
    ABIPointerInspectionResult inspected = ABIInspectPointer(
        (uintptr_t)references, sizeof(references), sizeof(uintptr_t), vtable, 0, ABIPointerNormalizationAutomatic);
    assert(inspected.status == ABIPointerInspectionMatch && inspected.candidate.pointerBits == (uintptr_t)object);
    inspected = ABIInspectPointer((uintptr_t)references, sizeof(references), 0, vtable, 0, ABIPointerNormalizationNone);
    assert(inspected.status == ABIPointerInspectionNoMatch);
    inspected = ABIInspectPointer((uintptr_t)references, sizeof(references), sizeof(references), vtable, 0, 0);
    assert(inspected.status == ABIPointerInspectionInvalidOptions);
    inspected = ABIInspectPointer((uintptr_t)references, sizeof(references), 0, vtable, 0, -1);
    assert(inspected.status == ABIPointerInspectionInvalidOptions);
    references[0] = 1;
    inspected = ABIInspectPointer((uintptr_t)references, sizeof(references), 0, vtable, 0, 0);
    assert(inspected.status == ABIPointerInspectionReadFailed && inspected.failure.stage == ABIPointerSearchVPtrRead);
    references[0] = 0;
    int32_t search_error = -1;
    ABIPointerSearchResult *search = ABICopyPointerSearch(&options, &search_error);
    assert(search && search_error == ABIPointerSearchSuccess);
    assert(ABIPointerSearchResultIsComplete(search) && ABIPointerSearchResultGetDistinctCount(search) == 1);
    assert(ABIPointerSearchResultGetCandidateCount(search) == 2 && ABIPointerSearchResultGetVisitedCount(search) == 3);
    assert(ABIPointerSearchResultGetCandidate(search, 1).pointerBits == (uintptr_t)object);
    assert(ABIPointerSearchResultGetFailureCount(search) == 0);
    ABIReleasePointerSearchResult(search);
    options.stride = 0;
    assert(!ABICopyPointerSearch(&options, &search_error));
    assert(search_error == ABIPointerSearchInvalidOptions);
    ABIReleasePointerSearchResult(NULL);

    ABISymbolRuntime *shared = ABICopySharedSymbolRuntime();
    ABISymbolRuntimeRemoveCachedResults(shared);
    ABIReleaseSymbolRuntime(shared);

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    ABISymbolRuntime *runtime = ABICreateSymbolRuntime();
    ABIResolutionFailure *failure = NULL;
    ABIResolvedSymbol *missing = ABIResolveSymbol(runtime, &(ABISymbolRequest){
        .declaration = {"ABIBridgeFixtureMissing", ABILanguageC, ABISymbolFunction, ABINameSource},
        .imageScopes = &(ABIImageSelector){ABIImagePath, argv[1]},
        .imageScopeCount = 1, .loading = ABIImageLoadIfNeeded
    }, &failure);
    assert(!missing && failure);
    assert(ABIResolutionFailureGetCode(failure) == ABIFailureDeclarationNotFound);
    ABIResolutionFailure *saved_failure = failure;

    ABIResolvedSymbol *table = ABIResolveCXXVTable(runtime, "ABIBridgeFixture::VirtualCounter", (ABIImageSelector){ABIImagePath, argv[1]}, ABIImageLoadIfNeeded, &failure);
    assert(table && !failure);
    // Independent address oracle for this compiler-generated fixture.
    assert(ABIResolvedSymbolGetAddress(table) ==
           dlsym(library, "_ZTVN16ABIBridgeFixture14VirtualCounterE"));
    // This fixture has one primary absolute entry after two ABI header words.
    const void *address_point = (const char *)ABIResolvedSymbolGetAddress(table) + 2 * sizeof(void *);
    ABIVirtualEntry *entry = ABICopyVirtualEntry(runtime, address_point, 1,
        "ABIBridgeFixture::VirtualCounter::current() const", &failure);
    assert(entry && !failure);
    ABIVirtualEntryInfo selected = ABIVirtualEntryGetInfo(entry);
    assert(selected.addressPoint == address_point && selected.index == 0 && selected.entryCount == 1);
    assert(selected.key == ABIAuthenticationUnsigned);
    assert(strstr(ABIVirtualEntryGetSymbolName(entry), "current"));
    ABIReleaseVirtualEntry(entry);
    ABIReleaseVirtualEntry(NULL);

    ABIImageInfo image;
    ABIResolvedSymbolGetImage(table, &image);
    assert(image.header && image.generation && image.path);

    ABIImageList *images = ABICopyLoadedImages();
    assert(images);
    int found = 0;
    for (size_t i = 0; i < ABIImageListGetCount(images); ++i) {
        ABIImageInfo entry = ABIImageListGetImage(images, i);
        if (entry.generation == image.generation) {
            assert(entry.header == image.header && entry.slide == image.slide);
            assert(memcmp(entry.uuid, image.uuid, sizeof(image.uuid)) == 0);
            assert(strcmp(entry.path, image.path) == 0);
            found = 1;
        }
    }
    assert(found);
    ABIImageLease *lease = ABIAcquireImageLease(image.generation);
    assert(lease);
    ABIReleaseImageList(images);
    assert(strlen(image.path) > 0); // This path is owned by the symbol, not the list.

    ABIResolvedSymbol *counter = ABIResolveSymbol(runtime, &(ABISymbolRequest){
        .declaration = {"ABIBridgeFixture::counter", ABILanguageCXX, ABISymbolData, ABINameSource},
        .imageScopes = &(ABIImageSelector){ABIImagePath, argv[1]},
        .imageScopeCount = 1, .loading = ABIImageLoadIfNeeded
    }, &failure);
    assert(counter && !failure);
    assert(!ABIResolveSymbol(runtime, &(ABISymbolRequest){
        .declaration = {"missing", ABILanguageC, ABISymbolData, ABINameSource},
        .imageScopes = &(ABIImageSelector){ABIImagePath, NULL},
        .imageScopeCount = 1, .loading = ABIImageLoadIfNeeded
    }, &failure));
    assert(ABIResolutionFailureGetCode(failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(failure);
    failure = NULL;
    assert(!ABIResolveSymbol(runtime, &(ABISymbolRequest){
        .declaration = {"missing", -1, ABISymbolData, ABINameSource},
        .imageScopes = &(ABIImageSelector){ABIImageAutomatic, NULL},
        .imageScopeCount = 1, .loading = ABIImageLoadIfNeeded
    }, NULL));

    ABIImageSelector scopes[] = {{ABIImageFramework, "ABIBridgeAbsentFixture"}, {ABIImagePath, argv[1]}};
    ABIDeclaration counter_declaration = {"ABIBridgeFixture::counter", ABILanguageCXX, ABISymbolData};
    ABIDeclaration exact_counter = {"_ZN16ABIBridgeFixture7counterE", ABILanguageCXX, ABISymbolData, ABINameLinker};
    ABIResolvedSymbol *literal_counter = ABIResolveSymbol(runtime, &(ABISymbolRequest){
        .declaration = {"__ZN16ABIBridgeFixture7counterE", ABILanguageCXX, ABISymbolData, ABINameMachO},
        .imageScopes = &(ABIImageSelector){ABIImagePath, argv[1]},
        .imageScopeCount = 1, .loading = ABIImageLoadIfNeeded
    }, &failure);
    assert(literal_counter && !failure);
    assert(ABIResolvedSymbolGetAddress(literal_counter) == ABIResolvedSymbolGetAddress(counter));
    ABIReleaseResolvedSymbol(literal_counter);
    ABISymbolRequest requests[] = {
        {counter_declaration, &exact_counter, 1, scopes, 2},
        {{"ABIBridgeBatchMissing", ABILanguageC, ABISymbolData}, NULL, 0, scopes, 2}
    };
    ABISymbolResult outcomes[2] = {{0}};
    ABIResolveSymbols(runtime, NULL, 0, NULL);
    ABIResolveSymbols(runtime, requests, 2, outcomes);
    assert(outcomes[0].symbol && !outcomes[0].failure);
    assert(!outcomes[1].symbol && outcomes[1].failure);
    assert(*(const int *)ABIResolvedSymbolGetAddress(outcomes[0].symbol) == 42);
    assert(ABIResolutionFailureGetCode(outcomes[1].failure) == ABIFailureDeclarationNotFound);
    ABIResolvedSymbol *aliased = ABIResolveSymbol(runtime, &requests[0], &failure);
    assert(aliased && !failure && ABIResolvedSymbolGetAddress(aliased) == ABIResolvedSymbolGetAddress(counter));
    ABIReleaseResolvedSymbol(aliased);
    ABISymbolRequest empty_request = requests[0];
    empty_request.imageScopeCount = 0;
    assert(!ABIResolveSymbol(runtime, &empty_request, &failure));
    assert(failure && ABIResolutionFailureGetCode(failure) == ABIFailureImageNotLoaded);
    ABIReleaseResolutionFailure(failure);
    failure = NULL;
    ABIReleaseResolvedSymbol(outcomes[0].symbol);
    ABIReleaseResolutionFailure(outcomes[1].failure);

    ABIDeclaration lazy_candidates[] = {
        counter_declaration,
        {"notASelector:", ABILanguageObjectiveC, ABISymbolFunction}
    };
    ABISymbolRequest lazy_request = {
        {"ABIBridgeLazyMissing", ABILanguageC, ABISymbolData}, NULL, 0, scopes, 2,
        lazy_candidates, 2
    };
    ABISymbolResult lazy_result = {0};
    lazy_result.symbol = ABIResolveSymbol(runtime, &lazy_request, &lazy_result.failure);
    assert(lazy_result.symbol && !lazy_result.failure);
    lazy_request.declaration = exact_counter;
    lazy_request.fallbacks = lazy_candidates + 1;
    lazy_request.fallbackCount = 1;
    ABISymbolResult skipped_result = {0};
    ABIResolveSymbols(runtime, &lazy_request, 1, &skipped_result);
    assert(skipped_result.symbol && !skipped_result.failure);
    ABIReleaseResolvedSymbol(skipped_result.symbol);
    lazy_request.fallbacks = NULL;
    ABISymbolResult invalid_result = {0};
    ABIResolveSymbols(runtime, &lazy_request, 1, &invalid_result);
    assert(!invalid_result.symbol && ABIResolutionFailureGetCode(invalid_result.failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(invalid_result.failure);

    assert(dlclose(library) == 0);
    ABISymbolRuntimeRemoveCachedResults(runtime);
    ABIReleaseSymbolRuntime(runtime);
    assert(*(const int *)ABIResolvedSymbolGetAddress(lazy_result.symbol) == 42);
    ABIReleaseResolvedSymbol(lazy_result.symbol);
    assert(strstr(ABIResolutionFailureGetMessage(saved_failure), "ABIBridgeFixtureMissing"));
    ABIReleaseResolutionFailure(saved_failure);
    assert(*(const int *)ABIResolvedSymbolGetAddress(counter) == 42);
    assert(strlen(image.path) > 0);

    const int *borrowed = ABIResolvedSymbolGetAddress(counter);
    ABIResolvedSymbol *retained_counter = ABIRetainResolvedSymbol(counter);
    ABIReleaseResolvedSymbol(counter);
    assert(*(const int *)ABIResolvedSymbolGetAddress(retained_counter) == 42);
    ABIReleaseResolvedSymbol(retained_counter);
    ABIReleaseResolvedSymbol(table);
    // An independent lease protects addresses but does not own a symbol's path.
    assert(*borrowed == 42);
    ABIReleaseImageLease(lease);
    assert(!ABIAcquireImageLease(image.generation));
    ABIReleaseImageList(NULL);
    ABIReleaseImageLease(NULL);
    ABIReleaseResolutionFailure(NULL);
    puts("C inspection consumer passed: public header, vtable lookup, leases, and errors.");
    return 0;
}
