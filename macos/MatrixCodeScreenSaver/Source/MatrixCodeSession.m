#import "MatrixCodeSession.h"

#import <ScreenSaver/ScreenSaver.h>

#import "MatrixCodeConstants.h"

static const NSTimeInterval MatrixCodeSessionReuseSeconds = 15.0;
static const NSTimeInterval MatrixCodeWarmupSeconds = 2.5;

@implementation MatrixCodeSession

+ (NSString *)identifierForScreen:(NSScreen *)screen {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    return number != nil
        ? [NSString stringWithFormat:@"screen-%@", number]
        : [NSString stringWithFormat:@"screen-%p", screen];
}

+ (NSRect)topLeftRectForFrame:(NSRect)frame desktopMaxY:(CGFloat)desktopMaxY {
    return NSMakeRect(frame.origin.x, desktopMaxY - NSMaxY(frame), frame.size.width, frame.size.height);
}

+ (NSDictionary<NSString *, id> *)descriptorForScreen:(NSScreen *)screen desktopMaxY:(CGFloat)desktopMaxY {
    NSRect rect = [self topLeftRectForFrame:screen.frame desktopMaxY:desktopMaxY];
    return @{
        @"id": [self identifierForScreen:screen],
        @"left": @(rect.origin.x),
        @"top": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

+ (NSDictionary<NSString *, id> *)sessionForScreen:(NSScreen *)screen {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    CGFloat desktopMaxY = -CGFLOAT_MAX;
    for (NSScreen *candidate in screens) {
        desktopMaxY = MAX(desktopMaxY, NSMaxY(candidate.frame));
    }

    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:MatrixCodeModuleIdentifier];
    NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.matrixcode.screensaver.session.lock"];
    NSDistributedLock *lock = [[NSDistributedLock alloc] initWithPath:lockPath];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
    BOOL acquiredLock = [lock tryLock];
    while (!acquiredLock && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
        acquiredLock = [lock tryLock];
    }

    NSTimeInterval nowMs = NSDate.date.timeIntervalSince1970 * 1000.0;
    NSDictionary *stored = [defaults dictionaryForKey:MatrixCodeSessionDefaultsKey];
    NSNumber *storedEpoch = [stored[@"epoch"] isKindOfClass:NSNumber.class] ? stored[@"epoch"] : nil;
    BOOL reusable = storedEpoch && fabs(nowMs - storedEpoch.doubleValue) <= MatrixCodeSessionReuseSeconds * 1000.0;
    NSDictionary *identity = stored;
    if (!reusable) {
        identity = @{
            @"seed": @((uint32_t)arc4random()),
            @"epoch": @(nowMs),
        };
        [defaults setObject:identity forKey:MatrixCodeSessionDefaultsKey];
        [defaults synchronize];
    }
    if (acquiredLock) {
        [lock unlock];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *descriptors = [NSMutableArray arrayWithCapacity:screens.count];
    for (NSScreen *candidate in screens) {
        [descriptors addObject:[self descriptorForScreen:candidate desktopMaxY:desktopMaxY]];
    }
    return @{
        @"seed": identity[@"seed"],
        @"epoch": identity[@"epoch"],
        @"warmupSeconds": @(MatrixCodeWarmupSeconds),
        @"screens": descriptors,
        @"currentScreenId": [self identifierForScreen:screen],
    };
}

@end
