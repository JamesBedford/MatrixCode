#import "MatrixCodeRainHostView.h"

#import <float.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeConstants.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeSession.h"
#import "MatrixCodeSettingsTheme.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodePresentationButton : NSButton
@property(nonatomic, strong, nullable) NSTrackingArea *hoverTrackingArea;
@property(nonatomic) BOOL hovered;
@end

@implementation MatrixCodePresentationButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.bordered = NO;
        self.focusRingType = NSFocusRingTypeNone;
        self.wantsLayer = YES;
        self.alignment = NSTextAlignmentCenter;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applyChromeStyle)
                   name:MatrixCodeSettingsThemeDidChangeNotification
                 object:nil];
        [self applyChromeStyle];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self applyChromeStyle];
}

- (void)updateTrackingAreas {
    if (self.hoverTrackingArea) {
        [self removeTrackingArea:self.hoverTrackingArea];
    }
    self.hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self applyChromeStyle];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self applyChromeStyle];
}

- (void)applyChromeStyle {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    NSString *title = self.title ?: @"";
    self.attributedTitle = [[NSAttributedString alloc]
        initWithString:title.uppercaseString
            attributes:@{
                NSFontAttributeName: [theme monospacedFontOfSize:12 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: theme.accentColor,
                NSKernAttributeName: @(12.0 * 0.08),
            }];
    self.contentTintColor = theme.accentColor;
    self.layer.cornerRadius = 6.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = (self.hovered ? theme.accentColor : theme.borderColor).CGColor;
    self.layer.backgroundColor = theme.panelColor.CGColor;
    self.layer.shadowColor = theme.accentColor.CGColor;
    self.layer.shadowOpacity = self.hovered ? 0.4 : 0.0;
    self.layer.shadowRadius = self.hovered ? 12.0 : 0.0;
    self.layer.shadowOffset = NSZeroSize;
}

@end

@interface MatrixCodeRainHostView ()
@property(nonatomic) MatrixCodeRainHostMode mode;
@property(nonatomic, strong) MatrixCodeMetalView *metalView;
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, strong) MatrixCodeConfigurationController *configurationController;
@property(nonatomic, strong) MatrixCodeIntroOverlayView *introOverlay;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, strong) NSDate *runStartDate;
@property(nonatomic, strong) NSDate *rainStartDate;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic, strong) NSTimer *rampPreviewTimer;
@property(nonatomic) NSTimeInterval rampDuration;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic) BOOL reducedMotionAbandonedRainChoreography;
@property(nonatomic) BOOL rainTimelineRequiresReducedMotionWarmup;
@property(nonatomic) BOOL synchronizedMultiDisplayTimeline;
@property(nonatomic) BOOL runTimelineStarted;
@property(nonatomic) BOOL visibilitySuspended;
@property(nonatomic) BOOL introScheduled;
@property(nonatomic) BOOL introMarksSeenOnCompletion;
@property(nonatomic, copy, nullable) dispatch_block_t introPreviewCompletion;
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
@property(nonatomic, strong, nullable) NSStackView *presentationChrome;
@property(nonatomic, strong, nullable) NSTimer *presentationChromeHideTimer;
@property(nonatomic, strong, nullable) NSView *shortcutToast;
@property(nonatomic, strong, nullable) NSTextField *shortcutToastLabel;
@property(nonatomic, strong, nullable) NSTimer *shortcutToastHideTimer;
@property(nonatomic, weak, nullable) NSWindow *observedWindow;
@property(nonatomic) BOOL syncingWindowLayout;
@property(nonatomic, strong, nullable) NSTextField *metalFailureNotice;
- (void)ensureMetalView;
- (void)syncPresentationLayoutToWindow;
- (void)revealPresentationChromeForPointerActivity;
- (void)applyShortcutToastStyle;
- (void)prepareRunTimelineForAnimationStartIfNeeded;
- (void)replayIntro;
- (BOOL)playIntroWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                       completion:(nullable dispatch_block_t)completion;
- (void)previewIntroWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                         completion:(dispatch_block_t)completion;
- (void)previewMessageWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)restartRainAfterControlsReset;
- (void)refreshAnimationForEnvironment;
- (void)updateFPSOverlayWithFramesPerSecond:(double)framesPerSecond;
@end

@implementation MatrixCodeRainHostView

NSString * const MatrixCodeRainHostRequestMultiMonitorNotification =
    @"MatrixCodeRainHostRequestMultiMonitorNotification";
NSString * const MatrixCodeRainHostRequestExitMultiMonitorNotification =
    @"MatrixCodeRainHostRequestExitMultiMonitorNotification";
NSString * const MatrixCodeRainHostFPSOverlayVisibilityDidChangeNotification =
    @"MatrixCodeRainHostFPSOverlayVisibilityDidChangeNotification";
NSString * const MatrixCodeRainHostFPSOverlayVisibleKey =
    @"visible";

static const double MatrixCodeDensityKeyStep = 1.2;
static const NSTimeInterval MatrixCodePresentationChromeHideDelay = 2.8;
static NSString * const MatrixCodeFPSOverlayStorageKey = @"mx-ui-state";

static NSMutableSet<NSString *> *MatrixCodeClaimedScreenIDs;
static NSTimeInterval MatrixCodeLastScreenClaimAt;

static id MatrixCodeRainHostJSONObject(NSString *raw, Class expectedClass) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [object isKindOfClass:expectedClass] ? object : nil;
}

static NSString *MatrixCodeRainHostJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

static BOOL MatrixCodeRainHostStoredFPSOverlayVisible(NSDictionary<NSString *, NSString *> *storedValues) {
    NSDictionary *state = MatrixCodeRainHostJSONObject(storedValues[MatrixCodeFPSOverlayStorageKey],
                                                       NSDictionary.class);
    id visible = state[@"fpsOverlayVisible"];
    return [visible isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)visible) == CFBooleanGetTypeID() &&
        [visible boolValue];
}

static BOOL MatrixCodeRainHostBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        ? [value boolValue] : fallback;
}

static NSNumber *MatrixCodeRainHostBoolObject(BOOL value) {
    return (__bridge NSNumber *)(value ? kCFBooleanTrue : kCFBooleanFalse);
}

static NSMutableDictionary *MatrixCodeRainHostDefaultMessagesDocument(void) {
    return [@{
        @"messages": [@[@"WAKE UP", @"THE MATRIX HAS YOU", @"FOLLOW THE WHITE RABBIT", @"{countup}"] mutableCopy],
        @"enabled": @NO,
        @"frequencyMs": @8000,
        @"persistenceMs": @10000,
        @"appearMs": @4000,
        @"disappearMs": @4000,
        @"flickerOut": @YES,
        @"brightnessFade": @NO,
        @"messageLayout": @"row",
        @"messageDirection": @"topToBottom",
        @"verticalPosition": @0.475,
        @"verticalJitter": @0.25,
    } mutableCopy];
}

