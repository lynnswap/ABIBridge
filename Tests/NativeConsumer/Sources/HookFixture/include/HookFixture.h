#pragma once
#include <objc/runtime.h>
#include <stdint.h>
typedef struct ABIHookPair { double x, y; } ABIHookPair;
#ifdef __OBJC__
#import <Foundation/Foundation.h>
@interface ABINativeHookResult : NSObject
@property(class, nonatomic, readonly) NSInteger liveObjects;
@end
@interface ABINativeHookFixture : NSObject
@property(nonatomic) int32_t calls;
@property(nonatomic) int32_t seed;
- (nullable instancetype)initWithSeed:(int32_t)seed;
- (int32_t)add:(int32_t)a to:(int32_t)b;
- (ABINativeHookResult *)copyObject;
- (ABIHookPair)shift:(ABIHookPair)value;
- (int32_t (^)(int32_t))block;
@end
#endif
#ifdef __cplusplus
extern "C" {
#endif
Class ABIHookFixtureClass(void);
void *ABIHookFixtureCreate(int32_t seed);
void ABIHookFixtureRelease(void *object);
int32_t ABIHookFixtureAdd(void *object, int32_t a, int32_t b);
int32_t ABIHookFixtureSeed(void *object);
void ABIHookFixtureSetSeed(void *object, int32_t seed);
int32_t ABIHookFixtureCalls(void *object);
ABIHookPair ABIHookFixtureShift(void *object, ABIHookPair value);
#ifdef __cplusplus
}
#endif
#include <ABIBridge/ObjectiveCHooks.h>
#ifdef __cplusplus
extern "C" {
#endif
ABIObjCMethodHook *ABIHookFixtureInstallMethod(void *context, void (*event)(void *, int), void (*release)(void *));
ABIObjCMethodHook *ABIHookFixtureInstallInitializer(void *context, void (*event)(void *, int), void (*release)(void *));
#ifdef __cplusplus
}
#endif
