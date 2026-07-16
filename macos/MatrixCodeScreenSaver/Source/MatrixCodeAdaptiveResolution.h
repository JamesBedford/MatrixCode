#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double targetMilliseconds;
    double minimumScale;
    double step;
    double emaAlpha;
    double upHeadroom;
    double downThreshold;
    NSInteger cooldownFrames;
    NSInteger warmFrames;
} MatrixCodeAdaptiveResolutionConfig;

FOUNDATION_EXPORT MatrixCodeAdaptiveResolutionConfig
    MatrixCodeAdaptiveResolutionDefaultConfig(void);

/** Pure port of src/gl/adaptiveResolution.ts. */
@interface MatrixCodeAdaptiveResolution : NSObject

- (instancetype)initWithConfig:(MatrixCodeAdaptiveResolutionConfig)config
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property(nonatomic, readonly) double value;
@property(nonatomic, readonly) double smoothedMilliseconds;

- (void)reset;
- (double)updateWithFrameMilliseconds:(double)frameMilliseconds;

@end

NS_ASSUME_NONNULL_END
