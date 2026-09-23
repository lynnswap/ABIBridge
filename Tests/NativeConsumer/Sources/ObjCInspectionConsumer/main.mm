#include <ABIBridge/Inspection.h>
#import <Foundation/Foundation.h>
#include <cassert>
#include <cstring>
#include <dlfcn.h>

@interface InspectionOwner : NSObject
- (instancetype)initWithSymbol:(ABIResolvedSymbol *)symbol;
- (ABIResolvedSymbol *)symbol;
@end

@implementation InspectionOwner {
    ABIResolvedSymbol *_symbol;
}
- (instancetype)initWithSymbol:(ABIResolvedSymbol *)symbol {
    self = [super init];
    if (self) _symbol = symbol;
    return self;
}
- (ABIResolvedSymbol *)symbol { return _symbol; }
- (void)dealloc { ABIReleaseResolvedSymbol(_symbol); }
@end

int main(int argc, char **argv) {
    assert(argc == 2);
    @autoreleasepool {
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(library);
        auto *runtime = ABICreateSymbolRuntime();
        ABIResolutionFailure *failure = nullptr;
        auto *table = ABIResolveSymbol(
            runtime, "vtable for ABIBridgeFixture::VirtualCounter",
            ABILanguageCXX, ABISymbolVTable, ABIImagePath, argv[1], &failure);
        assert(table && !failure);
        ABIImageInfo image{};
        ABIResolvedSymbolImage(table, &image);
        const auto generation = image.generation;
        __weak InspectionOwner *observed;
        {
            InspectionOwner *owner = [[InspectionOwner alloc] initWithSymbol:table];
            observed = owner;
            assert(dlclose(library) == 0);
            ABIRuntimeRemoveCachedResults(runtime);
            ABIReleaseSymbolRuntime(runtime);
            ABIResolvedSymbolImage(owner.symbol, &image);
            assert(image.generation == generation && std::strlen(image.path));
            Dl_info loaded{};
            assert(dladdr(ABIResolvedSymbolAddress(owner.symbol), &loaded));
            assert(reinterpret_cast<uintptr_t>(loaded.dli_fbase) == image.header);
            owner = nil;
        }
        assert(!observed);
        assert(!ABIRetainLoadedImage(generation));
    }
    puts("Objective-C++ inspection consumer passed: public C API and ARC-held symbol lifetime.");
}
