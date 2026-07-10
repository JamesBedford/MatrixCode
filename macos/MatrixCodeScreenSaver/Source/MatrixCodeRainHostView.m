#import "MatrixCodeRainHostView.h"

#import <float.h>
#import <os/log.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeSession.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeRainHostView ()
@property(nonatomic) MatrixCodeRainHostMode mode;
@property(nonatomic, strong) MatrixCodeMetalView *metalView;
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, strong) MatrixCodeConfigurationController *configurationController;
@property(nonatomic, strong) MatrixCodeIntroOverlayView *introOverlay;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, strong) NSDate *runStartDate;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic) NSTimeInterval rampDuration;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic) BOOL introScheduled;
@property(nonatomic) BOOL hostActive;
@property(nonatomic) BOOL screenResolutionRetryScheduled;
@property(nonatomic) NSUInteger screenResolutionRetryCount;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *standaloneSession;
@property(nonatomic) BOOL suppressesIntroOverlay;
@property(nonatomic) NSUInteger backdropClickCount;
@property(nonatomic, strong, nullable) NSTimer *backdropClickTimer;
@property(nonatomic, strong, nullable) NSDate *deferredRainStartDate;
@property(nonatomic) BOOL userPaused;
@property(nonatomic, strong, nullable) NSDate *pauseStartedDate;
@property(nonatomic, strong, nullable) NSTrackingArea *settingsRevealTrackingArea;
@property(nonatomic, strong, nullable) NSTextField *fpsOverlay;
@property(nonatomic) BOOL fpsOverlayVisible;
@property(nonatomic) NSTimeInterval fpsLastFrameTime;
@property(nonatomic) NSTimeInterval fpsLastDisplayUpdate;
@property(nonatomic) double fpsEma;
@end

@implementation MatrixCodeRainHostView

NSString * const MatrixCodeRainHostRequestMultiMonitorNotification =
    @"MatrixCodeRainHostRequestMultiMonitorNotification";
NSString * const MatrixCodeRainHostRequestExitMultiMonitorNotification =
    @"MatrixCodeRainHostRequestExitMultiMonitorNotification";

static NSMutableSet<NSString *> *MatrixCodeClaimedScreenIDs;
static NSTimeInterval MatrixCodeLastScreenClaimAt;

+ (void)initialize {
    if (self == MatrixCodeRainHostView.class) {
        MatrixCodeClaimedScreenIDs = [NSMutableSet set];
    }
}

+ (void)resetScreenClaimsIfStale {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (MatrixCodeLastScreenClaimAt <= 0 || now - MatrixCodeLastScreenClaimAt > 1.0) {
        [MatrixCodeClaimedScreenIDs removeAllObjects];
    }
}

+ (void)claimScreen:(NSScreen *)screen {
    [self resetScreenClaimsIfStale];
    [MatrixCodeClaimedScreenIDs addObject:[MatrixCodeSession identifierForScreen:screen]];
    MatrixCodeLastScreenClaimAt = NSDate.date.timeIntervalSince1970;
}

- (instancetype)initWithFrame:(NSRect)frame mode:(MatrixCodeRainHostMode)mode {
    return [self initWithFrame:frame mode:mode session:nil suppressesIntroOverlay:NO];
}

- (instancetype)initWithFrame:(NSRect)frame
                         mode:(MatrixCodeRainHostMode)mode
                      session:(NSDictionary<NSString *,id> *)session
        suppressesIntroOverlay:(BOOL)suppressesIntroOverlay {
    self = [super initWithFrame:frame];
    if (self) {
        _mode = mode;
        _standaloneSession = [session copy];
        _suppressesIntroOverlay = suppressesIntroOverlay;
        _preferences = [[MatrixCodePreferences alloc] init];
        _hostActive = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(previewValuesDidChange:)
                   name:MatrixCodePreviewValuesDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.animationTimer invalidate];
    [self.backdropClickTimer invalidate];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    [self ensureMetalView];
}

