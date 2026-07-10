#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodePreferences : NSObject

+ (BOOL)isAllowedStorageKey:(NSString *)key;
- (NSDictionary<NSString *, NSString *> *)storedValues;
- (void)commitValues:(NSDictionary<NSString *, NSString *> *)values;
- (void)setImmediateValue:(nullable NSString *)value forKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
