#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeSession : NSObject

+ (NSDictionary<NSString *, id> *)sessionForScreen:(NSScreen *)screen;
+ (NSDictionary<NSString *, id> *)freshSessionForScreen:(NSScreen *)screen;
+ (NSDictionary<NSString *, id> *)singleDisplaySession;
+ (uint32_t)seedForScreenCount:(NSUInteger)screenCount randomSeed:(uint32_t)randomSeed;
+ (NSDictionary<NSString *, NSNumber *> *)freshIdentityForScreenCount:(NSUInteger)screenCount
                                                            randomSeed:(uint32_t)randomSeed
                                                     epochMilliseconds:(NSTimeInterval)epochMilliseconds;
+ (NSDictionary<NSString *, id> *)descriptorForScreen:(NSScreen *)screen desktopMaxY:(CGFloat)desktopMaxY;
+ (nullable NSString *)centermostScreenIdentifierForDescriptors:(NSArray<NSDictionary<NSString *, id> *> *)descriptors;
+ (NSRect)topLeftRectForFrame:(NSRect)frame desktopMaxY:(CGFloat)desktopMaxY;
// Frames use AppKit coordinates, with the primary display first. Hosts may use
// either AppKit coordinates or legacy screen-saver coordinates measured from its top.
// Returns NSNotFound when neither a full-display match nor native overlap exists.
+ (NSUInteger)screenIndexForPlaybackHostRect:(NSRect)hostRect screenFrames:(NSArray<NSValue *> *)screenFrames;
+ (NSString *)identifierForScreen:(NSScreen *)screen;
+ (CGFloat)localOriginForVirtualOffset:(CGFloat)virtualOffset
                              cellSize:(CGFloat)cellSize
                             firstCell:(nullable NSInteger *)firstCell;
+ (nullable NSString *)uniqueUnclaimedScreenIdentifierForSize:(NSSize)size
                                                   descriptors:(NSArray<NSDictionary<NSString *, id> *> *)descriptors
                                                       claimed:(NSSet<NSString *> *)claimed;

@end

NS_ASSUME_NONNULL_END
