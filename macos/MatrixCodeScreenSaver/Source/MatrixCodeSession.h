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
+ (NSString *)identifierForScreen:(NSScreen *)screen;
+ (CGFloat)localOriginForVirtualOffset:(CGFloat)virtualOffset
                              cellSize:(CGFloat)cellSize
                             firstCell:(nullable NSInteger *)firstCell;
+ (nullable NSString *)uniqueUnclaimedScreenIdentifierForSize:(NSSize)size
                                                   descriptors:(NSArray<NSDictionary<NSString *, id> *> *)descriptors
                                                       claimed:(NSSet<NSString *> *)claimed;

@end

NS_ASSUME_NONNULL_END