static NSMutableDictionary *MatrixCodeRainHostDefaultImagesDocument(void) {
    return [@{
        @"images": [NSMutableArray array],
        @"enabled": @NO,
        @"frequencyMs": @14000,
        @"persistenceMs": @12000,
        @"appearMs": @4500,
        @"disappearMs": @4500,
        @"flickerOut": @YES,
        @"brightnessFade": @NO,
        @"imageScale": @0.72,
        @"imagePlacementJitter": @0.35,
    } mutableCopy];
}

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
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applyShortcutToastStyle)
                   name:MatrixCodeSettingsThemeDidChangeNotification
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applicationVisibilityDidChange:)
                   name:NSApplicationDidHideNotification
                 object:NSApp];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applicationVisibilityDidChange:)
                   name:NSApplicationDidUnhideNotification
                 object:NSApp];
        [NSWorkspace.sharedWorkspace.notificationCenter
            addObserver:self
               selector:@selector(accessibilityDisplayOptionsDidChange:)
                   name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self.animationTimer invalidate];
    [self.rampPreviewTimer invalidate];
    [self.backdropClickTimer invalidate];
    [self.presentationChromeHideTimer invalidate];
    [self.shortcutToastHideTimer invalidate];
}

- (NSArray<NSNotificationName> *)windowGeometryNotificationNames {
    return @[
        NSWindowDidResizeNotification,
        NSWindowDidEndLiveResizeNotification,
        NSWindowDidEnterFullScreenNotification,
        NSWindowDidExitFullScreenNotification,
    ];
}

- (NSArray<NSNotificationName> *)windowLifecycleNotificationNames {
    return @[
        NSWindowDidChangeOcclusionStateNotification,
        NSWindowDidMiniaturizeNotification,
        NSWindowDidDeminiaturizeNotification,
    ];
}

- (void)observeCurrentWindowGeometry {
    NSWindow *window = self.window;
    if (self.observedWindow == window) return;
    for (NSNotificationName name in [self windowGeometryNotificationNames]) {
        if (self.observedWindow) {
            [NSNotificationCenter.defaultCenter removeObserver:self
                                                          name:name
                                                        object:self.observedWindow];
        }
        if (window) {
            [NSNotificationCenter.defaultCenter addObserver:self
                                                   selector:@selector(windowGeometryDidChange:)
                                                       name:name
                                                     object:window];
        }
    }
    for (NSNotificationName name in [self windowLifecycleNotificationNames]) {
        if (self.observedWindow) {
            [NSNotificationCenter.defaultCenter removeObserver:self
                                                          name:name
                                                        object:self.observedWindow];
        }
        if (window) {
            [NSNotificationCenter.defaultCenter addObserver:self
                                                   selector:@selector(windowVisibilityDidChange:)
                                                       name:name
                                                     object:window];
        }
    }
    self.observedWindow = window;
}

- (void)syncContentViewFrameToWindowIfNeeded {
    if (!self.window || self.window.contentView != self) return;
    if (self.syncingWindowLayout) return;
    NSSize targetSize = self.window.contentLayoutRect.size;
    NSSize frameContentSize = [self.window contentRectForFrameRect:self.window.frame].size;
    targetSize.width = fmax(targetSize.width, frameContentSize.width);
    targetSize.height = fmax(targetSize.height, frameContentSize.height);
    if (self.window.styleMask & NSWindowStyleMaskFullScreen) {
        NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
        targetSize.width = fmax(targetSize.width, NSWidth(screen.frame));
        targetSize.height = fmax(targetSize.height, NSHeight(screen.frame));
    }
    if (targetSize.width < 1 || targetSize.height < 1) return;
    NSRect targetFrame = NSMakeRect(0, 0, targetSize.width, targetSize.height);
    NSRect currentFrame = self.frame;
    if (fabs(NSMinX(currentFrame) - NSMinX(targetFrame)) <= 0.5 &&
        fabs(NSMinY(currentFrame) - NSMinY(targetFrame)) <= 0.5 &&
        fabs(NSWidth(currentFrame) - NSWidth(targetFrame)) <= 0.5 &&
        fabs(NSHeight(currentFrame) - NSHeight(targetFrame)) <= 0.5) {
        return;
    }
    self.syncingWindowLayout = YES;
    [super setFrame:targetFrame];
    self.syncingWindowLayout = NO;
}

- (void)syncHostedSubviewFrames {
    NSRect bounds = self.bounds;
    self.metalView.frame = bounds;
    self.introOverlay.frame = bounds;
}

- (void)syncPresentationLayoutToWindow {
    [self syncContentViewFrameToWindowIfNeeded];
    [self syncHostedSubviewFrames];
    [self.configurationController refreshEmbeddedPresentationLayout];
}

- (void)windowGeometryDidChange:(NSNotification *)notification {
    (void)notification;
    [self syncPresentationLayoutToWindow];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf syncPresentationLayoutToWindow];
    });
}

- (void)windowVisibilityDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    NSWindow *window = self.window;
    BOOL visible = window && !window.miniaturized &&
        (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    self.visibilitySuspended = !visible || NSApp.hidden;
    [self refreshAnimationForEnvironment];
}

- (void)applicationVisibilityDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if (NSApp.hidden) {
        self.visibilitySuspended = YES;
    } else {
        NSWindow *window = self.window;
        self.visibilitySuspended = window.miniaturized ||
            (window.occlusionState & NSWindowOcclusionStateVisible) == 0;
    }
    [self refreshAnimationForEnvironment];
}

- (void)accessibilityDisplayOptionsDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyReducedMotionPreference:
        NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion];
}

- (void)applyReducedMotionPreference:(BOOL)reducedMotion {
    if (self.reducedMotion == reducedMotion) return;
    if (reducedMotion) {
        BOOL requiresWarmup = self.rainTimelineRequiresReducedMotionWarmup;
        self.reducedMotionAbandonedRainChoreography = YES;
        self.rainTimelineRequiresReducedMotionWarmup = NO;
        self.introScheduled = NO;
        self.deferredRainStartDate = nil;
        self.rampDuration = 0;
        [self.rampPreviewTimer invalidate];
        self.rampPreviewTimer = nil;
        if (requiresWarmup) [self.metalView prepareReducedMotionFrame];
    }
    self.reducedMotion = reducedMotion;
    [self refreshAnimationForEnvironment];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self syncHostedSubviewFrames];
    [self.configurationController refreshEmbeddedPresentationLayout];
}

- (void)layout {
    [super layout];
    [self syncContentViewFrameToWindowIfNeeded];
    [self syncHostedSubviewFrames];
    [self.configurationController refreshEmbeddedPresentationLayout];
}