- (void)updateTrackingAreas {
    if (self.settingsRevealTrackingArea) {
        [self removeTrackingArea:self.settingsRevealTrackingArea];
    }
    self.settingsRevealTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited |
                     NSTrackingMouseMoved |
                     NSTrackingActiveInKeyWindow |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.settingsRevealTrackingArea];
    [super updateTrackingAreas];
}

- (BOOL)isScreenSaverPreview {
    return self.mode == MatrixCodeRainHostModeScreenSaverPreview;
}

- (BOOL)isScreenSaverPlayback {
    return self.mode == MatrixCodeRainHostModeScreenSaverPlayback;
}

- (void)scheduleScreenResolutionRetry {
    if (self.screenResolutionRetryScheduled || self.screenResolutionRetryCount >= 40) return;
    self.screenResolutionRetryScheduled = YES;
    self.screenResolutionRetryCount++;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        weakSelf.screenResolutionRetryScheduled = NO;
        [weakSelf ensureMetalView];
    });
}

- (NSScreen *)unclaimedScreenMatchingViewSize {
    [self.class resetScreenClaimsIfStale];
    NSMutableArray<NSDictionary<NSString *, id> *> *descriptors = [NSMutableArray array];
    for (NSScreen *candidate in NSScreen.screens) {
        [descriptors addObject:@{
            @"id": [MatrixCodeSession identifierForScreen:candidate],
            @"width": @(candidate.frame.size.width),
            @"height": @(candidate.frame.size.height),
        }];
    }
    NSString *identifier = [MatrixCodeSession
        uniqueUnclaimedScreenIdentifierForSize:self.bounds.size
                                   descriptors:descriptors
                                       claimed:MatrixCodeClaimedScreenIDs];
    if (!identifier) return nil;
    for (NSScreen *candidate in NSScreen.screens) {
        if ([[MatrixCodeSession identifierForScreen:candidate] isEqualToString:identifier]) {
            return candidate;
        }
    }
    return nil;
}

- (NSScreen *)screenForPlaybackHostWithRect:(NSRect *)resolvedRect {
    [self.class resetScreenClaimsIfStale];
    NSScreen *screen = nil;
    NSRect screenRect = NSZeroRect;
    if (!NSIsEmptyRect(self.window.frame)) {
        NSRect windowRect = [self convertRect:self.bounds toView:nil];
        screenRect = [self.window convertRectToScreen:windowRect];
        CGFloat largestIntersection = 0;
        for (NSScreen *candidate in NSScreen.screens) {
            NSRect intersection = NSIntersectionRect(screenRect, candidate.frame);
            CGFloat area = intersection.size.width * intersection.size.height;
            if (area > largestIntersection) {
                largestIntersection = area;
                screen = candidate;
            }
        }
    }
    if (!screen) screen = self.window.screen;
    if (screen && [MatrixCodeClaimedScreenIDs containsObject:[MatrixCodeSession identifierForScreen:screen]]) {
        NSScreen *unclaimedMatch = [self unclaimedScreenMatchingViewSize];
        if (unclaimedMatch) {
            screen = unclaimedMatch;
        } else {
            [self scheduleScreenResolutionRetry];
            return nil;
        }
    }
    if (!screen) {
        screen = [self unclaimedScreenMatchingViewSize];
    }
    if (!screen) {
        [self scheduleScreenResolutionRetry];
        return nil;
    }
    if (resolvedRect) *resolvedRect = screenRect;
    return screen;
}

