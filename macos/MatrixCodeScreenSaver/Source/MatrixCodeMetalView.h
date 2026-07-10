#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeMetalView : MTKView

- (instancetype)initWithFrame:(NSRect)frame
                      session:(nullable NSDictionary<NSString *, id> *)session
                storedValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)setAnimationActive:(BOOL)active;
- (void)setDensityScale:(float)densityScale;
- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues;
#if DEBUG
- (nullable NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height;
#endif

@end

NS_ASSUME_NONNULL_END
