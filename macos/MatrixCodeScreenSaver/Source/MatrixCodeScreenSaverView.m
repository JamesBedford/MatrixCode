#import "MatrixCodeScreenSaverView.h"

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
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
@end

@implementation MatrixCodeScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0 / 60.0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _preferences = [[MatrixCodePreferences alloc] init];
        _hostActive = NO;
    }
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ensureMetalView];
}

- (void)ensureMetalView {
    if (self.metalView || !self.window) {
        return;
    }
    // Screen saver hosts may attach several views before window.screen settles.
    // Resolve by the view's actual screen-space rectangle so every window gets
    // its own virtual-grid slice rather than all falling back to the main screen.
    NSRect windowRect = [self convertRect:self.bounds toView:nil];
    NSRect screenRect = [self.window convertRectToScreen:windowRect];
    NSScreen *screen = nil;
    CGFloat largestIntersection = 0;
    for (NSScreen *candidate in NSScreen.screens) {
        NSRect intersection = NSIntersectionRect(screenRect, candidate.frame);
        CGFloat area = intersection.size.width * intersection.size.height;
        if (area > largestIntersection) {
            largestIntersection = area;
            screen = candidate;
        }
    }
    screen = screen ?: self.window.screen ?: NSScreen.mainScreen;
    NSDictionary<NSString *, id> *session = nil;
    if (!self.isPreview && screen) {
        session = [MatrixCodeSession sessionForScreen:screen];
    }

    NSDictionary<NSString *, NSString *> *storedValues = [self.preferences storedValues];
    self.runStartDate = [NSDate date];
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:self.runStartDate];
    NSDictionary *controls = [self.class dictionaryFromJSONString:storedValues[@"mx-controls"]];
    self.rampDuration = [controls[@"rampUpMs"] isKindOfClass:NSNumber.class]
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
    }];
    self.introScheduled = self.introOverlay.hasIntro;
    [self addSubview:self.introOverlay positioned:NSWindowAbove relativeTo:self.metalView];
    [self.metalView setAnimationActive:self.hostActive && !self.reducedMotion];
}

+ (NSDictionary *)dictionaryFromJSONString:(NSString *)raw {
    if (![raw isKindOfClass:NSString.class]) return @{};
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
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
    NSDate *now = self.reducedMotion ? self.runStartDate : [NSDate date];
    [self.introOverlay updateAtDate:now framesPerSecond:60];
    NSTimeInterval rainStart = 0;
    if (self.introScheduled && !self.introOverlay.rainDuringIntro) {
        rainStart = self.introOverlay.totalDuration + self.introOverlay.postIntroDelay;
    }
    NSTimeInterval elapsed = [now timeIntervalSinceDate:self.runStartDate] - rainStart;
    float densityScale = self.reducedMotion || self.rampDuration <= 0
        ? 1
        : fmin(1, fmax(0, elapsed / self.rampDuration));
    [self.metalView setDensityScale:densityScale];
    [self.metalView draw];
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