- (void)ensureMetalView {
    if (self.metalView || !self.window) {
        return;
    }

    NSScreen *screen = nil;
    NSDictionary<NSString *, id> *session = nil;
    NSRect screenRect = NSZeroRect;
    if ([self isScreenSaverPlayback]) {
        screen = [self screenForPlaybackHostWithRect:&screenRect];
        if (!screen) return;
        [self.class claimScreen:screen];
        session = [MatrixCodeSession sessionForScreen:screen];
    } else if ([self isScreenSaverPreview]) {
        screen = NSScreen.mainScreen;
    } else {
        screen = self.window.screen ?: NSScreen.mainScreen;
        session = self.standaloneSession;
    }

    os_log_info(OS_LOG_DEFAULT,
                "MatrixCode native host mapped: mode=%{public}ld screen=%{public}@ frame=%{public}@",
                (long)self.mode,
                screen ? [MatrixCodeSession identifierForScreen:screen] : @"none",
                screen ? NSStringFromRect(screen.frame) : NSStringFromRect(screenRect));

    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    self.runStartDate = [NSDate date];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate];
    NSDictionary *controls = [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]];
    BOOL multiMonitorSession = [session[@"screens"] isKindOfClass:NSArray.class] &&
        [session[@"screens"] count] > 1;
    self.rampDuration = multiMonitorSession ? 0 :
        [controls[@"rampUpMs"] isKindOfClass:NSNumber.class]
        ? MIN(60, MAX(0, [controls[@"rampUpMs"] doubleValue] / 1000.0))
        : 8;
    self.reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;

    self.metalView = [[MatrixCodeMetalView alloc] initWithFrame:self.bounds
                                                        session:session
                                                   storedValues:storedValues];
    if (!self.metalView) {
        return;
    }
    [self.metalView configureFramePacingForScreen:screen ?: self.window.screen];
    __weak typeof(self) weakSelf = self;
    self.metalView.frameHandler = ^(MatrixCodeMetalView *view,
                                    NSDate *date,
                                    double framesPerSecond) {
        [weakSelf advanceAnimationAtDate:date framesPerSecond:framesPerSecond];
    };
    [self addSubview:self.metalView];
    [self ensureFPSOverlay];
    if (!self.suppressesIntroOverlay) {
        self.introOverlay = [[MatrixCodeIntroOverlayView alloc] initWithFrame:self.bounds
                                                                storedValues:storedValues
                                                               tokenResolver:self.tokenResolver
                                                                  completion:^{
            [weakSelf.preferences setImmediateValue:@"1" forKey:@"mx-intro-seen"];
            if (weakSelf.introScheduled && !weakSelf.introOverlay.rainDuringIntro) {
                weakSelf.deferredRainStartDate =
                    [NSDate dateWithTimeIntervalSinceNow:weakSelf.introOverlay.postIntroDelay];
            }
        }];
        [self addSubview:self.introOverlay positioned:NSWindowAbove relativeTo:self.metalView];
    }
    self.introScheduled = self.introOverlay.hasIntro;
    [self.metalView setAnimationActive:self.hostActive && !self.reducedMotion];
    if (self.hostActive && !self.reducedMotion && self.introOverlay && !self.introOverlay.playing) {
        [self.introOverlay startAtDate:self.runStartDate];
    }
}

+ (NSDictionary *)dictionaryFromJSONString:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return @{};
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (void)previewValuesDidChange:(NSNotification *)notification {
    NSDictionary<NSString *, NSString *> *values =
        [notification.userInfo[MatrixCodePreviewValuesKey] isKindOfClass:NSDictionary.class]
        ? notification.userInfo[MatrixCodePreviewValuesKey] : nil;
    if (!values) return;
    [self.metalView reloadStoredValues:values];
    NSDictionary *controls = [self.class dictionaryFromJSONString:values[@"mx-controls"]];
    if (![self isScreenSaverPlayback]) {
        self.rampDuration = [controls[@"rampUpMs"] isKindOfClass:NSNumber.class]
            ? MIN(60, MAX(0, [controls[@"rampUpMs"] doubleValue] / 1000.0))
            : 8;
    }
    if (self.metalView.isPaused) [self.metalView draw];
}

