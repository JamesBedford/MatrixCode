#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@class MatrixCodeMetalView;

typedef void (^MatrixCodeMetalFrameHandler)(MatrixCodeMetalView *view,
                                            NSDate *date,
                                            double framesPerSecond);

@interface MatrixCodeMetalView : MTKView

@property(nonatomic, copy, nullable) MatrixCodeMetalFrameHandler frameHandler;
@property(nonatomic, readonly) double currentRenderScale;
@property(nonatomic, readonly) CGSize currentRenderSize;

+ (NSInteger)maximumFramesPerSecondForScreen:(nullable NSScreen *)screen;
- (instancetype)initWithFrame:(NSRect)frame
                      session:(nullable NSDictionary<NSString *, id> *)session
                storedValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)configureFramePacingForScreen:(nullable NSScreen *)screen;
- (void)setAnimationActive:(BOOL)active;
- (void)freezeAnimationAtDate:(NSDate *)date;
- (void)prepareReducedMotionFrame;
- (void)restartDeterministicRainFromEmpty:(BOOL)startsFromEmpty;
- (void)setTokenTimelineStartDate:(NSDate *)date;
- (void)shiftTokenTimelineBy:(NSTimeInterval)interval;
- (void)previewMessageAtDate:(NSDate *)date;
- (void)previewMessageWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                                atDate:(NSDate *)date;
- (void)setDensityScale:(double)densityScale;
- (void)setDensityScale:(double)densityScale rainElapsed:(NSTimeInterval)rainElapsed;
- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues;
#if DEBUG
+ (float)diagnosticEffectiveTrailLength:(float)trailLength
                                  rows:(float)rows
                          speedControl:(float)speedControl;
+ (NSInteger)diagnosticFramesPerSecondForScreenMaximum:(NSInteger)screenMaximum
                                displayModeRefreshRate:(double)displayModeRefreshRate
                                displayLinkRefreshRate:(double)displayLinkRefreshRate;
+ (NSString *)diagnosticAtlasPrimaryFontNameForGlyph:(NSString *)glyph
                                            controls:(NSDictionary<NSString *, id> *)controls;
+ (BOOL)diagnosticDrawsReadableDigitGlyph:(NSString *)glyph
                                 controls:(NSDictionary<NSString *, id> *)controls;
+ (NSString *)diagnosticAtlasDisplayGlyphForGlyph:(NSString *)glyph
                                            index:(NSUInteger)index
                                   rainGlyphCount:(NSUInteger)rainGlyphCount
                                         controls:(NSDictionary<NSString *, id> *)controls;
+ (float)diagnosticProceduralDigitValueForGlyphIndex:(NSInteger)glyph
                                      rainGlyphCount:(NSInteger)rainGlyphCount
                                            controls:(NSDictionary<NSString *, id> *)controls;
+ (float)diagnosticStepChanceForReferenceRateChance:(float)chance
                                             elapsed:(float)elapsed
                                       referenceRate:(float)referenceRate;
+ (uint32_t)diagnosticNormalRainSeed;
+ (uint32_t)diagnosticRainSeedForLane:(NSInteger)laneIndex;
- (NSData *)diagnosticPackedStateWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)diagnosticRendererConsumesPackedStateWithWidth:(NSUInteger)width
                                                 height:(NSUInteger)height;
- (double)diagnosticUpdateAdaptiveResolutionWithFrameMilliseconds:(double)frameMilliseconds;
- (nullable NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (NSArray<NSNumber *> *)diagnosticGlyphStateSnapshotWithWidth:(NSUInteger)width height:(NSUInteger)height;
#endif

@end

NS_ASSUME_NONNULL_END
