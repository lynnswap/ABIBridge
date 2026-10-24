#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol LGStore <NSObject>
- (void)storeValue:(int64_t)value;
- (void)removeObject:(id)object;                       // omit-needless-words -> remove(_:)
- (void)insertString:(NSString *)string atIndex:(NSInteger)index; // insert(_:at:)
- (int64_t)plain;
- (int64_t)renamedThing:(int64_t)x NS_SWIFT_NAME(extra(_:));
- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error;   // save(to:) throws
- (void)fetchValueWithCompletionHandler:(void (^)(int64_t))handler; // fetchValue(completionHandler:), fetchValue() async
+ (int64_t)make;
- (instancetype)initWithSeed:(int64_t)seed;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, readonly, getter=isOn) BOOL on;
- (id)objectForKeyedSubscript:(NSString *)key;
@optional
- (int64_t)maybe;
- (int64_t)hiddenThing NS_REFINED_FOR_SWIFT;
- (int64_t)gone NS_SWIFT_UNAVAILABLE("no");
@end
NS_ASSUME_NONNULL_END