- (BOOL)animationShouldRun {
    return self.hostActive && !self.reducedMotion && !self.userPaused;
}

- (double)animationFramesPerSecond {
    NSInteger framesPerSecond = self.metalView.preferredFramesPerSecond;
    return framesPerSecond > 0 ? framesPerSecond : 60;
}

- (void)ensureFPSOverlay {
    if (self.fpsOverlay) return;
    NSTextField *overlay = [NSTextField labelWithString:@"0 FPS"];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.identifier = @"fps-overlay";
    overlay.hidden = YES;
    overlay.drawsBackground = YES;
    overlay.backgroundColor = [NSColor colorWithWhite:0 alpha:0.58];
    overlay.textColor = [NSColor colorWithSRGBRed:0 green:1 blue:0.25 alpha:0.92];
    overlay.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    overlay.alignment = NSTextAlignmentLeft;
    overlay.bordered = NO;
    overlay.wantsLayer = YES;
    overlay.layer.cornerRadius = 4;
    overlay.layer.masksToBounds = YES;
    [self addSubview:overlay positioned:NSWindowAbove relativeTo:self.metalView];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [overlay.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [overlay.widthAnchor constraintGreaterThanOrEqualToConstant:62],
        [overlay.heightAnchor constraintGreaterThanOrEqualToConstant:24],
    ]];
    self.fpsOverlay = overlay;
}

- (void)toggleFPSOverlay {
    [self ensureFPSOverlay];
    self.fpsOverlayVisible = !self.fpsOverlayVisible;
    self.fpsOverlay.hidden = !self.fpsOverlayVisible;
    self.fpsLastFrameTime = 0;
    self.fpsLastDisplayUpdate = 0;
    self.fpsEma = 0;
    if (self.fpsOverlayVisible) self.fpsOverlay.stringValue = @"0 FPS";
}

- (void)updateFPSOverlayAtDate:(NSDate *)date {
    if (!self.fpsOverlayVisible) return;
    NSTimeInterval now = date.timeIntervalSince1970;
    if (self.fpsLastFrameTime > 0 && now > self.fpsLastFrameTime) {
        double instant = 1.0 / (now - self.fpsLastFrameTime);
        self.fpsEma = self.fpsEma <= 0 ? instant : self.fpsEma + 0.18 * (instant - self.fpsEma);
    }
    self.fpsLastFrameTime = now;
    if (self.fpsLastDisplayUpdate > 0 && now - self.fpsLastDisplayUpdate < 0.25) return;
    self.fpsLastDisplayUpdate = now;
    self.fpsOverlay.stringValue = [NSString stringWithFormat:@"%.0f FPS", fmax(0, self.fpsEma)];
}

- (void)startInternalAnimationTimerIfNeeded {
    if (!self.usesInternalAnimationTimer || self.animationTimer || ![self animationShouldRun]) return;
    if (self.metalView && !self.metalView.isPaused) return;
    __weak typeof(self) weakSelf = self;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / [self animationFramesPerSecond]
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        [weakSelf animateOneFrame];
    }];
}

