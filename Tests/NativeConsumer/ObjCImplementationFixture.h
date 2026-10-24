#pragma once
#import <ABIBridge/ObjectiveCInvocation.h>
#include <assert.h>
#include <stdio.h>

static int implementationReceivers;

@interface ABICapturedImplementationFixture : NSObject
- (NSInteger)value;
+ (NSInteger)classValue;
- (NSObject *)copyValue;
- (void)consumeValue:(id NS_RELEASES_ARGUMENT)value;
@end
@implementation ABICapturedImplementationFixture
- (instancetype)init {
    if ((self = [super init])) ++implementationReceivers;
    return self;
}
- (void)dealloc {
    --implementationReceivers;
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
- (NSInteger)value { return 42; }
+ (NSInteger)classValue { return 17; }
- (NSObject *)copyValue { return [NSObject new]; }
- (void)consumeValue:(id)value {
#if !__has_feature(objc_arc)
    [value release];
#endif
}
@end

static NSInteger replacedValue(id receiver, SEL selector) { return 99; }

static void checkObjectiveCImplementation(void) {
    @autoreleasepool {
        ABICapturedImplementationFixture *receiver = [ABICapturedImplementationFixture new];
        NSError *error = nil;
        const ABIObjCSignature signature = {@encode(NSInteger), NULL, 0};
        ABIObjCImplementation *implementation = ABICopyObjCImplementation(
            receiver, @selector(value), &signature, (ABIObjCMethodOptions){0}, &error);
        assert(implementation && !error);
        assert(ABIRetainObjCImplementation(implementation) == implementation);
        ABIReleaseObjCImplementation(implementation);
        assert(!ABIObjCImplementationGetReturnsRetained(implementation));
        assert(!ABIObjCImplementationGetConsumesReceiver(implementation));
        ABIBoundObjCImplementation *binding = ABICopyBoundObjCImplementation(implementation, receiver, &error);
        assert(binding && !error);
        ABIObjCImplementation *copied = ABIBoundObjCImplementationCopyImplementation(binding);
        assert(copied && ABIObjCImplementationGetIMP(copied) == ABIBoundObjCImplementationGetIMP(binding));
        ABIReleaseObjCImplementation(copied);
#if __has_feature(objc_arc)
        receiver = nil;
#else
        [receiver release];
#endif
        assert(implementationReceivers == 1);
        typedef NSInteger (*Getter)(id, SEL);
        __unsafe_unretained ABICapturedImplementationFixture *retained =
            (__bridge ABICapturedImplementationFixture *)ABIBoundObjCImplementationGetReceiverAddress(binding);
        Method method = class_getInstanceMethod(ABICapturedImplementationFixture.class, @selector(value));
        IMP previous = method_setImplementation(method, (IMP)replacedValue);
        assert([retained value] == 99);
        assert(((Getter)ABIBoundObjCImplementationGetIMP(binding))(
            retained, ABIBoundObjCImplementationGetSelector(binding)) == 42);
        method_setImplementation(method, previous);
        ABIReleaseBoundObjCImplementation(binding);
        assert(implementationReceivers == 0);
        ABIReleaseObjCImplementation(implementation);

        implementation = ABICopyObjCImplementation(ABICapturedImplementationFixture.class,
            @selector(classValue), &signature, (ABIObjCMethodOptions){0}, &error);
        assert(implementation && !error);
        assert(((Getter)ABIObjCImplementationGetIMP(implementation))(
            ABICapturedImplementationFixture.class, ABIObjCImplementationGetSelector(implementation)) == 17);
        ABICapturedImplementationFixture *instance = [ABICapturedImplementationFixture new];
        assert(!ABIObjCImplementationValidateReceiver(implementation, instance, &error));
        assert([error.domain isEqualToString:ABIObjCInvocationErrorDomain] && error.code == ABIFailureSignatureMismatch);
        assert(!ABICopyBoundObjCImplementation(implementation, instance, &error));
        ABIReleaseObjCImplementation(implementation);

        const ABIObjCSignature objectSignature = {@encode(NSObject *), NULL, 0};
        implementation = ABICopyObjCImplementation(instance, @selector(copyValue),
            &objectSignature, (ABIObjCMethodOptions){0}, &error);
        assert(implementation && !error && ABIObjCImplementationGetReturnsRetained(implementation));
        ABIReleaseObjCImplementation(implementation);
        implementation = ABICopyObjCImplementation(instance, @selector(copyValue), &objectSignature,
            (ABIObjCMethodOptions){.resultOwnership = ABIObjCOwnershipBorrowed}, &error);
        assert(implementation && !error && !ABIObjCImplementationGetReturnsRetained(implementation));
        ABIReleaseObjCImplementation(implementation);
        assert(!ABICopyObjCImplementation(instance, @selector(value), &signature,
            (ABIObjCMethodOptions){.resultOwnership = ABIObjCOwnershipTransferred}, &error));
        assert(error.code == ABIFailureInvalidRequest);

        const char *parameters[] = {@encode(id)};
        const ABIObjCSignature consumingSignature = {@encode(void), parameters, 1};
        const size_t consumed[] = {0};
        implementation = ABICopyObjCImplementation(instance, @selector(consumeValue:), &consumingSignature,
            (ABIObjCMethodOptions){.consumedParameters = consumed, .consumedParameterCount = 1}, &error);
        assert(implementation && !error && ABIObjCImplementationGetConsumesParameter(implementation, 0));
        binding = ABICopyBoundObjCImplementation(implementation, instance, &error);
        assert(binding && !error && ABIBoundObjCImplementationGetConsumesParameter(binding, 0));
        ABIReleaseBoundObjCImplementation(binding);
        ABIReleaseObjCImplementation(implementation);
#if !__has_feature(objc_arc)
        [instance release];
#endif
    }
    assert(implementationReceivers == 0);
    puts("Objective-C implementation consumer passed: captured IMP identity, ownership, class receivers, and binding lifetime");
}
