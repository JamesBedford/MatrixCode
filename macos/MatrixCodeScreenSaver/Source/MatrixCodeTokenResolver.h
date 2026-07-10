#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeTokenResolver : NSObject

- (instancetype)initWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                         runStartDate:(NSDate *)runStartDate;
- (NSString *)resolveText:(NSString *)text atDate:(NSDate *)date framesPerSecond:(double)framesPerSecond;
+ (NSString *)formatDuration:(NSTimeInterval)seconds;
+ (nullable NSDate *)builtInMomentNamed:(NSString *)name relativeToDate:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END
