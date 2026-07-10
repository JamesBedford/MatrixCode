#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatrixCodeSession : NSObject

+ (NSDictionary<NSString *, id> *)sessionForScreen:(NSScreen *)screen;
+ (NSDictionary<NSString *, id> *)descriptorForScreen:(NSScreen *)screen desktopMaxY:(CGFloat)desktopMaxY;
+ (NSRect)topLeftRectForFrame:(NSRect)frame desktopMaxY:(CGFloat)desktopMaxY;
+ (NSString *)identifierForScreen:(NSScreen *)screen;

@end

NS_ASSUME_NONNULL_END