- (void)layoutSubtreeIfNeeded {
    [super layoutSubtreeIfNeeded];
    [self syncPresentationLayoutToWindow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self observeCurrentWindowGeometry];
    [self syncContentViewFrameToWindowIfNeeded];
    self.window.acceptsMouseMovedEvents = YES;
    [self ensureMetalView];
    [self syncHostedSubviewFrames];
    [self revealPresentationChromeForPointerActivity];
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

- (void)showMetalFailureNotice {
    if (self.metalFailureNotice) return;
    NSTextField *notice = [NSTextField wrappingLabelWithString:
        @"COMPATIBILITY MODE UNAVAILABLE\nMETAL COULD NOT BE INITIALIZED"];
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    notice.identifier = @"metal-failure-notice";
    notice.alignment = NSTextAlignmentCenter;
    notice.maximumNumberOfLines = 2;
    notice.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    notice.textColor = [MatrixCodeSettingsTheme.sharedTheme.dimColor colorWithAlphaComponent:0.9];
    notice.accessibilityLabel = @"Matrix Code could not initialize Metal";
    [self addSubview:notice];
    [NSLayoutConstraint activateConstraints:@[
        [notice.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [notice.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [notice.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24],
        [notice.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-24],
    ]];
    self.metalFailureNotice = notice;
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
        session = [MatrixCodeSession singleDisplaySession];
    } else {
        screen = self.window.screen ?: NSScreen.mainScreen;
        session = self.standaloneSession ?: [MatrixCodeSession singleDisplaySession];
    }

    os_log_info(OS_LOG_DEFAULT,
                "MatrixCode native host mapped: mode=%{public}ld screen=%{public}@ frame=%{public}@",
                (long)self.mode,
                screen ? [MatrixCodeSession identifierForScreen:screen] : @"none",
                screen ? NSStringFromRect(screen.frame) : NSStringFromRect(screenRect));

    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    self.runStartDate = [NSDate date];
    self.rainStartDate = self.runStartDate;
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate];
    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(
        [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]]);
    MatrixCodeSettingsTheme.sharedTheme.presetName =
        [controls[@"preset"] isKindOfClass:NSString.class] ? controls[@"preset"] : @"classic";
    BOOL multiMonitorSession = [session[@"screens"] isKindOfClass:NSArray.class] &&
        [session[@"screens"] count] > 1;
    self.synchronizedMultiDisplayTimeline = multiMonitorSession;
    self.rampDuration = multiMonitorSession ? 0 : [controls[@"rampUpMs"] doubleValue] / 1000.0;
    self.reducedMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.reducedMotionAbandonedRainChoreography = self.reducedMotion;
    if (self.reducedMotion) self.rampDuration = 0;

    self.metalView = [[MatrixCodeMetalView alloc] initWithFrame:self.bounds
                                                        session:session
                                                   storedValues:storedValues];
    if (!self.metalView) {
        [self showMetalFailureNotice];
        return;
    }
    [self.metalFailureNotice removeFromSuperview];
    self.metalFailureNotice = nil;
    [self.metalView configureFramePacingForScreen:screen ?: self.window.screen];
    __weak typeof(self) weakSelf = self;
    self.metalView.frameHandler = ^(MatrixCodeMetalView *view,
                                    NSDate *date,
                                    double framesPerSecond) {
        [weakSelf advanceAnimationAtDate:date framesPerSecond:framesPerSecond];
    };
    [self addSubview:self.metalView];
    [self ensureFPSOverlay];
    [self setFPSOverlayVisible:MatrixCodeRainHostStoredFPSOverlayVisible(storedValues) notify:NO];
    if (!self.suppressesIntroOverlay && !multiMonitorSession) {
        self.introOverlay = [[MatrixCodeIntroOverlayView alloc] initWithFrame:self.bounds
                                                                storedValues:storedValues
                                                               tokenResolver:self.tokenResolver
                                                                  completion:^{
            if (weakSelf.introMarksSeenOnCompletion) {
                weakSelf.introMarksSeenOnCompletion = NO;
                [weakSelf.preferences setImmediateValue:@"1" forKey:@"mx-intro-seen"];
            }
            if (weakSelf.introScheduled && !weakSelf.introOverlay.rainDuringIntro) {
                weakSelf.deferredRainStartDate =
                    [NSDate dateWithTimeIntervalSinceNow:weakSelf.introOverlay.postIntroDelay];
            }
            dispatch_block_t previewCompletion = weakSelf.introPreviewCompletion;
            weakSelf.introPreviewCompletion = nil;
            if (previewCompletion) previewCompletion();
        }];
        self.introMarksSeenOnCompletion = self.introOverlay.hasIntro;
        [self addSubview:self.introOverlay positioned:NSWindowAbove relativeTo:self.metalView];
    }
    self.introScheduled = self.introOverlay.hasIntro &&
        !self.reducedMotionAbandonedRainChoreography;
    self.rainTimelineRequiresReducedMotionWarmup = !multiMonitorSession &&
        !self.reducedMotion &&
        (self.rampDuration > 0 ||
         (self.introScheduled && !self.introOverlay.rainDuringIntro));
    if (self.hostActive) {
        [self prepareRunTimelineForAnimationStartIfNeeded];
        self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                      runStartDate:self.runStartDate];
        [self.introOverlay reloadStoredValues:storedValues tokenResolver:self.tokenResolver];
    }
    if (self.hostActive && self.introScheduled && !self.reducedMotion &&
        self.introOverlay && !self.introOverlay.playing) {
        [self.introOverlay startAtDate:self.runStartDate];
    }
    [self.metalView setAnimationActive:[self animationShouldRun]];
}

+ (NSDictionary *)dictionaryFromJSONString:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return @{};
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (void)beginRainTimelineFromEmptyAtDate:(NSDate *)date {
    self.rainStartDate = date ?: NSDate.date;
    self.deferredRainStartDate = nil;
    self.rainTimelineRequiresReducedMotionWarmup = YES;
    [self.metalView setDensityScale:0 rainElapsed:0];
    [self.metalView draw];
}

