#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@class MatrixCodeMetalView;

typedef void (^MatrixCodeMetalFrameHandler)(MatrixCodeMetalView *view,
                                            NSDate *date,
                                            double framesPerSecond);

@interface MatrixCodeMetalView : MTKView

@property(nonatomic, copy, nullable) MatrixCodeMetalFrameHandler frameHandler;

+ (NSInteger)maximumFramesPerSecondForScreen:(nullable NSScreen *)screen;
- (instancetype)initWithFrame:(NSRect)frame
                      session:(nullable NSDictionary<NSString *, id> *)session
                storedValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)configureFramePacingForScreen:(nullable NSScreen *)screen;
- (void)setAnimationActive:(BOOL)active;
- (void)freezeAnimationAtDate:(NSDate *)date;
- (void)setDensityScale:(float)densityScale;
- (void)setDensityScale:(float)densityScale rainElapsed:(NSTimeInterval)rainElapsed;
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
- (nullable NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (NSArray<NSNumber *> *)diagnosticGlyphStateSnapshotWithWidth:(NSUInteger)width height:(NSUInteger)height;
#endif

@end

NS_ASSUME_NONNULL_END
