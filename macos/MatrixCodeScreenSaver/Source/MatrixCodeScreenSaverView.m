#import "MatrixCodeScreenSaverView.h"

#import <float.h>
#import <os/log.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeSession.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeScreenSaverView ()
@property(nonatomic, strong) MatrixCodeMetalView *metalView;
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, strong) MatrixCodeConfigurationController *configurationController;
@property(nonatomic, strong) MatrixCodeIntroOverlayView *introOverlay;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, strong) NSDate *runStartDate;
@property(nonatomic) NSTimeInterval rampDuration;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic) BOOL introScheduled;
@property(nonatomic) BOOL hostActive;
@property(nonatomic) BOOL screenResolutionRetryScheduled;
@property(nonatomic) NSUInteger screenResolutionRetryCount;
@property(nonatomic, strong, nullable) NSDate *deferredRainStartDate;
@end

@implementation MatrixCodeScreenSaverView

static NSMutableSet<NSString *> *MatrixCodeClaimedScreenIDs;
static NSTimeInterval MatrixCodeLastScreenClaimAt;

+ (void)initialize {
    if (self == MatrixCodeScreenSaverView.class) {
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

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0 / 60.0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _preferences = [[MatrixCodePreferences alloc] init];
        _hostActive = NO;
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
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ensureMetalView];
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

- (void)ensureMetalView {
    if (self.metalView || !self.window) {
        return;
    }
    // The multi-display host sometimes creates the upper screen's view before
    // assigning its NSWindow a frame or a screen. On other launches it reports
    // the left screen for both the left and upper windows. Never accept a
    // duplicate or fall back to main: resolve it by size to the sole unclaimed
    // display after the correctly identified windows have claimed theirs.
    [self.class resetScreenClaimsIfStale];
    NSScreen *screen = nil;
    NSRect screenRect = NSZeroRect;
    // A host window can temporarily report another saver window's `screen`.
    // Its non-empty screen-space frame is the stronger source of truth.
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
    if (screen && !self.isPreview &&
        [MatrixCodeClaimedScreenIDs containsObject:[MatrixCodeSession identifierForScreen:screen]]) {
        NSScreen *unclaimedMatch = [self unclaimedScreenMatchingViewSize];
        if (unclaimedMatch) {
            screen = unclaimedMatch;
        } else {
            // Never cement a duplicate assignment. Other windows may still
            // need to claim same-sized displays before this one is unique.
            [self scheduleScreenResolutionRetry];
            return;
        }
    }
    if (!screen && !self.isPreview) {
        screen = [self unclaimedScreenMatchingViewSize];
    }
    if (!screen) {
        if (self.isPreview) screen = NSScreen.mainScreen;
        else {
            [self scheduleScreenResolutionRetry];
            return;
        }
    }
    [self.class claimScreen:screen];
    NSDictionary<NSString *, id> *session = nil;
    if (!self.isPreview && screen) {
        session = [MatrixCodeSession sessionForScreen:screen];
    }
    os_log_info(OS_LOG_DEFAULT,
                "MatrixCode native view mapped: preview=%{public}d screen=%{public}@ frame=%{public}@",
                self.isPreview,
                screen ? [MatrixCodeSession identifierForScreen:screen] : @"none",
                screen ? NSStringFromRect(screen.frame) : @"none");

    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    self.runStartDate = [NSDate date];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate];
    NSDictionary *controls = [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]];
    BOOL multiMonitorSession = [session[@"screens"] isKindOfClass:NSArray.class] &&
        [session[@"screens"] count] > 1;
    // Match the WebGL multi-monitor path: begin from a deterministic,
    // distributed warm state so lower or horizontally offset displays are
    // populated immediately. Later stream cycles still enter above the shared
    // virtual desktop and travel continuously across display boundaries.
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
    [self addSubview:self.metalView];
    __weak typeof(self) weakSelf = self;
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
    self.introScheduled = self.introOverlay.hasIntro;
    [self addSubview:self.introOverlay positioned:NSWindowAbove relativeTo:self.metalView];
    [self.metalView setAnimationActive:self.hostActive && !self.reducedMotion];
    if (self.hostActive && !self.reducedMotion && !self.introOverlay.playing) {
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
    if (self.isPreview) {
        self.rampDuration = [controls[@"rampUpMs"] isKindOfClass:NSNumber.class]
            ? MIN(60, MAX(0, [controls[@"rampUpMs"] doubleValue] / 1000.0))
            : 8;
    }
    [self.metalView draw];
}

- (void)startAnimation {
    [super startAnimation];
    self.hostActive = YES;
    [self ensureMetalView];
    [self.metalView reloadStoredValues:[self.preferences storedValues]];
    [self.metalView setAnimationActive:!self.reducedMotion];
    self.introScheduled = self.introOverlay.hasIntro;
    if (!self.reducedMotion) [self.introOverlay startAtDate:self.runStartDate];
}

- (void)stopAnimation {
    self.hostActive = NO;
    [self.metalView setAnimationActive:NO];
    [super stopAnimation];
}

- (void)animateOneFrame {
    if (!self.metalView || !self.runStartDate) return;
    NSDate *now = self.reducedMotion ? self.runStartDate : [NSDate date];
    [self.introOverlay updateAtDate:now framesPerSecond:60];
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
    [self.metalView draw];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (self.introOverlay.playing) [self.introOverlay skip];
    else [super mouseDown:event];
}

- (void)keyDown:(NSEvent *)event {
    if (self.introOverlay.playing && event.keyCode == 53) {
        [self.introOverlay skip];
    } else {
        [super keyDown:event];
    }
}

- (void)cancelOperation:(id)sender {
    if (self.introOverlay.playing) [self.introOverlay skip];
    else [super cancelOperation:sender];
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    if (!self.configurationController) {
        __weak typeof(self) weakSelf = self;
        self.configurationController =
            [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{
                weakSelf.configurationController = nil;
            }];
    }
    return self.configurationController.window;
}

@end