- (void)scheduleRampPreviewWithDuration:(NSTimeInterval)duration {
    [self.rampPreviewTimer invalidate];
    self.rampPreviewTimer = nil;
    if (self.mode != MatrixCodeRainHostModeStandalone ||
        [self isStandaloneMultiMonitorPresentation] || duration <= 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.rampPreviewTimer = [NSTimer timerWithTimeInterval:0.2
                                                   repeats:NO
                                                     block:^(NSTimer *timer) {
        MatrixCodeRainHostView *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.rampPreviewTimer != timer) return;
        strongSelf.rampPreviewTimer = nil;
        if (![strongSelf animationShouldRun] || strongSelf.reducedMotion ||
            [strongSelf isStandaloneMultiMonitorPresentation] ||
            fabs(strongSelf.rampDuration - duration) > 0.0001 ||
            !strongSelf.metalView || strongSelf.metalView.isPaused) {
            return;
        }
        [strongSelf beginRainTimelineFromEmptyAtDate:NSDate.date];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.rampPreviewTimer forMode:NSRunLoopCommonModes];
}

- (void)previewValuesDidChange:(NSNotification *)notification {
    NSDictionary<NSString *, NSString *> *values =
        [notification.userInfo[MatrixCodePreviewValuesKey] isKindOfClass:NSDictionary.class]
        ? notification.userInfo[MatrixCodePreviewValuesKey] : nil;
    if (!values) return;
    [self.metalView reloadStoredValues:values];
    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(
        [self.class dictionaryFromJSONString:values[@"mx-controls"]]);
    MatrixCodeSettingsTheme.sharedTheme.presetName =
        [controls[@"preset"] isKindOfClass:NSString.class] ? controls[@"preset"] : @"classic";
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:values
                                                                  runStartDate:self.runStartDate ?: NSDate.date];
    [self.introOverlay reloadStoredValues:values tokenResolver:self.tokenResolver];
    self.metalFailureNotice.textColor =
        [MatrixCodeSettingsTheme.sharedTheme.dimColor colorWithAlphaComponent:0.9];
    if (![self isScreenSaverPlayback]) {
        NSTimeInterval previousRampDuration = self.rampDuration;
        NSTimeInterval nextRampDuration = self.reducedMotion ||
            [self isStandaloneMultiMonitorPresentation]
            ? 0
            : [controls[@"rampUpMs"] doubleValue] / 1000.0;
        self.rampDuration = nextRampDuration;
        if (fabs(previousRampDuration - nextRampDuration) > 0.0001) {
            [self scheduleRampPreviewWithDuration:nextRampDuration];
        }
    }
    if (self.metalView.isPaused) [self.metalView draw];
}

- (BOOL)animationShouldRun {
    return self.hostActive && !self.reducedMotion && !self.userPaused && !self.visibilitySuspended;
}

- (void)refreshAnimationForEnvironment {
    BOOL shouldRun = [self animationShouldRun];
    [self.metalView setAnimationActive:shouldRun];
    if (shouldRun) {
        [self startInternalAnimationTimerIfNeeded];
        return;
    }
    [self stopInternalAnimationTimer];
    if (self.hostActive && self.reducedMotion && !self.visibilitySuspended && self.metalView) {
        [self advanceAnimationAtDate:self.runStartDate ?: NSDate.date
                    framesPerSecond:0];
        [self.metalView draw];
    }
}

- (double)animationFramesPerSecond {
    NSInteger framesPerSecond = self.metalView.preferredFramesPerSecond;
    return framesPerSecond > 0 ? framesPerSecond : 60;
}

- (void)ensureFPSOverlay {
    if (self.fpsOverlay) return;
    NSTextField *overlay = [NSTextField labelWithString:@"0 fps · 100% res · 0×0"];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.identifier = @"fps-overlay";
    overlay.hidden = YES;
    overlay.drawsBackground = YES;
    overlay.backgroundColor = [NSColor colorWithWhite:0 alpha:0.58];
    overlay.textColor = [MatrixCodeSettingsTheme.sharedTheme.accentColor colorWithAlphaComponent:0.92];
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

- (void)persistFPSOverlayVisible:(BOOL)visible {
    NSMutableDictionary *state =
        [MatrixCodeRainHostJSONObject([self.preferences storedValues][MatrixCodeFPSOverlayStorageKey],
                                      NSDictionary.class) mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];
    if (visible) state[@"fpsOverlayVisible"] = @YES;
    else [state removeObjectForKey:@"fpsOverlayVisible"];
    [self.preferences setImmediateValue:state.count ? MatrixCodeRainHostJSONString(state) : nil
                                 forKey:MatrixCodeFPSOverlayStorageKey];
}

- (void)setFPSOverlayVisible:(BOOL)visible notify:(BOOL)notify {
    [self ensureFPSOverlay];
    if (self.fpsOverlayVisible == visible && self.fpsOverlay.hidden == !visible) return;
    self.fpsOverlayVisible = visible;
    self.fpsOverlay.hidden = !self.fpsOverlayVisible;
    if (self.fpsOverlayVisible) [self updateFPSOverlayWithFramesPerSecond:0];
    if (notify) [self persistFPSOverlayVisible:visible];
    if (notify) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:MatrixCodeRainHostFPSOverlayVisibilityDidChangeNotification
                          object:self
                        userInfo:@{MatrixCodeRainHostFPSOverlayVisibleKey: @(visible)}];
    }
}

- (void)setFPSOverlayVisible:(BOOL)visible {
    [self setFPSOverlayVisible:visible notify:NO];
}

- (void)toggleFPSOverlay {
    [self setFPSOverlayVisible:!self.fpsOverlayVisible notify:YES];
}

- (void)ensureShortcutToast {
    if (self.shortcutToast) return;
    NSView *toast = [[NSView alloc] initWithFrame:NSZeroRect];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.identifier = @"shortcut-toast";
    toast.wantsLayer = YES;
    toast.hidden = YES;
    toast.alphaValue = 0;

    NSTextField *label = [NSTextField labelWithString:@""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.identifier = @"shortcut-toast-label";
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    [toast addSubview:label];
    [self addSubview:toast positioned:NSWindowAbove relativeTo:nil];

    [NSLayoutConstraint activateConstraints:@[
        [toast.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [toast.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
        [toast.widthAnchor constraintLessThanOrEqualToConstant:280],
        [toast.heightAnchor constraintGreaterThanOrEqualToConstant:34],
        [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:13],
        [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-13],
        [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:8],
        [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-8],
    ]];
    self.shortcutToast = toast;
    self.shortcutToastLabel = label;
    [self applyShortcutToastStyle];
}

- (void)applyShortcutToastStyle {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    self.fpsOverlay.textColor = [theme.accentColor colorWithAlphaComponent:0.92];
    self.metalFailureNotice.textColor = [theme.dimColor colorWithAlphaComponent:0.9];
    if (!self.shortcutToast || !self.shortcutToastLabel) return;
    self.shortcutToast.layer.cornerRadius = 6.0;
    self.shortcutToast.layer.borderWidth = 1.0;
    self.shortcutToast.layer.borderColor = theme.borderColor.CGColor;
    self.shortcutToast.layer.backgroundColor = theme.panelColor.CGColor;
    self.shortcutToast.layer.shadowColor = theme.accentColor.CGColor;
    self.shortcutToast.layer.shadowOpacity = 0.22;
    self.shortcutToast.layer.shadowRadius = 20.0;
    self.shortcutToast.layer.shadowOffset = NSZeroSize;

    NSString *text = self.shortcutToastLabel.stringValue ?: @"";
    self.shortcutToastLabel.attributedStringValue = [[NSAttributedString alloc]
        initWithString:text.uppercaseString
            attributes:@{
                NSFontAttributeName: [theme monospacedFontOfSize:12 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: theme.accentColor,
                NSKernAttributeName: @(12.0 * 0.08),
            }];
}

- (void)hideShortcutToast:(NSTimer *)timer {
    (void)timer;
    NSView *toast = self.shortcutToast;
    if (!toast || toast.hidden) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        toast.animator.alphaValue = 0;
    } completionHandler:^{
        if (toast.alphaValue <= 0.001) toast.hidden = YES;
    }];
}

- (void)showShortcutToastForLabel:(NSString *)label enabled:(BOOL)enabled {
    [self ensureShortcutToast];
    NSString *state = enabled ? @"enabled" : @"disabled";
    self.shortcutToastLabel.stringValue =
        [NSString stringWithFormat:@"%@ %@", label ?: @"", state];
    [self applyShortcutToastStyle];
    [self.shortcutToastHideTimer invalidate];
    self.shortcutToast.hidden = NO;
    [self addSubview:self.shortcutToast positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        self.shortcutToast.animator.alphaValue = 1;
    } completionHandler:nil];
    __weak typeof(self) weakSelf = self;
    self.shortcutToastHideTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.7
                                        repeats:NO
                                          block:^(NSTimer *timer) {
        [weakSelf hideShortcutToast:timer];
    }];
}