- (void)stopInternalAnimationTimer {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

- (void)startAnimation {
    self.hostActive = YES;
    [self ensureMetalView];
    [self.metalView reloadStoredValues:[self.preferences storedValues]];
    [self.metalView setAnimationActive:[self animationShouldRun]];
    self.introScheduled = self.introOverlay.hasIntro;
    if ([self animationShouldRun] && self.introOverlay) {
        [self.introOverlay startAtDate:self.runStartDate];
    } else {
        [self animateOneFrame];
    }
    [self startInternalAnimationTimerIfNeeded];
}

- (void)stopAnimation {
    self.hostActive = NO;
    self.userPaused = NO;
    self.pauseStartedDate = nil;
    [self.metalView setAnimationActive:NO];
    [self stopInternalAnimationTimer];
}

- (void)advanceAnimationAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond {
    if (!self.metalView || !self.runStartDate) return;
    NSDate *now = self.reducedMotion ? self.runStartDate : (date ?: NSDate.date);
    [self updateFPSOverlayAtDate:now];
    [self.introOverlay updateAtDate:now framesPerSecond:framesPerSecond];
    NSTimeInterval elapsed = [now timeIntervalSinceDate:self.runStartDate];
    if (!self.reducedMotion && self.introScheduled && !self.introOverlay.rainDuringIntro) {
        elapsed = self.deferredRainStartDate
            ? [now timeIntervalSinceDate:self.deferredRainStartDate]
            : -DBL_MAX;
    }
    float linearDensityScale = elapsed < 0 ? 0 :
        (self.reducedMotion || self.rampDuration <= 0
            ? 1
            : fmin(1, elapsed / self.rampDuration));
    float densityScale = MatrixCodeRainRampEase(linearDensityScale);
    [self.metalView setDensityScale:densityScale rainElapsed:elapsed];
}

- (void)animateOneFrame {
    if (self.userPaused) return;
    if (!self.metalView || !self.runStartDate) return;
    if (!self.metalView.isPaused) return;
    [self advanceAnimationAtDate:NSDate.date framesPerSecond:[self animationFramesPerSecond]];
    [self.metalView draw];
}

- (void)toggleUserPaused {
    if (!self.hostActive || self.reducedMotion) return;
    if (!self.userPaused) {
        NSDate *pauseDate = NSDate.date;
        [self advanceAnimationAtDate:pauseDate framesPerSecond:[self animationFramesPerSecond]];
        self.pauseStartedDate = pauseDate;
        self.userPaused = YES;
        [self stopInternalAnimationTimer];
        [self.metalView freezeAnimationAtDate:pauseDate];
        return;
    }

    NSDate *resumeDate = [NSDate date];
    NSTimeInterval pausedDuration = [resumeDate timeIntervalSinceDate:self.pauseStartedDate];
    if (isfinite(pausedDuration) && pausedDuration > 0) {
        self.runStartDate = [self.runStartDate dateByAddingTimeInterval:pausedDuration];
        self.deferredRainStartDate = [self.deferredRainStartDate dateByAddingTimeInterval:pausedDuration];
        [self.introOverlay shiftTimelineBy:pausedDuration];
    }
    self.pauseStartedDate = nil;
    self.userPaused = NO;
    [self.metalView setAnimationActive:[self animationShouldRun]];
    [self startInternalAnimationTimerIfNeeded];
    [self animateOneFrame];
}

- (NSWindow *)configureWindow {
    if (!self.configurationController) {
        __weak typeof(self) weakSelf = self;
        self.configurationController =
            [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{
                weakSelf.configurationController = nil;
            }];
    }
    return self.configurationController.window;
}

- (void)showSettingsOverlay {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation]) return;
    [self ensureMetalView];
    if (!self.configurationController) {
        __weak typeof(self) weakSelf = self;
        self.configurationController =
            [[MatrixCodeConfigurationController alloc] initEmbeddedInView:self
                                                              closeHandler:^{
            MatrixCodeRainHostView *strongSelf = weakSelf;
            strongSelf.configurationController = nil;
            [strongSelf.window makeFirstResponder:strongSelf];
        }];
    } else {
        [self.configurationController showSettingsPanel];
    }
    [self.window makeFirstResponder:self];
}

- (void)revealSettingsOverlayForPointerActivity {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation]) return;
    [self showSettingsOverlay];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)isStandaloneMultiMonitorPresentation {
    NSArray *screens = [self.standaloneSession[@"screens"] isKindOfClass:NSArray.class]
        ? self.standaloneSession[@"screens"] : @[];
    return self.mode == MatrixCodeRainHostModeStandalone && screens.count > 1;
}

- (BOOL)isStandaloneFullScreenPresentation {
    return self.mode == MatrixCodeRainHostModeStandalone &&
        self.window &&
        (self.window.styleMask & NSWindowStyleMaskFullScreen);
}

