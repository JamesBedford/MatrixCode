#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/** Portable mx-images limits shared by configuration, playback, and other native hosts. */
FOUNDATION_EXPORT NSUInteger const MatrixCodeImageMaskMaximumDimension;
FOUNDATION_EXPORT NSUInteger const MatrixCodeImageMaximumCount;
FOUNDATION_EXPORT NSUInteger const MatrixCodeImageNameMaximumLength;
FOUNDATION_EXPORT NSUInteger const MatrixCodeImageMaskMaximumStoredCharacters;

/**
 * Private, one-time compatibility backup. Its value is the original raw mx-images JSON string;
 * it is deliberately not part of MatrixCodeStorageKeys and therefore never crosses host bridges.
 */
FOUNDATION_EXPORT NSString * const MatrixCodeImagesPortableBackupDefaultsKey;

FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeDefaultImagesDocument(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MatrixCodeSanitizeImageItem(
    id _Nullable rawItem);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeSanitizeImagesDocument(
    id _Nullable rawDocument);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MatrixCodeSanitizeImagesJSONString(
    NSString * _Nullable rawJSON);

/** True when portable canonicalization would change/drop a previously valid item or trim the list. */
FOUNDATION_EXPORT BOOL MatrixCodeImagesJSONStringRequiresPortableBackup(
    NSString * _Nullable rawJSON);

typedef struct {
    NSInteger width;
    NSInteger height;
} MatrixCodeImageMaskDimensions;

/** Aspect-fit source pixels without upscaling, using the portable 96-cell maximum. */
FOUNDATION_EXPORT MatrixCodeImageMaskDimensions MatrixCodeImageMaskDimensionsForSource(
    NSUInteger sourceWidth,
    NSUInteger sourceHeight);

/**
 * Convert premultiplied RGBA8 pixels to the persisted one-byte luminance mask. RGB is intentionally
 * multiplied by alpha again, preserving the established native alpha-squared import appearance.
 */
FOUNDATION_EXPORT NSData * _Nullable MatrixCodeImageMaskFromPremultipliedRGBA(
    NSData *rgba,
    NSInteger width,
    NSInteger height);

/** Pure reveal primitives, exported so every backend can lock against deterministic fixtures. */
FOUNDATION_EXPORT uint32_t MatrixCodeImageHash(uint32_t value);
FOUNDATION_EXPORT float MatrixCodeImageUnit(uint32_t value);
/** Match the web scheduler's double-precision floor before narrowing to the uint uniform. */
FOUNDATION_EXPORT uint32_t MatrixCodeImageAnimationBucket(NSTimeInterval nowSeconds,
                                                          NSTimeInterval epochSeconds);
FOUNDATION_EXPORT uint32_t MatrixCodeImageCellIdentity(uint32_t laneSeed,
                                                       NSInteger globalColumn,
                                                       NSInteger globalRow);
FOUNDATION_EXPORT float MatrixCodeImageSampleMask(NSData *mask,
                                                  NSInteger width,
                                                  NSInteger height,
                                                  float u,
                                                  float v);
FOUNDATION_EXPORT float MatrixCodeImageSignalForLuminance(float luminance);
FOUNDATION_EXPORT float MatrixCodeImageEdgeFeather(float u,
                                                   float v,
                                                   float featherU,
                                                   float featherV);
FOUNDATION_EXPORT float MatrixCodeImageFallingGate(NSInteger globalColumn,
                                                   NSInteger globalRow,
                                                   float rainElapsed,
                                                   uint32_t seed);
FOUNDATION_EXPORT NSInteger MatrixCodeImageGlyphForLuminance(float luminance,
                                                             uint32_t key,
                                                             NSString *glyphMode);

NS_ASSUME_NONNULL_END