- (void)updateFPSOverlayWithFramesPerSecond:(double)framesPerSecond {
    if (!self.fpsOverlayVisible) return;
    double finiteFramesPerSecond = isfinite(framesPerSecond) ? fmax(0, framesPerSecond) : 0;
    double renderScale = self.metalView.currentRenderScale;
    if (!isfinite(renderScale) || renderScale <= 0) renderScale = 1;
    CGSize renderSize = self.metalView.currentRenderSize;
    double width = isfinite(renderSize.width) ? fmax(0, renderSize.width) : 0;
    double height = isfinite(renderSize.height) ? fmax(0, renderSize.height) : 0;
    NSInteger roundedFramesPerSecond = (NSInteger)floor(finiteFramesPerSecond + 0.5);
    NSInteger roundedRenderPercent = (NSInteger)floor(renderScale * 100 + 0.5);
    NSInteger roundedWidth = (NSInteger)floor(width + 0.5);
    NSInteger roundedHeight = (NSInteger)floor(height + 0.5);
    self.fpsOverlay.stringValue = [NSString stringWithFormat:
        @"%ld fps · %ld%% res · %ld×%ld",
        (long)roundedFramesPerSecond,
        (long)roundedRenderPercent,
        (long)roundedWidth,
        (long)roundedHeight];
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

- (void)prepareRunTimelineForAnimationStartIfNeeded {
    if (self.synchronizedMultiDisplayTimeline || self.runTimelineStarted) return;
    NSDate *startDate = NSDate.date;
    self.runStartDate = startDate;
    self.rainStartDate = startDate;
    self.deferredRainStartDate = nil;
    self.runTimelineStarted = YES;
    [self.metalView setTokenTimelineStartDate:startDate];
}

- (void)startAnimation {
    self.hostActive = YES;
    [self observeCurrentWindowGeometry];
    [self syncPresentationLayoutToWindow];
    [self ensureMetalView];
    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    [self.metalView reloadStoredValues:storedValues];
    if (self.metalView) [self prepareRunTimelineForAnimationStartIfNeeded];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate ?: NSDate.date];
    [self.introOverlay reloadStoredValues:storedValues tokenResolver:self.tokenResolver];
    self.introScheduled = self.introOverlay.hasIntro &&
        !self.reducedMotionAbandonedRainChoreography;
    if (self.introScheduled && !self.introOverlay.rainDuringIntro) {
        self.rainTimelineRequiresReducedMotionWarmup = YES;
    }
    if (self.introScheduled && !self.reducedMotion &&
        self.introOverlay && !self.introOverlay.playing) {
        [self.introOverlay startAtDate:self.runStartDate];
    }
    if (![self animationShouldRun]) {
        [self animateOneFrame];
    }
    [self refreshAnimationForEnvironment];
}

- (void)stopAnimation {
    self.hostActive = NO;
    self.userPaused = NO;
    self.pauseStartedDate = nil;
    [self.metalView setAnimationActive:NO];
    [self stopInternalAnimationTimer];
    [self.rampPreviewTimer invalidate];
    self.rampPreviewTimer = nil;
}

- (void)advanceAnimationAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond {
    if (!self.metalView || !self.runStartDate) return;
    NSDate *now = self.reducedMotion ? (self.rainStartDate ?: self.runStartDate) : (date ?: NSDate.date);
    [self updateFPSOverlayWithFramesPerSecond:framesPerSecond];
    if (!self.reducedMotion) {
        [self.introOverlay updateAtDate:now framesPerSecond:framesPerSecond];
    }
    NSTimeInterval elapsed = [now timeIntervalSinceDate:self.rainStartDate ?: self.runStartDate];
    if (!self.reducedMotion && self.introScheduled && !self.introOverlay.rainDuringIntro) {
        elapsed = self.deferredRainStartDate
            ? [now timeIntervalSinceDate:self.deferredRainStartDate]
            : -DBL_MAX;
    }
    double linearDensityScale = self.reducedMotion ? 1 :
        (elapsed < 0 ? 0 : (self.rampDuration <= 0
            ? 1
            : fmin(1, elapsed / self.rampDuration)));
    double densityScale = MatrixCodeRainRampEase(linearDensityScale);
    [self.metalView setDensityScale:densityScale rainElapsed:elapsed];
}

- (void)animateOneFrame {
    if (self.userPaused) return;
    if (!self.metalView || !self.runStartDate) return;
    if (!self.metalView.isPaused) return;
    [self advanceAnimationAtDate:NSDate.date
                framesPerSecond:self.reducedMotion ? 0 : [self animationFramesPerSecond]];
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
        self.rainStartDate = [self.rainStartDate dateByAddingTimeInterval:pausedDuration];
        self.deferredRainStartDate = [self.deferredRainStartDate dateByAddingTimeInterval:pausedDuration];
        [self.tokenResolver shiftRunStartBy:pausedDuration];
        [self.metalView shiftTokenTimelineBy:pausedDuration];
        [self.introOverlay shiftTimelineBy:pausedDuration];
    }
    self.pauseStartedDate = nil;
    self.userPaused = NO;
    [self.metalView setAnimationActive:[self animationShouldRun]];
    [self startInternalAnimationTimerIfNeeded];
    [self animateOneFrame];
}

- (BOOL)shouldShowPresentationChrome {
    return self.mode == MatrixCodeRainHostModeStandalone &&
        (![self isStandaloneMultiMonitorPresentation] || [self isStandaloneMultiMonitorControlHost]);
}

