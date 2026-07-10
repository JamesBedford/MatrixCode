#import "MatrixCodeRainHostView.h"

#import <float.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>

#import "MatrixCodeConfigurationController.h"
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
@property(nonatomic, strong, nullable) NSStackView *presentationChrome;
@property(nonatomic, strong, nullable) NSTimer *presentationChromeHideTimer;
@property(nonatomic, strong, nullable) NSView *shortcutToast;
@property(nonatomic, strong, nullable) NSTextField *shortcutToastLabel;
@property(nonatomic, strong, nullable) NSTimer *shortcutToastHideTimer;
@property(nonatomic, weak, nullable) NSWindow *observedWindow;
@property(nonatomic) BOOL syncingWindowLayout;
- (void)ensureMetalView;
- (void)syncPresentationLayoutToWindow;
- (void)revealPresentationChromeForPointerActivity;
- (void)applyShortcutToastStyle;
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
    return [visible isKindOfClass:NSNumber.class] && [visible boolValue];
}

static double MatrixCodeRainHostNumber(NSDictionary *dictionary,
                                       NSString *key,
                                       double fallback,
                                       double minimum,
                                       double maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) {
        return fallback;
    }
    return fmin(maximum, fmax(minimum, [value doubleValue]));
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
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.animationTimer invalidate];
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
    [self setFPSOverlayVisible:MatrixCodeRainHostStoredFPSOverlayVisible(storedValues) notify:NO];
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
    self.fpsLastFrameTime = 0;
    self.fpsLastDisplayUpdate = 0;
    self.fpsEma = 0;
    if (self.fpsOverlayVisible) self.fpsOverlay.stringValue = @"0 FPS";
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
    if (!self.shortcutToast || !self.shortcutToastLabel) return;
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
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
    [self observeCurrentWindowGeometry];
    [self syncPresentationLayoutToWindow];
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
        [self.configurationController cancelOperation:self];
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
    NSDictionary *stored = MatrixCodeRainHostJSONObject(values[@"mx-controls"], NSDictionary.class);
    NSMutableDictionary *controls = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    double current = MatrixCodeRainHostNumber(controls, @"density", 2.0, 0.1, 100.0);
    controls[@"density"] = @(fmin(100.0, fmax(0.1, current * factor)));
    values[@"mx-controls"] = MatrixCodeRainHostJSONString(controls);
    [self commitShortcutValues:values];
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
        }];
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
    self.backdropClickTimer =
        [NSTimer scheduledTimerWithTimeInterval:[self backdropClickInterval]
                                         target:self
                                       selector:@selector(settleBackdropClickGesture:)
                                       userInfo:nil
                                        repeats:NO];
}

- (void)mouseDown:(NSEvent *)event {
    [self revealPresentationChromeForPointerActivity];
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
        self.mode == MatrixCodeRainHostModeStandalone) {
        [self showSettingsOverlay];
    } else if (!event.isARepeat && optionOnly && [characters isEqualToString:@"f"]) {
        [self toggleFPSOverlay];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"f"]) {
        [self toggleStandaloneFullscreen:event];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"h"]) {
        [self toggleSettingsOverlay];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"i"]) {
        [self openSettingsEditorKind:@"intro"];
    } else if (!event.isARepeat && shiftOnly && [characters isEqualToString:@"m"]) {
        BOOL enabled = [self toggleMessagesShortcut];
        [self showShortcutToastForLabel:@"Messages" enabled:enabled];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"m"]) {
        [self openSettingsEditorKind:@"messages"];
    } else if (!event.isARepeat && shiftOnly && [characters isEqualToString:@"x"]) {
        BOOL enabled = [self toggleImagesShortcut];
        [self showShortcutToastForLabel:@"Images" enabled:enabled];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"x"]) {
        [self openSettingsEditorKind:@"images"];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"c"]) {
        [self openSettingsEditorKind:@"countdown"];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"n"]) {
        BOOL enabled = [self toggleMessagesShortcut];
        [self showShortcutToastForLabel:@"Messages" enabled:enabled];
    } else if (!event.isARepeat && bareWebShortcut &&
               ([characters isEqualToString:@"-"] || [typedCharacters isEqualToString:@"_"])) {
        [self nudgeDensityByFactor:1.0 / MatrixCodeDensityKeyStep];
    } else if (!event.isARepeat && bareWebShortcut &&
               ([characters isEqualToString:@"="] || [typedCharacters isEqualToString:@"+"])) {
        [self nudgeDensityByFactor:MatrixCodeDensityKeyStep];
    } else if (!event.isARepeat && bareWebShortcut && [characters isEqualToString:@"p"]) {
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
