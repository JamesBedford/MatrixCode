#import "MatrixCodeScreenSaverView.h"

#import <os/log.h>
#import <stdlib.h>

#import "MatrixCodeRainHostView.h"

@interface MatrixCodeScreenSaverView ()
@property(nonatomic, strong) MatrixCodeRainHostView *rainHostView;
@property(nonatomic, strong) NSNotificationCenter *stopNotificationCenter;
@property(nonatomic, copy) NSArray<id> *stopNotificationObservers;
+ (BOOL)resolvedPreviewForRequestedPreview:(BOOL)isPreview
                                     frame:(NSRect)frame
               operatingSystemMajorVersion:(NSInteger)majorVersion;
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
            _stopNotificationCenter = [self screenSaverNotificationCenter];
            __weak typeof(self) weakSelf = self;
            // Sonoma and Sequoia can retain the entire legacyScreenSaver view/window stack
            // without calling stopAnimation. Releasing our renderer alone leaves that opaque
            // black view above the next activation, so retire the faulty extension host after
            // cleanup. didstop is intentionally ignored because distributed delivery may lag
            // behind a subsequent activation and tear down its new renderer.
            id observer = [_stopNotificationCenter
                addObserverForName:@"com.apple.screensaver.willstop"
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *notification) {
                (void)notification;
                MatrixCodeScreenSaverView *screenSaver = weakSelf;
                if (!screenSaver) return;
                [screenSaver stopAnimation];
                [screenSaver terminateLegacyScreenSaverHost];
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