- (MatrixCodePresentationButton *)presentationButtonWithTitle:(NSString *)title
                                                       action:(SEL)action
                                                   identifier:(NSString *)identifier
                                                      toolTip:(NSString *)toolTip {
    MatrixCodePresentationButton *button =
        [[MatrixCodePresentationButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.title = title;
    button.target = self;
    button.action = action;
    button.identifier = identifier;
    button.toolTip = toolTip;
    [button.heightAnchor constraintEqualToConstant:32].active = YES;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:
        [identifier isEqualToString:@"presentation-multimonitor"] ? 148 : 122].active = YES;
    return button;
}

- (void)ensurePresentationChrome {
    if (![self shouldShowPresentationChrome]) {
        [self.presentationChrome removeFromSuperview];
        self.presentationChrome = nil;
        return;
    }
    if (self.presentationChrome) return;

    BOOL multiMonitorControls = [self isStandaloneMultiMonitorControlHost];
    NSMutableArray<NSView *> *buttons = [NSMutableArray array];
    if (!multiMonitorControls) {
        NSButton *fullscreen = [self presentationButtonWithTitle:@"⛶ Fullscreen"
                                                          action:@selector(toggleStandaloneFullscreen:)
                                                      identifier:@"presentation-fullscreen"
                                                         toolTip:@"Fullscreen (F)"];
        [buttons addObject:fullscreen];
    }
    NSButton *multiMonitor = [self presentationButtonWithTitle:@"▦ Multi-monitor"
                                                        action:@selector(enterStandaloneMultiMonitor:)
                                                  identifier:@"presentation-multimonitor"
                                                       toolTip:multiMonitorControls
                                                            ? @"Exit multi-monitor mode (⇧⌘M)"
                                                            : @"Start multi-monitor mode (⇧⌘M)"];
    if (multiMonitorControls) multiMonitor.title = @"▦ Exit";
    [buttons addObject:multiMonitor];
    NSStackView *chrome = [NSStackView stackViewWithViews:buttons];
    chrome.translatesAutoresizingMaskIntoConstraints = NO;
    chrome.identifier = @"presentation-chrome";
    chrome.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chrome.alignment = NSLayoutAttributeCenterY;
    chrome.spacing = 8;
    chrome.alphaValue = 0;
    chrome.hidden = YES;
    [self addSubview:chrome positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [chrome.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
        [chrome.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
    ]];
    self.presentationChrome = chrome;
}

- (void)raisePresentationChrome {
    if (self.presentationChrome.superview == self) {
        [self addSubview:self.presentationChrome positioned:NSWindowAbove relativeTo:nil];
    }
}

- (void)hidePresentationChrome {
    if (!self.presentationChrome || self.presentationChrome.hidden) return;
    NSStackView *chrome = self.presentationChrome;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.24;
        chrome.animator.alphaValue = 0;
    } completionHandler:^{
        if (chrome.alphaValue <= 0.001) chrome.hidden = YES;
    }];
}

- (void)schedulePresentationChromeHide {
    [self.presentationChromeHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.presentationChromeHideTimer =
        [NSTimer scheduledTimerWithTimeInterval:MatrixCodePresentationChromeHideDelay
                                        repeats:NO
                                          block:^(NSTimer *timer) {
        [weakSelf hidePresentationChrome];
    }];
}

- (void)revealPresentationChromeForPointerActivity {
    if (![self shouldShowPresentationChrome]) return;
    [self ensurePresentationChrome];
    [self raisePresentationChrome];
    self.presentationChrome.hidden = NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.24;
        self.presentationChrome.animator.alphaValue = 1;
    } completionHandler:nil];
    [self schedulePresentationChromeHide];
}

- (void)toggleStandaloneFullscreen:(id)sender {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation]) return;
    if (!self.window) return;
    [self.window toggleFullScreen:sender ?: self];
}

- (BOOL)sendStandalonePresentationRequestToAppDelegate:(SEL)selector object:(id)object {
    id delegate = NSApp.delegate;
    if (!delegate || ![delegate respondsToSelector:selector]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [delegate performSelector:selector withObject:object];
#pragma clang diagnostic pop
    return YES;
}

- (void)requestStandaloneMultiMonitor {
    if ([self sendStandalonePresentationRequestToAppDelegate:NSSelectorFromString(@"enterMultiMonitorFromHost:")
                                                      object:self]) {
        return;
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodeRainHostRequestMultiMonitorNotification
                      object:self];
}

- (void)requestStandaloneMultiMonitorExit {
    if ([self sendStandalonePresentationRequestToAppDelegate:NSSelectorFromString(@"exitMultiMonitor:")
                                                      object:self]) {
        return;
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodeRainHostRequestExitMultiMonitorNotification
                      object:self];
}

- (void)enterStandaloneMultiMonitor:(id)sender {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation]) {
        [self requestStandaloneMultiMonitorExit];
        return;
    }
    [self requestStandaloneMultiMonitor];
}

- (void)toggleSettingsOverlay {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation] && ![self isStandaloneMultiMonitorControlHost]) return;
    if (self.configurationController) {
        [self.configurationController dismissSettingsPanelAnimated];
        [self hidePresentationChrome];
    } else {
        [self showSettingsOverlay];
    }
}

- (void)openSettingsEditorKind:(NSString *)kind {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation] && ![self isStandaloneMultiMonitorControlHost]) return;
    [self showSettingsOverlay];
    [self.configurationController openEditorKind:kind];
    [self syncPresentationLayoutToWindow];
}

- (NSMutableDictionary<NSString *, NSString *> *)storedValuesForShortcutMutation {
    return [[self.preferences storedValues] mutableCopy];
}

- (void)commitShortcutValues:(NSDictionary<NSString *, NSString *> *)values {
    [self.preferences commitValues:values];
    [NSNotificationCenter.defaultCenter
        postNotificationName:MatrixCodePreviewValuesDidChangeNotification
                      object:self
                    userInfo:@{MatrixCodePreviewValuesKey: values}];
}

- (BOOL)toggleMessagesShortcut {
    if (self.configurationController) {
        return [self.configurationController toggleMessagesEnabled];
    }
    NSMutableDictionary<NSString *, NSString *> *values = [self storedValuesForShortcutMutation];
    NSDictionary *stored = MatrixCodeRainHostJSONObject(values[@"mx-messages"], NSDictionary.class);
    NSMutableDictionary *messages = MatrixCodeRainHostDefaultMessagesDocument();
    if (stored) {
        for (NSString *key in stored) {
            if ([key isEqualToString:@"messages"]) continue;
            messages[key] = stored[key];
        }
        if ([stored[@"messages"] isKindOfClass:NSArray.class]) {
            messages[@"messages"] = stored[@"messages"];
        }
    }
    BOOL enabled = MatrixCodeRainHostBool(messages, @"enabled", NO);
    BOOL nextEnabled = !enabled;
    messages[@"enabled"] = MatrixCodeRainHostBoolObject(nextEnabled);
    values[@"mx-messages"] = MatrixCodeRainHostJSONString(messages);
    [self commitShortcutValues:values];
    return nextEnabled;
}

