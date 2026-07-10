#import "MatrixCodeSession.h"

#import <float.h>
#import <math.h>
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

+ (CGFloat)localOriginForVirtualOffset:(CGFloat)virtualOffset
                              cellSize:(CGFloat)cellSize
                             firstCell:(NSInteger *)firstCell {
    if (cellSize <= 0) {
        if (firstCell) *firstCell = 0;
        return 0;
    }
    CGFloat cells = virtualOffset / cellSize;
    NSInteger first = (NSInteger)floor(cells);
    if (firstCell) *firstCell = first;
    return (first - cells) * cellSize;
}

+ (NSString *)uniqueUnclaimedScreenIdentifierForSize:(NSSize)size
                                          descriptors:(NSArray<NSDictionary<NSString *,id> *> *)descriptors
                                              claimed:(NSSet<NSString *> *)claimed {
    NSString *match = nil;
    for (NSDictionary<NSString *, id> *descriptor in descriptors) {
        NSString *identifier = [descriptor[@"id"] isKindOfClass:NSString.class]
            ? descriptor[@"id"] : nil;
        NSNumber *width = [descriptor[@"width"] isKindOfClass:NSNumber.class]
            ? descriptor[@"width"] : nil;
        NSNumber *height = [descriptor[@"height"] isKindOfClass:NSNumber.class]
            ? descriptor[@"height"] : nil;
        if (identifier == nil || width == nil || height == nil ||
            [claimed containsObject:identifier]) continue;
        if (fabs(width.doubleValue - size.width) > 1 ||
            fabs(height.doubleValue - size.height) > 1) continue;
        if (match) return nil; // Ambiguous until more known screens are claimed.
        match = identifier;
    }
    return match;
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

+ (nullable NSString *)centermostScreenIdentifierForDescriptors:(NSArray<NSDictionary<NSString *,id> *> *)descriptors {
    CGFloat minX = CGFLOAT_MAX;
    CGFloat minY = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX;
    CGFloat maxY = -CGFLOAT_MAX;
    NSMutableArray<NSDictionary<NSString *, id> *> *valid = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *descriptor in descriptors) {
        NSString *identifier = [descriptor[@"id"] isKindOfClass:NSString.class] ? descriptor[@"id"] : nil;
        NSNumber *left = [descriptor[@"left"] isKindOfClass:NSNumber.class] ? descriptor[@"left"] : nil;
        NSNumber *top = [descriptor[@"top"] isKindOfClass:NSNumber.class] ? descriptor[@"top"] : nil;
        NSNumber *width = [descriptor[@"width"] isKindOfClass:NSNumber.class] ? descriptor[@"width"] : nil;
        NSNumber *height = [descriptor[@"height"] isKindOfClass:NSNumber.class] ? descriptor[@"height"] : nil;
        if (!identifier || !left || !top || !width || !height) continue;
        CGFloat x = left.doubleValue;
        CGFloat y = top.doubleValue;
        CGFloat w = width.doubleValue;
        CGFloat h = height.doubleValue;
        if (!isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) continue;
        [valid addObject:descriptor];
        minX = MIN(minX, x);
        minY = MIN(minY, y);
        maxX = MAX(maxX, x + w);
        maxY = MAX(maxY, y + h);
    }
    if (valid.count == 0) return nil;

    CGFloat centerX = (minX + maxX) / 2.0;
    CGFloat centerY = (minY + maxY) / 2.0;
    NSString *bestIdentifier = nil;
    double bestDistance = DBL_MAX;
    for (NSDictionary<NSString *, id> *descriptor in valid) {
        NSString *identifier = (NSString *)descriptor[@"id"];
        CGFloat x = [descriptor[@"left"] doubleValue];
        CGFloat y = [descriptor[@"top"] doubleValue];
        CGFloat w = [descriptor[@"width"] doubleValue];
        CGFloat h = [descriptor[@"height"] doubleValue];
        double dx = x + w / 2.0 - centerX;
        double dy = y + h / 2.0 - centerY;
        double distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            bestIdentifier = identifier;
            bestDistance = distance;
        }
    }
    return bestIdentifier;
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
    NSString *controlsScreenId = [self centermostScreenIdentifierForDescriptors:descriptors];
    NSMutableDictionary<NSString *, id> *session = [@{
        @"seed": identity[@"seed"],
        @"epoch": identity[@"epoch"],
        @"warmupSeconds": @(MatrixCodeWarmupSeconds),
        @"screens": descriptors,
        @"currentScreenId": [self identifierForScreen:screen],
    } mutableCopy];
    if (controlsScreenId) session[@"controlsScreenId"] = controlsScreenId;
    return session;
}

@end
