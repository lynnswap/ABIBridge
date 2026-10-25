#import <ABIBridge/ABIBridge.h>
#import <ABIBridge/ObjectiveCInvocation.h>
#include <assert.h>

void ABIValidateObjCConsumerHeaders(void) {
    ABIResolutionFailure *failure = NULL;
    ABIValueType *integer = ABICreateScalarType(ABIValueInt32, &failure);
    assert(integer && !failure);
    ABIReleaseValueType(integer);
    @autoreleasepool {
        NSError *error = [NSError errorWithDomain:ABIObjCInvocationErrorDomain code:0 userInfo:nil];
        assert([error.domain isEqualToString:ABIObjCInvocationErrorDomain]);
    }
    ABIPointerSlotResult effect = {0};
    assert(!effect.didWrite && ABIAuthenticationUnsigned == -1);
}
