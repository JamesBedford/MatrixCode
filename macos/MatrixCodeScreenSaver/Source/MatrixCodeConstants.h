#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MatrixCodeModuleIdentifier;
FOUNDATION_EXPORT NSString * const MatrixCodeSessionDefaultsKey;
FOUNDATION_EXPORT NSInteger const MatrixCodeValentinesMonth;
FOUNDATION_EXPORT NSInteger const MatrixCodeValentinesDay;
FOUNDATION_EXPORT NSInteger const MatrixCodeStPatricksMonth;
FOUNDATION_EXPORT NSInteger const MatrixCodeStPatricksDay;

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
FOUNDATION_EXPORT NSArray<NSNumber *> *MatrixCodeColorPaletteForControls(
    NSDictionary<NSString *, id> *controls);
/// Local Gregorian holiday/full-moon override; fixed holidays take priority, and nil keeps the chosen preset.
FOUNDATION_EXPORT NSString * _Nullable MatrixCodeHolidayColorPreset(
    NSDate *date, NSTimeZone *timeZone);
/// Settings copy for that override, or nil on an ordinary day. The saved theme is unchanged.
FOUNDATION_EXPORT NSString * _Nullable MatrixCodeColorOverrideLabel(
    NSDate *date, NSTimeZone *timeZone);
/// In-rain greeting for that day, or nil. Fixed holidays win over a full moon.
FOUNDATION_EXPORT NSString * _Nullable MatrixCodeOccasionGreeting(
    NSDate *date, NSTimeZone *timeZone);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeSanitizeControlsDocument(
    id _Nullable rawControls);
FOUNDATION_EXPORT double MatrixCodeQuantizedControlValue(NSString *key, double value);
FOUNDATION_EXPORT double MatrixCodeNudgedDensity(double density, double factor);

NS_ASSUME_NONNULL_END
