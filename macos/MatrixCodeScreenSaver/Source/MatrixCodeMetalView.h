#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeMetalView : MTKView

- (instancetype)initWithFrame:(NSRect)frame
                      session:(nullable NSDictionary<NSString *, id> *)session
                storedValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)setAnimationActive:(BOOL)active;
- (void)setDensityScale:(float)densityScale;
- (void)setDensityScale:(float)densityScale rainElapsed:(NSTimeInterval)rainElapsed;
- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues;
#if DEBUG
+ (float)diagnosticEffectiveTrailLength:(float)trailLength
                                  rows:(float)rows
                          speedControl:(float)speedControl;
- (nullable NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (NSArray<NSNumber *> *)diagnosticGlyphStateSnapshotWithWidth:(NSUInteger)width height:(NSUInteger)height;
#endif

@end

NS_ASSUME_NONNULL_END
