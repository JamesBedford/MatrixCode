#import "MatrixCodeScreenSaverView.h"

#import "MatrixCodeRainHostView.h"

@interface MatrixCodeScreenSaverView ()
@property(nonatomic, strong) MatrixCodeRainHostView *rainHostView;
@property(nonatomic, strong) NSNotificationCenter *stopNotificationCenter;
@property(nonatomic, copy) NSArray<id> *stopNotificationObservers;
@end

@implementation MatrixCodeScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0;
        MatrixCodeRainHostMode mode = isPreview
            ? MatrixCodeRainHostModeScreenSaverPreview
            : MatrixCodeRainHostModeScreenSaverPlayback;
        _rainHostView = [[MatrixCodeRainHostView alloc] initWithFrame:self.bounds mode:mode];
        [self addSubview:_rainHostView];
        if (!isPreview) {
            _stopNotificationCenter = [self screenSaverNotificationCenter];
            NSMutableArray<id> *observers = [NSMutableArray array];
            __weak typeof(self) weakSelf = self;
            // legacyScreenSaver can retain views without calling stopAnimation.
            // These undocumented notifications supplement the supported callback.
            for (NSNotificationName name in @[@"com.apple.screensaver.willstop",
                                               @"com.apple.screensaver.didstop"]) {
                id observer = [_stopNotificationCenter
                    addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *notification) {
                    [weakSelf stopAnimation];
                }];
                [observers addObject:observer];
            }
            _stopNotificationObservers = [observers copy];
        }
    }
    return self;
}

- (NSNotificationCenter *)screenSaverNotificationCenter {
    return NSDistributedNotificationCenter.defaultCenter;
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
