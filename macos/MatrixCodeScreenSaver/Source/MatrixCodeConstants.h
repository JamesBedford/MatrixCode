#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MatrixCodeModuleIdentifier;
FOUNDATION_EXPORT NSString * const MatrixCodeSessionDefaultsKey;
FOUNDATION_EXPORT NSArray<NSString *> *MatrixCodeStorageKeys(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeSanitizeControlsDocument(
    id _Nullable rawControls);
FOUNDATION_EXPORT double MatrixCodeQuantizedControlValue(NSString *key, double value);
FOUNDATION_EXPORT double MatrixCodeNudgedDensity(double density, double factor);

NS_ASSUME_NONNULL_END
