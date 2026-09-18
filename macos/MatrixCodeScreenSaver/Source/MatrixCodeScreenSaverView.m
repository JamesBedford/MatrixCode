#import "MatrixCodeScreenSaverView.h"

#import <os/log.h>
#import <stdlib.h>

#import "MatrixCodeRainHostView.h"

@interface MatrixCodeScreenSaverView ()
@property(nonatomic, strong) MatrixCodeRainHostView *rainHostView;
@property(nonatomic, strong) NSNotificationCenter *stopNotificationCenter;
@property(nonatomic, copy) NSArray<id> *stopNotificationObservers;
@property(nonatomic) BOOL retiresLegacyScreenSaverHost;
+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion;
+ (BOOL)retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:(NSInteger)majorVersion;
- (void)terminateLegacyScreenSaverHost;
@end

@implementation MatrixCodeScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    NSInteger majorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    BOOL resolvedPreview = [self.class resolvedPreviewForRequestedPreview:isPreview
                                                                    frame:frame
                                              operatingSystemMajorVersion:majorVersion];
    self = [super initWithFrame:frame isPreview:resolvedPreview];
    if (self) {
        self.animationTimeInterval = 1.0;
        MatrixCodeRainHostMode mode = resolvedPreview
            ? MatrixCodeRainHostModeScreenSaverPreview
            : MatrixCodeRainHostModeScreenSaverPlayback;
        _rainHostView = [[MatrixCodeRainHostView alloc] initWithFrame:self.bounds mode:mode];
        [self addSubview:_rainHostView];
        if (!resolvedPreview) {
            _retiresLegacyScreenSaverHost =
                [self.class retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:majorVersion];
            _stopNotificationCenter = [self screenSaverNotificationCenter];
            __weak typeof(self) weakSelf = self;
            // legacyScreenSaver can retain the entire view/window stack without calling
            // stopAnimation, so run the repeatable cleanup from this notification. On the
            // affected systems the faulty host is also retired afterwards. didstop is
            // intentionally ignored because distributed delivery may lag behind a subsequent
            // activation and tear down its new renderer.
            id observer = [_stopNotificationCenter
                addObserverForName:@"com.apple.screensaver.willstop"
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *notification) {
                (void)notification;
                MatrixCodeScreenSaverView *screenSaver = weakSelf;
                if (!screenSaver) return;
                [screenSaver stopAnimation];
                if (screenSaver.retiresLegacyScreenSaverHost) {
                    [screenSaver terminateLegacyScreenSaverHost];
                }
            }];
            _stopNotificationObservers = observer ? @[observer] : @[];
        }
    }
    return self;
}

+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion {
    if (majorVersion < 26 && isPreview && frame.size.width > 400 && frame.size.height > 300) {
        // Pre-Tahoe legacyScreenSaver incorrectly reports full-screen instances as
        // previews. Its embedded Settings preview is always 296 x 184.
        return NO;
    }
    return isPreview;
}

+ (BOOL)retiresLegacyScreenSaverHostForOperatingSystemMajorVersion:(NSInteger)majorVersion {
    // Sonoma and Sequoia retain an opaque black view above the next activation even after the
    // renderer is released, so their faulty host is retired and macOS launches a clean one.
    // Tahoe relaunches the extension as soon as the host exits and starts a fresh set of saver
    // views for the session that is already ending. Nothing ever stops those views: they render
    // forever and leave every display black on the next activation, so cleanup runs alone there.
    return majorVersion < 26;
}

- (NSNotificationCenter *)screenSaverNotificationCenter {
    return NSDistributedNotificationCenter.defaultCenter;
}

- (void)terminateLegacyScreenSaverHost {
    // Run after the distributed-notification callback returns so cleanup and observer
    // delivery can unwind normally. The system relaunches the extension on demand.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *processName = NSProcessInfo.processInfo.processName;
        if ([processName hasPrefix:@"legacyScreenSaver"]) {
            os_log_info(OS_LOG_DEFAULT,
                        "MatrixCode retiring retained legacyScreenSaver host after willstop");
            exit(EXIT_SUCCESS);
        }
        os_log_error(OS_LOG_DEFAULT,
                     "MatrixCode did not retire unexpected screen saver host: %{public}@",
                     processName);
    });
}

- (void)dealloc {
    for (id observer in _stopNotificationObservers) {
        [_stopNotificationCenter removeObserver:observer];
    }
}

- (void)startAnimation {
    [super startAnimation];
    [self.rainHostView startAnimation];
}

- (void)stopAnimation {
    [self.rainHostView stopAnimation];
    [super stopAnimation];
}

- (void)animateOneFrame {
    [self.rainHostView animateOneFrame];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self.rainHostView mouseDown:event];
}

- (void)keyDown:(NSEvent *)event {
    [self.rainHostView keyDown:event];
}

- (void)cancelOperation:(id)sender {
    [self.rainHostView cancelOperation:sender];
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    return [self.rainHostView configureWindow];
}

@end