- (BOOL)toggleImagesShortcut {
    if (self.configurationController) {
        return [self.configurationController toggleImagesEnabled];
    }
    NSMutableDictionary<NSString *, NSString *> *values = [self storedValuesForShortcutMutation];
    NSDictionary *stored = MatrixCodeRainHostJSONObject(values[@"mx-images"], NSDictionary.class);
    NSMutableDictionary *images = MatrixCodeRainHostDefaultImagesDocument();
    if (stored) {
        [images addEntriesFromDictionary:stored];
    }
    BOOL enabled = MatrixCodeRainHostBool(images, @"enabled", NO);
    BOOL nextEnabled = !enabled;
    images[@"enabled"] = MatrixCodeRainHostBoolObject(nextEnabled);
    values[@"mx-images"] = MatrixCodeRainHostJSONString(images);
    [self commitShortcutValues:values];
    return nextEnabled;
}

- (void)nudgeDensityByFactor:(double)factor {
    if (!isfinite(factor) || factor <= 0) return;
    if (self.configurationController) {
        [self.configurationController nudgeDensityByFactor:factor];
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *values = [self storedValuesForShortcutMutation];
    NSMutableDictionary *controls = [MatrixCodeSanitizeControlsDocument(
        MatrixCodeRainHostJSONObject(values[@"mx-controls"], NSDictionary.class)) mutableCopy];
    double current = [controls[@"density"] doubleValue];
    controls[@"density"] = @(MatrixCodeNudgedDensity(current, factor));
    values[@"mx-controls"] = MatrixCodeRainHostJSONString(controls);
    [self commitShortcutValues:values];
}

- (BOOL)playIntroWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                       completion:(nullable dispatch_block_t)completion {
    if (self.mode != MatrixCodeRainHostModeStandalone ||
        [self isStandaloneMultiMonitorPresentation] || self.reducedMotion ||
        !self.introOverlay || !self.metalView) {
        if (completion) completion();
        return NO;
    }
    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(
        [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]]);
    NSDate *startDate = NSDate.date;
    [self.metalView reloadStoredValues:storedValues];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate ?: startDate];
    [self.introOverlay reloadStoredValues:storedValues tokenResolver:self.tokenResolver];
    self.introPreviewCompletion = [completion copy];
    self.reducedMotionAbandonedRainChoreography = NO;
    self.introScheduled = YES;
    self.rampDuration = [controls[@"rampUpMs"] doubleValue] / 1000.0;
    self.deferredRainStartDate = nil;
    [self.introOverlay replayAtDate:startDate];

    if (!self.introOverlay.rainDuringIntro || self.rampDuration > 0) {
        [self beginRainTimelineFromEmptyAtDate:startDate];
        return YES;
    }
    self.rainTimelineRequiresReducedMotionWarmup = NO;
    [self advanceAnimationAtDate:startDate framesPerSecond:[self animationFramesPerSecond]];
    [self.metalView draw];
    return YES;
}

- (void)replayIntro {
    [self playIntroWithStoredValues:[self.preferences storedValues] completion:nil];
}

- (void)previewIntroWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                         completion:(dispatch_block_t)completion {
    [self playIntroWithStoredValues:storedValues ?: @{} completion:completion];
}

- (void)previewMessageWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues {
    if (self.mode != MatrixCodeRainHostModeStandalone ||
        [self isStandaloneMultiMonitorPresentation] || self.reducedMotion ||
        !self.metalView) {
        return;
    }
    [self.metalView previewMessageWithStoredValues:storedValues ?: @{} atDate:NSDate.date];
    if (self.metalView.isPaused) [self.metalView draw];
}

- (void)restartRainAfterControlsReset {
    if (self.mode != MatrixCodeRainHostModeStandalone ||
        [self isStandaloneMultiMonitorPresentation] || !self.metalView) {
        return;
    }
    [self.rampPreviewTimer invalidate];
    self.rampPreviewTimer = nil;
    [self.introOverlay cancel];
    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(
        [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]]);
    NSDate *startDate = NSDate.date;
    self.runStartDate = startDate;
    self.rainStartDate = startDate;
    self.deferredRainStartDate = nil;
    self.runTimelineStarted = YES;
    self.userPaused = NO;
    self.pauseStartedDate = nil;
    self.rampDuration = self.reducedMotion ? 0 : [controls[@"rampUpMs"] doubleValue] / 1000.0;
    [self.metalView setTokenTimelineStartDate:startDate];
    [self.metalView reloadStoredValues:storedValues];
    [self.metalView restartDeterministicRainFromEmpty:
        self.rampDuration > 0 && !self.reducedMotion];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:startDate];
    [self.introOverlay reloadStoredValues:storedValues tokenResolver:self.tokenResolver];

    BOOL shouldReplayIntro = !self.reducedMotion && self.introOverlay &&
        ![storedValues[@"mx-intro-seen"] isEqualToString:@"1"];
    self.introMarksSeenOnCompletion = shouldReplayIntro;
    self.reducedMotionAbandonedRainChoreography = self.reducedMotion;
    self.introScheduled = shouldReplayIntro;
    if (shouldReplayIntro) [self.introOverlay replayAtDate:startDate];
    self.rainTimelineRequiresReducedMotionWarmup = !self.reducedMotion &&
        (self.rampDuration > 0 ||
         (self.introScheduled && !self.introOverlay.rainDuringIntro));

    [self advanceAnimationAtDate:startDate framesPerSecond:[self animationFramesPerSecond]];
    [self refreshAnimationForEnvironment];
    if (self.metalView.isPaused) [self.metalView draw];
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
    if ([self isStandaloneMultiMonitorPresentation] && ![self isStandaloneMultiMonitorControlHost]) return;
    [self observeCurrentWindowGeometry];
    [self syncPresentationLayoutToWindow];
    [self revealPresentationChromeForPointerActivity];
    [self ensureMetalView];
    if (!self.configurationController) {
        __weak typeof(self) weakSelf = self;
        self.configurationController =
            [[MatrixCodeConfigurationController alloc] initEmbeddedInView:self
                                                              closeHandler:^{
            MatrixCodeRainHostView *strongSelf = weakSelf;
            strongSelf.configurationController = nil;
            [strongSelf.window makeFirstResponder:strongSelf];
        }
                                                        replayIntroHandler:^{
            [weakSelf replayIntro];
        }
                                                       introPreviewHandler:^(
            NSDictionary<NSString *, NSString *> *storedValues,
            dispatch_block_t completion
        ) {
            [weakSelf previewIntroWithStoredValues:storedValues completion:completion];
        }
                                                     messagePreviewHandler:^(
            NSDictionary<NSString *, NSString *> *storedValues
        ) {
            [weakSelf previewMessageWithStoredValues:storedValues];
        }
                                                         resetRainHandler:^{
            [weakSelf restartRainAfterControlsReset];
        }
                                        restrictedToMultiMonitorControls:
            [self isStandaloneMultiMonitorPresentation]];
    } else {
        [self.configurationController showSettingsPanel];
    }
    [self raisePresentationChrome];
    [self syncPresentationLayoutToWindow];
    [self.window makeFirstResponder:self];
}

