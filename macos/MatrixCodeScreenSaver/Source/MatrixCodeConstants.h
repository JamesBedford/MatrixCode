#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MatrixCodeModuleIdentifier;
FOUNDATION_EXPORT NSString * const MatrixCodeSessionDefaultsKey;

typedef NS_ENUM(NSUInteger, MatrixCodeColorStop) {
    MatrixCodeColorStopBackground,
    MatrixCodeColorStopTail,
    MatrixCodeColorStopBody,
    MatrixCodeColorStopBright,
    MatrixCodeColorStopHead,
};

FOUNDATION_EXPORT NSArray<NSString *> *MatrixCodeStorageKeys(void);
FOUNDATION_EXPORT NSArray<NSString *> *MatrixCodeColorPresetNames(void);
FOUNDATION_EXPORT NSArray<NSNumber *> *MatrixCodeColorPaletteForPreset(
    NSString *presetName);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeSanitizeControlsDocument(
    id _Nullable rawControls);
FOUNDATION_EXPORT double MatrixCodeQuantizedControlValue(NSString *key, double value);
FOUNDATION_EXPORT double MatrixCodeNudgedDensity(double density, double factor);

NS_ASSUME_NONNULL_END
