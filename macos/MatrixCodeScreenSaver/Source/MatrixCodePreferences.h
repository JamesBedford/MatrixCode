#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString * MatrixCodeAppPresentationMode NS_TYPED_ENUM;
FOUNDATION_EXPORT MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeWindowed;
FOUNDATION_EXPORT MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeFullScreen;
FOUNDATION_EXPORT MatrixCodeAppPresentationMode const MatrixCodeAppPresentationModeMultiMonitor;

@interface MatrixCodePreferences : NSObject

+ (MatrixCodeAppPresentationMode)savedAppPresentationMode;
+ (MatrixCodeAppPresentationMode)savedAppPresentationModeInDefaults:(NSUserDefaults *)defaults;
+ (void)setSavedAppPresentationMode:(MatrixCodeAppPresentationMode)mode;
+ (void)setSavedAppPresentationMode:(MatrixCodeAppPresentationMode)mode
                          inDefaults:(NSUserDefaults *)defaults;
+ (BOOL)isAllowedStorageKey:(NSString *)key;
- (NSDictionary<NSString *, NSString *> *)storedValues;
- (void)commitValues:(NSDictionary<NSString *, NSString *> *)values;
- (void)setImmediateValue:(nullable NSString *)value forKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