- (void)revealSettingsOverlayForPointerActivity {
    if (self.mode != MatrixCodeRainHostModeStandalone) return;
    if ([self isStandaloneMultiMonitorPresentation] && ![self isStandaloneMultiMonitorControlHost]) return;
    [self revealPresentationChromeForPointerActivity];
    [self showSettingsOverlay];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags shortcutFlags =
        event.modifierFlags & (NSEventModifierFlagCommand |
                               NSEventModifierFlagShift |
                               NSEventModifierFlagControl |
                               NSEventModifierFlagOption);
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    BOOL commandShiftM = event.type == NSEventTypeKeyDown &&
        !event.isARepeat &&
        shortcutFlags == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
        [characters isEqualToString:@"m"];

    if (commandShiftM && self.mode == MatrixCodeRainHostModeStandalone) {
        if ([self isStandaloneMultiMonitorPresentation]) {
            [self requestStandaloneMultiMonitorExit];
        } else {
            [self enterStandaloneMultiMonitor:self];
        }
        return YES;
    }

    return [super performKeyEquivalent:event];
}

- (BOOL)isStandaloneMultiMonitorPresentation {
    NSArray *screens = [self.standaloneSession[@"screens"] isKindOfClass:NSArray.class]
        ? self.standaloneSession[@"screens"] : @[];
    return self.mode == MatrixCodeRainHostModeStandalone && screens.count > 1;
}

- (BOOL)isStandaloneMultiMonitorControlHost {
    if (![self isStandaloneMultiMonitorPresentation]) return NO;
    NSString *current = [self.standaloneSession[@"currentScreenId"] isKindOfClass:NSString.class]
        ? self.standaloneSession[@"currentScreenId"] : nil;
    NSString *controls = [self.standaloneSession[@"controlsScreenId"] isKindOfClass:NSString.class]
        ? self.standaloneSession[@"controlsScreenId"] : nil;
    if (!controls) {
        NSArray<NSDictionary<NSString *, id> *> *screens =
            [self.standaloneSession[@"screens"] isKindOfClass:NSArray.class]
                ? self.standaloneSession[@"screens"] : @[];
        controls = [MatrixCodeSession centermostScreenIdentifierForDescriptors:screens];
    }
    return current && controls && [current isEqualToString:controls];
}

- (BOOL)isStandaloneFullScreenPresentation {
    return self.mode == MatrixCodeRainHostModeStandalone &&
        self.window &&
        (self.window.styleMask & NSWindowStyleMaskFullScreen);
}

- (BOOL)exitStandalonePresentationIfNeeded {
    if ([self isStandaloneMultiMonitorPresentation]) {
        [self requestStandaloneMultiMonitorExit];
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
        [self requestStandaloneMultiMonitor];
        return;
    }
    [self.backdropClickTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.backdropClickTimer =
        [NSTimer scheduledTimerWithTimeInterval:[self backdropClickInterval]
                                        repeats:NO
                                          block:^(NSTimer *timer) {
        [weakSelf settleBackdropClickGesture:timer];
    }];
}

- (void)mouseDown:(NSEvent *)event {
    [self revealPresentationChromeForPointerActivity];
    if (self.introPreviewCompletion && self.introOverlay.playing) {
        [self.introOverlay skip];
    } else if (self.configurationController && self.mode == MatrixCodeRainHostModeStandalone) {
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
    NSString *typedCharacters = event.characters.lowercaseString;
    NSEventModifierFlags deviceIndependentFlags =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL hasCommandControlOrOption = (deviceIndependentFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0;
    BOOL commandOnly = (deviceIndependentFlags & NSEventModifierFlagCommand) != 0 &&
        (deviceIndependentFlags & (NSEventModifierFlagControl | NSEventModifierFlagOption)) == 0;
    BOOL optionOnly = (deviceIndependentFlags & NSEventModifierFlagOption) != 0 &&
        (deviceIndependentFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) == 0;
    BOOL shiftOnly = (deviceIndependentFlags & NSEventModifierFlagShift) != 0 &&
        (deviceIndependentFlags & (NSEventModifierFlagCommand |
                                   NSEventModifierFlagControl |
                                   NSEventModifierFlagOption)) == 0;
    BOOL bareWebShortcut = !hasCommandControlOrOption;
    BOOL multiMonitorPresentation = [self isStandaloneMultiMonitorPresentation];
    if (multiMonitorPresentation && ![self isStandaloneMultiMonitorControlHost]) {
        if (event.keyCode == 53 && [self exitStandalonePresentationIfNeeded]) return;
        [super keyDown:event];
        return;
    }
    if (!event.isARepeat && commandOnly && [characters isEqualToString:@","] &&
        self.mode == MatrixCodeRainHostModeStandalone && !multiMonitorPresentation) {
        [self toggleSettingsOverlay];
    } else if (!event.isARepeat && optionOnly && [characters isEqualToString:@"f"]) {
        [self toggleFPSOverlay];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"f"] &&
               !multiMonitorPresentation) {
        [self toggleStandaloneFullscreen:event];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"h"]) {
        [self toggleSettingsOverlay];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"i"] &&
               !multiMonitorPresentation) {
        [self openSettingsEditorKind:@"intro"];
    } else if (!event.isARepeat && shiftOnly && [characters isEqualToString:@"m"] &&
               !multiMonitorPresentation) {
        BOOL enabled = [self toggleMessagesShortcut];
        [self showShortcutToastForLabel:@"Messages" enabled:enabled];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"m"] &&
               !multiMonitorPresentation) {
        [self openSettingsEditorKind:@"messages"];
    } else if (!event.isARepeat && shiftOnly && [characters isEqualToString:@"x"] &&
               !multiMonitorPresentation) {
        BOOL enabled = [self toggleImagesShortcut];
        [self showShortcutToastForLabel:@"Images" enabled:enabled];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"x"] &&
               !multiMonitorPresentation) {
        [self openSettingsEditorKind:@"images"];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"c"] &&
               !multiMonitorPresentation) {
        [self openSettingsEditorKind:@"countdown"];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"n"] &&
               !multiMonitorPresentation) {
        BOOL enabled = [self toggleMessagesShortcut];
        [self showShortcutToastForLabel:@"Messages" enabled:enabled];
    } else if (bareWebShortcut &&
               ([characters isEqualToString:@"-"] || [typedCharacters isEqualToString:@"_"])) {
        [self nudgeDensityByFactor:1.0 / MatrixCodeDensityKeyStep];
    } else if (bareWebShortcut &&
               ([characters isEqualToString:@"="] || [typedCharacters isEqualToString:@"+"])) {
        [self nudgeDensityByFactor:MatrixCodeDensityKeyStep];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"p"] &&
               !multiMonitorPresentation) {
        [self toggleUserPaused];
    } else if (self.introPreviewCompletion && self.introOverlay.playing && event.keyCode == 53) {
        [self.introOverlay skip];
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
