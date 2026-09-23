#pragma once
#include <ABIBridge/Inspection.hpp>
#import <Foundation/Foundation.h>
#include <cassert>
#include <dlfcn.h>
#include <cstdio>

static int destroyedInspectionOwners = 0;

@interface CXXInspectionOwner : NSObject
- (instancetype)initWithSymbol:(abi_bridge::resolved_symbol)symbol;
- (const void *)address;
@end

@implementation CXXInspectionOwner {
    std::optional<abi_bridge::resolved_symbol> _symbol;
}
- (instancetype)initWithSymbol:(abi_bridge::resolved_symbol)symbol {
    self = [super init];
    if (self) _symbol = std::move(symbol);
    return self;
}
- (const void *)address { return _symbol->unsafe_address(); }
- (void)dealloc {
    ++destroyedInspectionOwners;
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end

int main(int argc, char **argv) {
    assert(argc == 2);
    using namespace abi_bridge;
    std::uint64_t generation = 0;
    @autoreleasepool {
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(library);
        __attribute__((objc_precise_lifetime)) CXXInspectionOwner *owner = nil;
        {
            Runtime runtime;
            auto table = runtime.resolve(
                {"vtable for ABIBridgeFixture::VirtualCounter", language::cxx, symbol_kind::vtable},
                image_selector::path(argv[1]));
            generation = table.image().load_generation;
            owner = [[CXXInspectionOwner alloc] initWithSymbol:std::move(table)];
            assert(!table);
            assert(dlclose(library) == 0);
            runtime.remove_cached_results();
        }
        // The C++ member owns the symbol after both the runtime and loader drop it.
        Dl_info loaded{};
        assert(dladdr(owner.address, &loaded));
        assert(destroyedInspectionOwners == 0);
#if __has_feature(objc_arc)
        owner = nil;
#else
        [owner release];
        owner = nil;
#endif
    }
    assert(destroyedInspectionOwners == 1);
    assert(!image_lease::acquire(generation));
#if __has_feature(objc_arc)
    std::puts("Objective-C++ inspection consumer passed: public C++ wrappers with ARC.");
#else
    std::puts("Objective-C++ inspection consumer passed: public C++ wrappers with manual reference counting.");
#endif
}