- (BOOL)exitStandalonePresentationIfNeeded {
    if ([self isStandaloneMultiMonitorPresentation]) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:MatrixCodeRainHostRequestExitMultiMonitorNotification
                          object:self];
        return YES;
    }
    if ([self isStandaloneFullScreenPresentation]) {
        [self.window toggleFullScreen:self];
        return YES;
    }
    return NO;
}

- (NSTimeInterval)backdropClickInterval {
    NSTimeInterval interval = NSEvent.doubleClickInterval;
    if (!isfinite(interval) || interval <= 0) interval = 0.35;
    return MIN(0.65, MAX(0.2, interval));
}

- (void)resetBackdropClickGesture {
    [self.backdropClickTimer invalidate];
    self.backdropClickTimer = nil;
    self.backdropClickCount = 0;
}

- (void)settleBackdropClickGesture:(NSTimer *)timer {
    if (self.backdropClickCount == 2 && self.window) {
        [self.window toggleFullScreen:self];
    }
    [self resetBackdropClickGesture];
}

- (void)handleStandaloneBackdropClick {
    if ([self isStandaloneMultiMonitorPresentation]) return;
    self.backdropClickCount++;
    if (self.backdropClickCount >= 3) {
        [self resetBackdropClickGesture];
        [NSNotificationCenter.defaultCenter
            postNotificationName:MatrixCodeRainHostRequestMultiMonitorNotification
                          object:self];
        return;
    }
    [self.backdropClickTimer invalidate];
    self.backdropClickTimer =
        [NSTimer scheduledTimerWithTimeInterval:[self backdropClickInterval]
                                         target:self
                                       selector:@selector(settleBackdropClickGesture:)
                                       userInfo:nil
                                        repeats:NO];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.configurationController && self.mode == MatrixCodeRainHostModeStandalone) {
        [self.configurationController showSettingsPanel];
    } else if (self.introOverlay.playing) {
        [self.introOverlay skip];
    } else if (self.mode == MatrixCodeRainHostModeStandalone) {
        [self handleStandaloneBackdropClick];
    } else {
        [super mouseDown:event];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [self revealSettingsOverlayForPointerActivity];
}

- (void)mouseMoved:(NSEvent *)event {
    [self revealSettingsOverlayForPointerActivity];
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    NSEventModifierFlags deviceIndependentFlags =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL hasCommandControlOrOption = (deviceIndependentFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0;
    BOOL commandOnly = (deviceIndependentFlags & NSEventModifierFlagCommand) != 0 &&
        (deviceIndependentFlags & (NSEventModifierFlagControl | NSEventModifierFlagOption)) == 0;
    if (!event.isARepeat && commandOnly && [characters isEqualToString:@","] &&
        self.mode == MatrixCodeRainHostModeStandalone) {
        [self showSettingsOverlay];
    } else if (!event.isARepeat && !hasCommandControlOrOption && [characters isEqualToString:@"f"]) {
        [self toggleFPSOverlay];
    } else if (!event.isARepeat && !hasCommandControlOrOption && [characters isEqualToString:@"p"]) {
        [self toggleUserPaused];
    } else if (self.configurationController && event.keyCode == 53) {
        [self.configurationController cancelOperation:self];
    } else if (event.keyCode == 53 && [self exitStandalonePresentationIfNeeded]) {
        return;
    } else if (self.introOverlay.playing && event.keyCode == 53) {
        [self.introOverlay skip];
    } else {
        [super keyDown:event];
    }
}

- (void)cancelOperation:(id)sender {
    if (self.configurationController) {
        [self.configurationController cancelOperation:sender];
        return;
    }
    if ([self exitStandalonePresentationIfNeeded]) return;
    if (self.introOverlay.playing) [self.introOverlay skip];
    else [super cancelOperation:sender];
}

@end
