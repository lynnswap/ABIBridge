// These are test checks in the optimized device host as well.
#undef NDEBUG
#import <Foundation/Foundation.h>
#include "ArchitectureFixtures.h"
#include "../../../NativeConsumer/ObjCInvocationFixture.hpp"

const char *ABIValidateExtractedObjCImplementations() {
    static thread_local std::string failure;
    try {
        @autoreleasepool {
            checkReusableCapturedImplementation();
            checkAssignmentReentry(false);
            checkAssignmentReentry(true);
#if !__has_feature(objc_arc)
            checkReceiverRetainReentry();
#endif
        }
        return nullptr;
    } catch (const std::exception& error) {
        failure = error.what();
        return failure.c_str();
    }
}
