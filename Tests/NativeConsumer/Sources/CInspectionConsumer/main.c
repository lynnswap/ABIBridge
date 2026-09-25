#include <ABIBridge/Inspection.h>
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
    assert(list && !error && ABILazyLibraryListCount(list) == 3);
    ABILazyLibraryInfo info = ABILazyLibraryListGet(list, 0);
    assert(info.isOptional == ABIDiagnosticTrue && info.isInitialized == ABIDiagnosticUnknown);
    assert(info.symbolCount == 3 && strcmp(info.path, "@rpath/Example.dylib") == 0);
    assert(strcmp(ABILazyLibraryListSymbol(list, 0, 0).name, "Example::Renderer::refresh()") == 0);
    assert(ABILazyLibraryListGet(list, 2).symbolsAvailable == ABIDiagnosticFalse);
    ABIFreeLazyLibraryList(list);
    assert(!ABICopyLazyLibrariesForImage(UINT64_MAX, &error));
    assert(error && ABIResolutionFailureCode(error) == ABIFailureImageChanged);
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
    assert(ABIPointerSearchIsComplete(search) && ABIPointerSearchDistinctCount(search) == 1);
    assert(ABIPointerSearchCandidateCount(search) == 2 && ABIPointerSearchVisitedCount(search) == 3);
    assert(ABIPointerSearchCandidateAt(search, 1).pointerBits == (uintptr_t)object);
    assert(ABIPointerSearchFailureCount(search) == 0);
    ABIFreePointerSearch(search);
    options.stride = 0;
    assert(!ABICopyPointerSearch(&options, &search_error));
    assert(search_error == ABIPointerSearchInvalidOptions);
    ABIFreePointerSearch(NULL);

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

    ABIResolvedSymbol *table = ABIResolveCXXVTable(
        runtime, "ABIBridgeFixture::VirtualCounter", ABIImagePath, argv[1], &failure);
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

    ABIImageSelector scopes[] = {{ABIImageFramework, "ABIBridgeAbsentFixture"}, {ABIImagePath, argv[1]}};
    ABIDeclaration counter_declaration = {"ABIBridgeFixture::counter", ABILanguageCXX, ABISymbolData};
    ABIDeclaration exact_counter = {"_ZN16ABIBridgeFixture7counterE", ABILanguageCXX, ABISymbolData, ABINameLinker};
    ABIResolvedSymbol *literal_counter = ABIResolveSymbolWithNameForm(
        runtime, "__ZN16ABIBridgeFixture7counterE", ABINameMachO,
        ABILanguageCXX, ABISymbolData, ABIImagePath, argv[1], &failure);
    assert(literal_counter && !failure);
    assert(ABIResolvedSymbolAddress(literal_counter) == ABIResolvedSymbolAddress(counter));
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
    assert(*(const int *)ABIResolvedSymbolAddress(outcomes[0].symbol) == 42);
    assert(ABIResolutionFailureCode(outcomes[1].failure) == ABIFailureDeclarationNotFound);
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
    ABIResolveSymbols(runtime, &lazy_request, 1, &lazy_result);
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
    assert(!invalid_result.symbol && ABIResolutionFailureCode(invalid_result.failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(invalid_result.failure);

    assert(dlclose(library) == 0);
    ABIRuntimeRemoveCachedResults(runtime);
    ABIReleaseSymbolRuntime(runtime);
    assert(*(const int *)ABIResolvedSymbolAddress(lazy_result.symbol) == 42);
    ABIReleaseResolvedSymbol(lazy_result.symbol);
    assert(strstr(ABIResolutionFailureMessage(saved_failure), "ABIBridgeFixtureMissing"));
    ABIReleaseResolutionFailure(saved_failure);
    assert(*(const int *)ABIResolvedSymbolAddress(counter) == 42);
    assert(strlen(image.path) > 0);

    const int *borrowed = ABIResolvedSymbolAddress(counter);
    ABIResolvedSymbol *retained_counter = ABIRetainResolvedSymbol(counter);
    ABIReleaseResolvedSymbol(counter);
    assert(*(const int *)ABIResolvedSymbolAddress(retained_counter) == 42);
    ABIReleaseResolvedSymbol(retained_counter);
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
