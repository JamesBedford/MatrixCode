#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainHostView.h"
#import "MatrixCodeSettingsTheme.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeRainHostView (Testing)
- (void)advanceAnimationAtDate:(NSDate *)date framesPerSecond:(double)framesPerSecond;
- (void)applyReducedMotionPreference:(BOOL)reducedMotion;
- (void)prepareRunTimelineForAnimationStartIfNeeded;
- (void)previewValuesDidChange:(NSNotification *)notification;
- (void)replayIntro;
- (void)previewIntroWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                         completion:(dispatch_block_t)completion;
- (void)previewMessageWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues;
- (void)restartRainAfterControlsReset;
- (void)refreshAnimationForEnvironment;
- (void)scheduleRampPreviewWithDuration:(NSTimeInterval)duration;
- (void)showMetalFailureNotice;
- (void)toggleUserPaused;
- (void)updateFPSOverlayWithFramesPerSecond:(double)framesPerSecond;
@end

@interface MatrixCodeRampMetalProbe : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL animationActive;
@property(nonatomic) NSInteger preferredFramesPerSecond;
@property(nonatomic) NSUInteger rewindCount;
@property(nonatomic) NSUInteger drawCount;
@property(nonatomic) NSUInteger prepareReducedMotionCount;
@property(nonatomic) double densityScale;
@property(nonatomic) NSTimeInterval rainElapsed;
@property(nonatomic) double currentRenderScale;
@property(nonatomic) CGSize currentRenderSize;
@property(nonatomic, strong, nullable) NSDate *tokenTimelineStartDate;
@property(nonatomic) NSTimeInterval tokenTimelineShift;
@property(nonatomic) NSUInteger deterministicRestartCount;
@property(nonatomic) BOOL deterministicRestartStartsFromEmpty;
@property(nonatomic) NSUInteger previewMessageCount;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *previewMessageValues;
@property(nonatomic, strong, nullable) NSDate *previewMessageDate;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *animationStates;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation MatrixCodeRampMetalProbe

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentRenderScale = 1;
        _currentRenderSize = CGSizeZero;
    }
    return self;
}

- (BOOL)isPaused {
    return self.paused;
}

- (void)setDensityScale:(double)densityScale rainElapsed:(NSTimeInterval)rainElapsed {
    self.densityScale = densityScale;
    self.rainElapsed = rainElapsed;
    self.rewindCount++;
    [self.events addObject:@"density"];
}

- (void)setAnimationActive:(BOOL)animationActive {
    _animationActive = animationActive;
    self.paused = !animationActive;
    if (!self.animationStates) self.animationStates = [NSMutableArray array];
    if (!self.events) self.events = [NSMutableArray array];
    [self.animationStates addObject:@(animationActive)];
    [self.events addObject:animationActive ? @"active:1" : @"active:0"];
}

- (void)prepareReducedMotionFrame {
    self.prepareReducedMotionCount++;
    if (!self.events) self.events = [NSMutableArray array];
    [self.events addObject:@"prepare"];
}

- (void)draw {
    self.drawCount++;
    [self.events addObject:@"draw"];
}

- (void)reloadStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues {
    (void)storedValues;
}

- (void)setTokenTimelineStartDate:(NSDate *)date {
    _tokenTimelineStartDate = date;
}

- (void)shiftTokenTimelineBy:(NSTimeInterval)interval {
    self.tokenTimelineShift += interval;
}

- (void)restartDeterministicRainFromEmpty:(BOOL)startsFromEmpty {
    self.deterministicRestartCount++;
    self.deterministicRestartStartsFromEmpty = startsFromEmpty;
}

- (void)previewMessageWithStoredValues:(NSDictionary<NSString *, NSString *> *)storedValues
                                atDate:(NSDate *)date {
    self.previewMessageCount++;
    self.previewMessageValues = storedValues;
    self.previewMessageDate = date;
}

@end

@interface MatrixCodeEscapeTestWindow : NSWindow
@property(nonatomic) BOOL reportsFullScreen;
@property(nonatomic) BOOL toggledFullScreen;
@end

@implementation MatrixCodeEscapeTestWindow

- (NSWindowStyleMask)styleMask {
    NSWindowStyleMask styleMask = [super styleMask];
    return self.reportsFullScreen ? (styleMask | NSWindowStyleMaskFullScreen) : styleMask;
}

- (void)toggleFullScreen:(id)sender {
    self.toggledFullScreen = YES;
}

@end

@interface MatrixCodeMultiMonitorDelegateProbe : NSObject <NSApplicationDelegate>
@property(nonatomic, weak) MatrixCodeRainHostView *enteredHost;
@property(nonatomic, weak) id exitSender;
@end

@implementation MatrixCodeMultiMonitorDelegateProbe

- (void)enterMultiMonitorFromHost:(MatrixCodeRainHostView *)hostView {
    self.enteredHost = hostView;
}

- (void)exitMultiMonitor:(id)sender {
    self.exitSender = sender;
}

@end

@interface MatrixCodeRainHostViewTests : XCTestCase
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalStoredValues;
@property(nonatomic, weak) id<NSApplicationDelegate> originalAppDelegate;
@end

@implementation MatrixCodeRainHostViewTests

- (void)setUp {
    [super setUp];
    self.preferences = [[MatrixCodePreferences alloc] init];
    self.originalStoredValues = [self.preferences storedValues];
    self.originalAppDelegate = NSApp.delegate;
    [self.preferences commitValues:@{}];
}

- (void)tearDown {
    NSApp.delegate = self.originalAppDelegate;
    self.originalAppDelegate = nil;
    [self.preferences commitValues:self.originalStoredValues ?: @{}];
    self.originalStoredValues = nil;
    self.preferences = nil;
    [super tearDown];
}

static NSEvent *MatrixCodeKeyEventWithFlags(NSWindow *window,
                                            NSString *characters,
                                            unsigned short keyCode,
                                            NSEventModifierFlags modifierFlags,
                                            BOOL repeat) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:modifierFlags
                           timestamp:0
                        windowNumber:window.windowNumber
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:repeat
                             keyCode:keyCode];
}

static NSEvent *MatrixCodeKeyEvent(NSWindow *window,
                                   NSString *characters,
                                   unsigned short keyCode,
                                   BOOL repeat) {
    return MatrixCodeKeyEventWithFlags(window, characters, keyCode, 0, repeat);
}

static NSEvent *MatrixCodeEscapeKeyEvent(NSWindow *window) {
    return MatrixCodeKeyEvent(window, @"\e", 53, NO);
}

static NSEvent *MatrixCodePKeyEvent(BOOL repeat) {
    return MatrixCodeKeyEvent(nil, @"p", 35, repeat);
}

static NSEvent *MatrixCodeFKeyEvent(BOOL repeat) {
    return MatrixCodeKeyEvent(nil, @"f", 3, repeat);
}

static NSEvent *MatrixCodeOptionFKeyEvent(BOOL repeat) {
    return MatrixCodeKeyEventWithFlags(nil, @"f", 3, NSEventModifierFlagOption, repeat);
}

static NSEvent *MatrixCodeCommandShiftMKeyEvent(BOOL repeat) {
    return MatrixCodeKeyEventWithFlags(nil,
                                       @"M",
                                       46,
                                       NSEventModifierFlagCommand | NSEventModifierFlagShift,
                                       repeat);
}

static NSEvent *MatrixCodeCommandCommaKeyEvent(BOOL repeat) {
    return MatrixCodeKeyEventWithFlags(nil, @",", 43, NSEventModifierFlagCommand, repeat);
}

// Spins the main run loop until `condition` is satisfied or `timeout` elapses,
// so tests can await the settings panel's fade-out animation completing.
static void MatrixCodeSpinRunLoopUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSEvent *MatrixCodeShiftXKeyEvent(void) {
    return MatrixCodeKeyEventWithFlags(nil, @"X", 7, NSEventModifierFlagShift, NO);
}

static NSEvent *MatrixCodeShiftMKeyEvent(void) {
    return MatrixCodeKeyEventWithFlags(nil, @"M", 46, NSEventModifierFlagShift, NO);
}

static NSEvent *MatrixCodeLetterKeyEventWithRepeat(NSString *letter, BOOL repeat) {
    NSDictionary<NSString *, NSNumber *> *keyCodes = @{
        @"h": @4,
        @"i": @34,
        @"m": @46,
        @"x": @7,
        @"c": @8,
        @"n": @45,
        @"-": @27,
        @"=": @24,
    };
    return MatrixCodeKeyEvent(nil, letter, [keyCodes[letter] unsignedShortValue], repeat);
}

static NSEvent *MatrixCodeLetterKeyEvent(NSString *letter) {
    return MatrixCodeLetterKeyEventWithRepeat(letter, NO);
}

static NSEvent *MatrixCodeMouseMovedEvent(NSWindow *window) {
    return [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                              location:NSMakePoint(320, 240)
                         modifierFlags:0
                             timestamp:0
                          windowNumber:window.windowNumber
                               context:nil
                           eventNumber:1
                            clickCount:0
                              pressure:0];
}

static NSDictionary *MatrixCodeJSONDictionary(NSString *raw) {
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *MatrixCodeJSONString(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSView *MatrixCodeHostDescendantWithIdentifier(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *subview in view.subviews) {
        NSView *match = MatrixCodeHostDescendantWithIdentifier(subview, identifier);
        if (match) return match;
    }
    return nil;
}

static NSDictionary *MatrixCodeHostStoredMessages(MatrixCodeRainHostView *hostView) {
    MatrixCodePreferences *preferences = [hostView valueForKey:@"preferences"];
    return MatrixCodeJSONDictionary([preferences storedValues][@"mx-messages"]);
}

static NSDictionary *MatrixCodeHostStoredImages(MatrixCodeRainHostView *hostView) {
    MatrixCodePreferences *preferences = [hostView valueForKey:@"preferences"];
    return MatrixCodeJSONDictionary([preferences storedValues][@"mx-images"]);
}

static NSString *MatrixCodeHostShortcutToastText(MatrixCodeRainHostView *hostView) {
    NSTextField *label = (NSTextField *)MatrixCodeHostDescendantWithIdentifier(hostView,
                                                                               @"shortcut-toast-label");
    return label.stringValue;
}

- (void)testEscapeKeyExitsStandaloneFullScreen {
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                                      styleMask:NSWindowStyleMaskTitled
                                                        backing:NSBackingStoreBuffered
                                                          defer:YES];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;
    window.reportsFullScreen = YES;

    [hostView keyDown:MatrixCodeEscapeKeyEvent(window)];

    XCTAssertTrue(window.toggledFullScreen);
}

- (void)testEscapeKeyRequestsMultiMonitorExit {
    NSDictionary *session = @{
        @"screens": @[
            @{@"id": @"screen-1"},
            @{@"id": @"screen-2"},
        ],
    };
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];
    __block BOOL requestedExit = NO;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodeRainHostRequestExitMultiMonitorNotification
                    object:hostView
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        requestedExit = YES;
    }];

    [hostView keyDown:MatrixCodeEscapeKeyEvent(nil)];

    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue(requestedExit);
}

- (void)testStandaloneSettingsAppearAsEmbeddedRainOverlayNotSheet {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView showSettingsOverlay];
    [hostView layoutSubtreeIfNeeded];

    XCTAssertNil(window.attachedSheet);
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
    id controller = [hostView valueForKey:@"configurationController"];
    XCTAssertNotNil(controller);
    XCTAssertNil([controller window]);
}

- (void)testRampPreviewDebouncesRewindsAndInvalidatesOnStop {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:@1.0 forKey:@"rampDuration"];
    [hostView setValue:[NSDate dateWithTimeIntervalSince1970:1] forKey:@"rainStartDate"];

    [hostView scheduleRampPreviewWithDuration:1.0];
    NSTimer *supersededTimer = [hostView valueForKey:@"rampPreviewTimer"];
    XCTAssertTrue(supersededTimer.isValid);

    [hostView setValue:@2.0 forKey:@"rampDuration"];
    [hostView scheduleRampPreviewWithDuration:2.0];
    NSTimer *activeTimer = [hostView valueForKey:@"rampPreviewTimer"];
    XCTAssertFalse(supersededTimer.isValid);
    XCTAssertNotEqual(activeTimer, supersededTimer);

    [activeTimer fire];

    XCTAssertNil([hostView valueForKey:@"rampPreviewTimer"]);
    XCTAssertEqual(probe.rewindCount, 1u);
    XCTAssertEqual(probe.drawCount, 1u);
    XCTAssertEqualWithAccuracy(probe.densityScale, 0, 0.0001);
    XCTAssertEqualWithAccuracy(probe.rainElapsed, 0, 0.0001);
    XCTAssertGreaterThan([[hostView valueForKey:@"rainStartDate"] timeIntervalSince1970], 1);
    XCTAssertTrue([[hostView valueForKey:@"rainTimelineRequiresReducedMotionWarmup"] boolValue]);

    [hostView scheduleRampPreviewWithDuration:2.0];
    NSTimer *teardownTimer = [hostView valueForKey:@"rampPreviewTimer"];
    XCTAssertTrue(teardownTimer.isValid);

    [hostView stopAnimation];

    XCTAssertFalse(teardownTimer.isValid);
    XCTAssertNil([hostView valueForKey:@"rampPreviewTimer"]);
}

- (void)testReducedMotionWarmsFullDensityBeforeDrawingAndAbandonsRainChoreography {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:startDate forKey:@"runStartDate"];
    [hostView setValue:startDate forKey:@"rainStartDate"];
    [hostView setValue:@8.0 forKey:@"rampDuration"];
    [hostView setValue:@YES forKey:@"introScheduled"];
    [hostView setValue:@YES forKey:@"rainTimelineRequiresReducedMotionWarmup"];
    [hostView setValue:[startDate dateByAddingTimeInterval:30]
                forKey:@"deferredRainStartDate"];
    [hostView scheduleRampPreviewWithDuration:8.0];
    NSTimer *rampTimer = [hostView valueForKey:@"rampPreviewTimer"];

    [hostView applyReducedMotionPreference:YES];

    XCTAssertEqual(probe.prepareReducedMotionCount, 1u);
    XCTAssertEqualObjects(probe.events,
                          (@[@"prepare", @"active:0", @"density", @"draw"]));
    XCTAssertEqualWithAccuracy(probe.densityScale, 1, 0.0001);
    XCTAssertEqualWithAccuracy(probe.rainElapsed, 0, 0.0001);
    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 0, 0.0001);
    XCTAssertFalse([[hostView valueForKey:@"introScheduled"] boolValue]);
    XCTAssertTrue([[hostView valueForKey:@"reducedMotionAbandonedRainChoreography"] boolValue]);
    XCTAssertFalse([[hostView valueForKey:@"rainTimelineRequiresReducedMotionWarmup"] boolValue]);
    XCTAssertNil([hostView valueForKey:@"deferredRainStartDate"]);
    XCTAssertFalse(rampTimer.isValid);
    XCTAssertNil([hostView valueForKey:@"rampPreviewTimer"]);

    [hostView applyReducedMotionPreference:NO];

    XCTAssertEqualObjects(probe.animationStates, (@[@NO, @YES]));
    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 0, 0.0001);
    XCTAssertFalse([[hostView valueForKey:@"introScheduled"] boolValue]);
}

- (void)testReducedMotionKeepsAlreadyCanonicalFullDensityRainWithoutRewarming {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:startDate forKey:@"runStartDate"];
    [hostView setValue:startDate forKey:@"rainStartDate"];
    [hostView setValue:@0 forKey:@"rampDuration"];
    [hostView setValue:@NO forKey:@"rainTimelineRequiresReducedMotionWarmup"];

    [hostView applyReducedMotionPreference:YES];

    XCTAssertEqual(probe.prepareReducedMotionCount, 0u);
    XCTAssertEqualObjects(probe.events, (@[@"active:0", @"density", @"draw"]));
    XCTAssertEqualWithAccuracy(probe.densityScale, 1, 0.0001);
}

- (void)testReducedMotionFreezesTheCurrentIntroOverlayFrame {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *values = @{
        @"mx-intro": @"{\"lines\":[{\"text\":\"HELLO\",\"holdMs\":1000,\"pauseMs\":0}],\"charMs\":100,\"startDelayMs\":0,\"fadeOutMs\":0,\"rainDuringIntro\":true}",
    };
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values runStartDate:startDate];
    MatrixCodeIntroOverlayView *overlay =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:values
                                           tokenResolver:resolver
                                              completion:^{}];
    [overlay startAtDate:startDate];
    [overlay updateAtDate:[startDate dateByAddingTimeInterval:0.25] framesPerSecond:60];
    NSString *visibleBeforeReduction = [[overlay valueForKey:@"visibleText"] copy];
    XCTAssertEqualObjects(visibleBeforeReduction, @"HE");

    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:startDate forKey:@"runStartDate"];
    [hostView setValue:startDate forKey:@"rainStartDate"];

    [hostView applyReducedMotionPreference:YES];

    XCTAssertTrue(overlay.playing);
    XCTAssertEqualObjects([overlay valueForKey:@"visibleText"], visibleBeforeReduction);
}

- (void)testLiveIntroReplayRestartsCurrentHostAndAfterModeRainTimeline {
    NSDictionary *values = @{
        @"mx-controls": MatrixCodeJSONString(@{@"rampUpMs": @2000}),
        @"mx-intro": @"{\"lines\":[{\"text\":\"AGAIN\",\"holdMs\":1000,\"pauseMs\":0}],\"charMs\":100,\"startDelayMs\":0,\"fadeOutMs\":0,\"rainDuringIntro\":false,\"postIntroDelayMs\":500}",
        @"mx-intro-seen": @"1",
    };
    [self.preferences commitValues:values];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    NSDate *runStartDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values runStartDate:runStartDate];
    MatrixCodeIntroOverlayView *overlay =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:values
                                           tokenResolver:resolver
                                              completion:^{}];
    XCTAssertFalse(overlay.hasIntro);
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:runStartDate forKey:@"runStartDate"];
    [hostView setValue:runStartDate forKey:@"rainStartDate"];
    [hostView replayIntro];

    XCTAssertTrue(overlay.hasIntro);
    XCTAssertTrue(overlay.playing);
    XCTAssertTrue([[hostView valueForKey:@"introScheduled"] boolValue]);
    XCTAssertTrue([[hostView valueForKey:@"rainTimelineRequiresReducedMotionWarmup"] boolValue]);
    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 2, 0.0001);
    XCTAssertEqualWithAccuracy(probe.densityScale, 0, 0.0001);
    XCTAssertEqualWithAccuracy(probe.rainElapsed, 0, 0.0001);
    XCTAssertEqual(probe.drawCount, 1u);
    XCTAssertFalse([[hostView valueForKey:@"introMarksSeenOnCompletion"] boolValue]);

    [overlay skip];
    [hostView setValue:@YES forKey:@"reducedMotion"];
    [hostView replayIntro];
    XCTAssertFalse(overlay.playing);
    XCTAssertEqual(probe.drawCount, 1u);
}

- (void)testDraftPreviewAndReplayPreservePendingFirstVisitSeenFlag {
    NSDictionary *values = @{
        @"mx-controls": MatrixCodeJSONString(@{@"rampUpMs": @0}),
        @"mx-intro": @"{\"lines\":[{\"text\":\"PREVIEW\",\"holdMs\":1000,\"pauseMs\":0}],\"rainDuringIntro\":true}",
    };
    [self.preferences commitValues:values];
    MatrixCodeRainHostView *hostView = [[MatrixCodeRainHostView alloc]
        initWithFrame:NSZeroRect
                 mode:MatrixCodeRainHostModeStandalone
              session:nil
suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values
                runStartDate:startDate];
    MatrixCodeIntroOverlayView *overlay = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSZeroRect
         storedValues:values
        tokenResolver:resolver
           completion:^{}];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:startDate forKey:@"runStartDate"];
    [hostView setValue:startDate forKey:@"rainStartDate"];
    [hostView setValue:@YES forKey:@"introMarksSeenOnCompletion"];

    [hostView previewIntroWithStoredValues:values completion:^{}];

    XCTAssertTrue([[hostView valueForKey:@"introMarksSeenOnCompletion"] boolValue]);
    XCTAssertTrue(overlay.playing);

    [hostView replayIntro];
    XCTAssertTrue([[hostView valueForKey:@"introMarksSeenOnCompletion"] boolValue]);
}

- (void)testVisibilitySuspensionTransitionsMetalAnimationOffAndBackOn {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    NSDate *runStartDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *rainStartDate = [runStartDate dateByAddingTimeInterval:1];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:runStartDate forKey:@"runStartDate"];
    [hostView setValue:rainStartDate forKey:@"rainStartDate"];

    [hostView refreshAnimationForEnvironment];
    [hostView setValue:@YES forKey:@"visibilitySuspended"];
    [hostView refreshAnimationForEnvironment];
    [hostView setValue:@NO forKey:@"visibilitySuspended"];
    [hostView refreshAnimationForEnvironment];

    XCTAssertEqualObjects(probe.animationStates, (@[@YES, @NO, @YES]));
    XCTAssertEqualObjects([hostView valueForKey:@"runStartDate"], runStartDate);
    XCTAssertEqualObjects([hostView valueForKey:@"rainStartDate"], rainStartDate);
}

- (void)testUserPauseResumeShiftsRainAndTokenTimelinesByPausedDuration {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.paused = YES;
    NSDate *runStartDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDate *rainStartDate = [runStartDate dateByAddingTimeInterval:1];
    NSDate *deferredRainStartDate = [runStartDate dateByAddingTimeInterval:20];
    MatrixCodeTokenResolver *tokenResolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:runStartDate];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:@YES forKey:@"userPaused"];
    [hostView setValue:[NSDate dateWithTimeIntervalSinceNow:-10] forKey:@"pauseStartedDate"];
    [hostView setValue:runStartDate forKey:@"runStartDate"];
    [hostView setValue:rainStartDate forKey:@"rainStartDate"];
    [hostView setValue:deferredRainStartDate forKey:@"deferredRainStartDate"];
    [hostView setValue:tokenResolver forKey:@"tokenResolver"];

    [hostView toggleUserPaused];

    NSTimeInterval runShift = [[hostView valueForKey:@"runStartDate"]
        timeIntervalSinceDate:runStartDate];
    NSTimeInterval rainShift = [[hostView valueForKey:@"rainStartDate"]
        timeIntervalSinceDate:rainStartDate];
    NSTimeInterval deferredShift = [[hostView valueForKey:@"deferredRainStartDate"]
        timeIntervalSinceDate:deferredRainStartDate];
    NSTimeInterval resolverShift = [[tokenResolver valueForKey:@"runStartDate"]
        timeIntervalSinceDate:runStartDate];
    XCTAssertEqualWithAccuracy(runShift, 10, 0.25);
    XCTAssertEqualWithAccuracy(rainShift, runShift, 0.001);
    XCTAssertEqualWithAccuracy(deferredShift, runShift, 0.001);
    XCTAssertEqualWithAccuracy(resolverShift, runShift, 0.001);
    XCTAssertEqualWithAccuracy(probe.tokenTimelineShift, runShift, 0.001);
    XCTAssertFalse([[hostView valueForKey:@"userPaused"] boolValue]);
    XCTAssertEqualObjects(probe.animationStates.lastObject, @YES);
}

- (void)testSingleDisplayRunTimelineStartsAfterSetupAndOnlyOnce {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    NSDate *setupStart = [NSDate dateWithTimeIntervalSince1970:1];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:setupStart forKey:@"runStartDate"];
    [hostView setValue:setupStart forKey:@"rainStartDate"];

    [hostView prepareRunTimelineForAnimationStartIfNeeded];

    NSDate *readyStart = [hostView valueForKey:@"runStartDate"];
    XCTAssertGreaterThan(readyStart.timeIntervalSince1970, setupStart.timeIntervalSince1970);
    XCTAssertEqualObjects([hostView valueForKey:@"rainStartDate"], readyStart);
    XCTAssertTrue([[hostView valueForKey:@"runTimelineStarted"] boolValue]);
    XCTAssertEqualObjects(probe.tokenTimelineStartDate, readyStart);

    [hostView prepareRunTimelineForAnimationStartIfNeeded];
    XCTAssertEqualObjects([hostView valueForKey:@"runStartDate"], readyStart);

    MatrixCodeRainHostView *multiDisplayHost =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    [multiDisplayHost setValue:setupStart forKey:@"runStartDate"];
    [multiDisplayHost setValue:setupStart forKey:@"rainStartDate"];
    [multiDisplayHost setValue:@YES forKey:@"synchronizedMultiDisplayTimeline"];
    [multiDisplayHost prepareRunTimelineForAnimationStartIfNeeded];
    XCTAssertEqualObjects([multiDisplayHost valueForKey:@"runStartDate"], setupStart);
    XCTAssertEqualObjects([multiDisplayHost valueForKey:@"rainStartDate"], setupStart);
}

- (void)testInitialReducedMotionSkipsIntroEvenAfterMotionReturns {
    NSDictionary *values = @{
        @"mx-intro": @"{\"lines\":[{\"text\":\"HI\",\"holdMs\":100,\"pauseMs\":0}],\"charMs\":50,\"startDelayMs\":0,\"fadeOutMs\":0,\"rainDuringIntro\":true}",
    };
    [self.preferences commitValues:values];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values
                runStartDate:NSDate.date];
    MatrixCodeIntroOverlayView *overlay = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSZeroRect
         storedValues:values
        tokenResolver:resolver
           completion:^{}];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"reducedMotion"];
    [hostView setValue:@YES forKey:@"reducedMotionAbandonedRainChoreography"];

    [hostView startAnimation];

    NSDate *startDate = [hostView valueForKey:@"runStartDate"];
    XCTAssertFalse(overlay.playing);
    [hostView advanceAnimationAtDate:[startDate dateByAddingTimeInterval:2]
                    framesPerSecond:60];
    XCTAssertFalse(overlay.playing);

    [hostView applyReducedMotionPreference:NO];
    [hostView advanceAnimationAtDate:[startDate dateByAddingTimeInterval:2]
                    framesPerSecond:60];
    XCTAssertFalse(overlay.playing);
}

- (void)testLiveMessagePreviewForwardsUnsavedDraftToCurrentMetalView {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    [hostView setValue:probe forKey:@"metalView"];
    NSDictionary *values = @{ @"mx-messages": @"{\"messages\":[\"UNSAVED\"]}" };

    [hostView previewMessageWithStoredValues:values];

    XCTAssertEqual(probe.previewMessageCount, 1u);
    XCTAssertEqualObjects(probe.previewMessageValues, values);
    XCTAssertNotNil(probe.previewMessageDate);
}

- (void)testControlsResetRestartsDeterministicRainAndDefaultRampTimeline {
    [self.preferences commitValues:@{
        @"mx-controls": MatrixCodeJSONString(@{}),
        @"mx-intro-seen": @"1",
    }];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];

    [hostView restartRainAfterControlsReset];

    XCTAssertEqual(probe.deterministicRestartCount, 1u);
    XCTAssertTrue(probe.deterministicRestartStartsFromEmpty);
    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 8, 0.0001);
    XCTAssertEqualWithAccuracy(probe.densityScale, 0, 0.0001);
    XCTAssertEqualObjects(probe.tokenTimelineStartDate, [hostView valueForKey:@"runStartDate"]);
    XCTAssertFalse([[hostView valueForKey:@"introScheduled"] boolValue]);
}

- (void)testControlsResetCancelsManualReplayForSeenViewer {
    NSDictionary *values = @{
        @"mx-controls": MatrixCodeJSONString(@{}),
        @"mx-intro-seen": @"1",
    };
    [self.preferences commitValues:values];
    MatrixCodeRainHostView *hostView = [[MatrixCodeRainHostView alloc]
        initWithFrame:NSZeroRect
                 mode:MatrixCodeRainHostModeStandalone
              session:nil
suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values
                runStartDate:NSDate.date];
    __block BOOL completed = NO;
    MatrixCodeIntroOverlayView *overlay = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSZeroRect
         storedValues:values
        tokenResolver:resolver
           completion:^{ completed = YES; }];
    [overlay replayAtDate:NSDate.date];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"hostActive"];

    [hostView restartRainAfterControlsReset];

    XCTAssertFalse(completed);
    XCTAssertFalse(overlay.playing);
    XCTAssertFalse([[hostView valueForKey:@"introScheduled"] boolValue]);
}

- (void)testControlsResetUnderReducedMotionKeepsCanonicalRainAndSkipsUnseenIntro {
    NSDictionary *values = @{
        @"mx-controls": MatrixCodeJSONString(@{}),
        @"mx-intro": @"{\"lines\":[{\"text\":\"DO NOT PLAY\",\"holdMs\":1000,\"pauseMs\":0}]}",
    };
    [self.preferences commitValues:values];
    MatrixCodeRainHostView *hostView = [[MatrixCodeRainHostView alloc]
        initWithFrame:NSZeroRect
                 mode:MatrixCodeRainHostModeStandalone
              session:nil
suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.preferredFramesPerSecond = 60;
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values
                runStartDate:NSDate.date];
    MatrixCodeIntroOverlayView *overlay = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSZeroRect
         storedValues:values
        tokenResolver:resolver
           completion:^{}];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"introOverlay"];
    [hostView setValue:@YES forKey:@"hostActive"];
    [hostView setValue:@YES forKey:@"reducedMotion"];

    [hostView restartRainAfterControlsReset];

    XCTAssertEqual(probe.deterministicRestartCount, 1u);
    XCTAssertFalse(probe.deterministicRestartStartsFromEmpty);
    XCTAssertFalse(overlay.playing);
    XCTAssertFalse([[hostView valueForKey:@"introScheduled"] boolValue]);
    XCTAssertEqualWithAccuracy(probe.densityScale, 1, 0.0001);
}

- (void)testHostSanitizesMalformedRampAndPresetBeforeLiveUse {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    NSDictionary *booleanValues = @{
        @"mx-controls": MatrixCodeJSONString(@{
            @"rampUpMs": @YES,
            @"preset": @"invalid",
        }),
    };
    NSNotification *booleanNotification = [NSNotification
        notificationWithName:MatrixCodePreviewValuesDidChangeNotification
                      object:nil
                    userInfo:@{MatrixCodePreviewValuesKey: booleanValues}];

    [hostView previewValuesDidChange:booleanNotification];

    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 8, 0.0001);
    XCTAssertEqualObjects(MatrixCodeSettingsTheme.sharedTheme.presetName, @"classic");

    NSDictionary *outOfRangeValues = @{
        @"mx-controls": MatrixCodeJSONString(@{@"rampUpMs": @999999}),
    };
    NSNotification *outOfRangeNotification = [NSNotification
        notificationWithName:MatrixCodePreviewValuesDidChangeNotification
                      object:nil
                    userInfo:@{MatrixCodePreviewValuesKey: outOfRangeValues}];
    [hostView previewValuesDidChange:outOfRangeNotification];

    XCTAssertEqualWithAccuracy([[hostView valueForKey:@"rampDuration"] doubleValue], 60, 0.0001);
    [hostView stopAnimation];
}

- (void)testEscapeKeyDismissesStandaloneSettingsOverlay {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView showSettingsOverlay];
    [hostView layoutSubtreeIfNeeded];

    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));

    [hostView keyDown:MatrixCodeEscapeKeyEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
    XCTAssertNil([hostView valueForKey:@"configurationController"]);
}

- (void)testHKeyTogglesStandaloneSettingsOverlay {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"h")];
    [hostView layoutSubtreeIfNeeded];
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"h")];
    [hostView layoutSubtreeIfNeeded];
    // Dismissal fades the panel out before tearing the overlay down.
    MatrixCodeSpinRunLoopUntil(^BOOL{
        return [hostView valueForKey:@"configurationController"] == nil;
    }, 2.0);
    [hostView layoutSubtreeIfNeeded];
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
}

- (void)testCommandCommaTogglesStandaloneSettingsOverlayWithFade {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    // First Command+, summons the settings overlay.
    [hostView keyDown:MatrixCodeCommandCommaKeyEvent(NO)];
    [hostView layoutSubtreeIfNeeded];
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
    id controller = [hostView valueForKey:@"configurationController"];
    XCTAssertNotNil(controller);

    // Second Command+, dismisses it. The panel is hidden immediately but the
    // overlay lingers through the fade animation rather than vanishing at once.
    [hostView keyDown:MatrixCodeCommandCommaKeyEvent(NO)];
    XCTAssertEqualObjects([controller valueForKey:@"settingsPanelVisible"], @NO);
    XCTAssertEqualObjects([controller valueForKey:@"settingsPanelDismissing"], @YES);

    MatrixCodeSpinRunLoopUntil(^BOOL{
        return [hostView valueForKey:@"configurationController"] == nil;
    }, 2.0);
    [hostView layoutSubtreeIfNeeded];
    XCTAssertNil([hostView valueForKey:@"configurationController"]);
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));

    // A third Command+, brings the overlay back, confirming a true toggle.
    [hostView keyDown:MatrixCodeCommandCommaKeyEvent(NO)];
    [hostView layoutSubtreeIfNeeded];
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
}

- (void)testWebEditorShortcutKeysOpenMatchingNativeEditors {
    NSArray<NSArray<NSString *> *> *shortcuts = @[
        @[@"i", @"intro"],
        @[@"m", @"messages"],
        @[@"x", @"images"],
        @[@"c", @"countdowns"],
    ];
    for (NSArray<NSString *> *shortcut in shortcuts) {
        NSWindow *window =
            [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                        styleMask:NSWindowStyleMaskTitled
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
        MatrixCodeRainHostView *hostView =
            [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                     mode:MatrixCodeRainHostModeStandalone
                                                  session:nil
                                    suppressesIntroOverlay:YES];
        hostView.usesInternalAnimationTimer = NO;
        window.contentView = hostView;

        [hostView keyDown:MatrixCodeLetterKeyEvent(shortcut[0])];
        [hostView layoutSubtreeIfNeeded];

        NSString *identifier = [@"settings-editor-card-" stringByAppendingString:shortcut[1]];
        XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, identifier),
                        @"Expected %@ to open %@", shortcut[0], identifier);
    }
}

- (void)testImagesEditorRefreshesStaleFullscreenHostLayout {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1920, 1080)
                                    styleMask:NSWindowStyleMaskTitled |
                                              NSWindowStyleMaskResizable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView setFrame:NSMakeRect(0, 240, 1920, 640)];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"x")];
    [hostView layoutSubtreeIfNeeded];

    CGFloat expectedHeight = window.contentLayoutRect.size.height;
    CGFloat expectedWidth = window.contentLayoutRect.size.width;
    XCTAssertEqualWithAccuracy(hostView.frame.origin.x, 0, 0.5);
    XCTAssertEqualWithAccuracy(hostView.frame.origin.y, 0, 0.5);
    XCTAssertEqualWithAccuracy(hostView.bounds.size.width, expectedWidth, 0.5);
    XCTAssertEqualWithAccuracy(hostView.bounds.size.height, expectedHeight, 0.5);

    NSView *backdrop = MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-editor-backdrop");
    NSView *panel = MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel");
    MatrixCodeMetalView *metalView = [hostView valueForKey:@"metalView"];
    XCTAssertNotNil(backdrop);
    XCTAssertNotNil(panel);
    XCTAssertNotNil(metalView);
    XCTAssertEqualWithAccuracy(metalView.frame.origin.x, 0, 0.5);
    XCTAssertEqualWithAccuracy(metalView.frame.origin.y, 0, 0.5);
    XCTAssertEqualWithAccuracy(backdrop.frame.size.height, expectedHeight, 0.5);
    XCTAssertEqualWithAccuracy(panel.frame.size.height, expectedHeight - 32, 0.5);
    XCTAssertEqualWithAccuracy(metalView.frame.size.height, expectedHeight, 0.5);
}

- (void)testFullscreenLayoutSyncUsesScreenBoundsWhenWindowContentSizeIsStale {
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskResizable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    window.reportsFullScreen = YES;
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView setFrame:NSMakeRect(0, 260, 800, 320)];
    [hostView layoutSubtreeIfNeeded];

    NSSize frameContentSize = [window contentRectForFrameRect:window.frame].size;
    NSSize screenSize = (window.screen ?: NSScreen.mainScreen).frame.size;
    CGFloat expectedWidth = fmax(fmax(window.contentLayoutRect.size.width, frameContentSize.width),
                                 screenSize.width);
    CGFloat expectedHeight = fmax(fmax(window.contentLayoutRect.size.height, frameContentSize.height),
                                  screenSize.height);
    XCTAssertEqualWithAccuracy(hostView.frame.origin.x, 0, 0.5);
    XCTAssertEqualWithAccuracy(hostView.frame.origin.y, 0, 0.5);
    XCTAssertEqualWithAccuracy(hostView.frame.size.width, expectedWidth, 0.5);
    XCTAssertEqualWithAccuracy(hostView.frame.size.height, expectedHeight, 0.5);
}

- (void)testStandaloneSettingsAppearWhenPointerMovesOverRainWindow {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;
    [hostView viewDidMoveToWindow];

    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));

    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    XCTAssertTrue(window.acceptsMouseMovedEvents);
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
}

- (void)testStandaloneSettingsControlsReceiveHitTesting {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;

    [hostView showSettingsOverlay];
    [hostView layoutSubtreeIfNeeded];

    NSView *name = MatrixCodeHostDescendantWithIdentifier(hostView, @"mx-user-name");
    XCTAssertNotNil(name);
    NSRect nameFrame = [name convertRect:name.bounds toView:hostView];
    NSView *hit = [hostView hitTest:NSMakePoint(NSMidX(nameFrame), NSMidY(nameFrame))];
    XCTAssertNotNil(hit);
    XCTAssertTrue(hit == name || [hit isDescendantOf:name],
                  @"Expected the viewer-name field to receive clicks, got %@", hit);
}

- (void)testNKeyTogglesMessagesWithoutOpeningSettingsOverlay {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"n")];

    NSDictionary *messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertTrue([messages[@"enabled"] boolValue]);
    XCTAssertEqual([messages[@"messages"] count], 4);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"MESSAGES ENABLED");
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"n")];
    messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertFalse([messages[@"enabled"] boolValue]);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"MESSAGES DISABLED");
}

- (void)testNKeyTreatsNumericEnabledAsInvalidLikeWebSanitizer {
    [self.preferences commitValues:@{
        @"mx-messages": MatrixCodeJSONString(@{
            @"enabled": @1,
            @"messages": @[@"NEO"],
        }),
    }];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"n")];

    NSDictionary *messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertEqualObjects(messages[@"enabled"], @YES);
    XCTAssertEqualObjects(messages[@"messages"], @[@"NEO"]);
}

- (void)testShiftMKeyTogglesMessagesWithoutOpeningSettingsOverlay {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView keyDown:MatrixCodeShiftMKeyEvent()];

    NSDictionary *messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertTrue([messages[@"enabled"] boolValue]);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"MESSAGES ENABLED");
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));

    [hostView keyDown:MatrixCodeShiftMKeyEvent()];
    messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertFalse([messages[@"enabled"] boolValue]);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"MESSAGES DISABLED");
}

- (void)testShiftXKeyTogglesImagesWithoutOpeningSettingsOverlay {
    [self.preferences commitValues:@{
        @"mx-images": MatrixCodeJSONString(@{
            @"enabled": @NO,
            @"images": @[],
        }),
    }];
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView keyDown:MatrixCodeShiftXKeyEvent()];

    NSDictionary *images = MatrixCodeHostStoredImages(hostView);
    XCTAssertTrue([images[@"enabled"] boolValue]);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"IMAGES ENABLED");
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));

    [hostView keyDown:MatrixCodeShiftXKeyEvent()];
    images = MatrixCodeHostStoredImages(hostView);
    XCTAssertFalse([images[@"enabled"] boolValue]);
    XCTAssertEqualObjects(MatrixCodeHostShortcutToastText(hostView), @"IMAGES DISABLED");
}

- (void)testDensityShortcutKeysUseWebMultiplicativeStep {
    [self.preferences commitValues:@{
        @"mx-controls": MatrixCodeJSONString(@{@"density": @2}),
    }];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"=")];
    NSDictionary *controls =
        MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2.4, 0.0001);

    [hostView keyDown:MatrixCodeLetterKeyEventWithRepeat(@"=", YES)];
    controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2.88, 0.0001);

    [hostView keyDown:MatrixCodeLetterKeyEventWithRepeat(@"-", YES)];
    controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2.4, 0.0001);

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"-")];
    controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2.0, 0.0001);

    [self.preferences commitValues:@{
        @"mx-controls": MatrixCodeJSONString(@{@"density": @5.2}),
    }];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"=")];
    controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 6.0, 0.0001);
}

- (void)testReducedMotionPreferenceCanChangeDuringAHostSession {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];

    [hostView applyReducedMotionPreference:YES];
    XCTAssertTrue([[hostView valueForKey:@"reducedMotion"] boolValue]);
    [hostView applyReducedMotionPreference:NO];
    XCTAssertFalse([[hostView valueForKey:@"reducedMotion"] boolValue]);
}

- (void)testMetalInitializationFailureHasVisibleAccessibleNotice {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    [hostView showMetalFailureNotice];

    NSTextField *notice = (NSTextField *)MatrixCodeHostDescendantWithIdentifier(
        hostView, @"metal-failure-notice");
    XCTAssertNotNil(notice);
    XCTAssertTrue([notice.stringValue containsString:@"METAL COULD NOT BE INITIALIZED"]);
    XCTAssertEqualObjects(notice.accessibilityLabel, @"Matrix Code could not initialize Metal");
}

- (void)testStandaloneTopRightChromeHasFullscreenAndMultiMonitorButtons {
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskTitled
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = NO;
    window.contentView = hostView;
    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    NSView *chrome = MatrixCodeHostDescendantWithIdentifier(hostView, @"presentation-chrome");
    NSButton *fullscreen = (NSButton *)MatrixCodeHostDescendantWithIdentifier(
        hostView, @"presentation-fullscreen");
    NSButton *multiMonitor = (NSButton *)MatrixCodeHostDescendantWithIdentifier(
        hostView, @"presentation-multimonitor");
    XCTAssertNotNil(chrome);
    XCTAssertFalse(chrome.hidden);
    XCTAssertEqualObjects(fullscreen.toolTip, @"Fullscreen (F)");
    XCTAssertEqualObjects(multiMonitor.toolTip, @"Start multi-monitor mode (⇧⌘M)");
    XCTAssertEqualWithAccuracy(fullscreen.layer.cornerRadius, 6.0, 0.001);
    XCTAssertEqualWithAccuracy(multiMonitor.layer.cornerRadius, 6.0, 0.001);

    [fullscreen performClick:nil];
    XCTAssertTrue(window.toggledFullScreen);

    __block BOOL requestedMultiMonitor = NO;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodeRainHostRequestMultiMonitorNotification
                    object:hostView
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        requestedMultiMonitor = YES;
    }];
    [multiMonitor performClick:nil];
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue(requestedMultiMonitor);
}

- (void)testStandaloneMultiMonitorButtonDispatchesToAppDelegateWhenAvailable {
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskTitled
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;
    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    MatrixCodeMultiMonitorDelegateProbe *probe = [[MatrixCodeMultiMonitorDelegateProbe alloc] init];
    NSApp.delegate = probe;
    NSButton *multiMonitor = (NSButton *)MatrixCodeHostDescendantWithIdentifier(
        hostView, @"presentation-multimonitor");

    [multiMonitor performClick:nil];

    XCTAssertEqual(probe.enteredHost, hostView);
}

- (void)testCentremostMultiMonitorHostShowsControlsAndSettings {
    NSDictionary *session = @{
        @"screens": @[@{}, @{}],
        @"currentScreenId": @"center",
        @"controlsScreenId": @"center",
    };
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    NSButton *multiMonitor = (NSButton *)MatrixCodeHostDescendantWithIdentifier(
        hostView, @"presentation-multimonitor");
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"presentation-chrome"));
    XCTAssertEqualObjects(multiMonitor.title, @"▦ EXIT");
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"presentation-fullscreen"));

    [hostView showSettingsOverlay];
    id controller = [hostView valueForKey:@"configurationController"];
    XCTAssertNotNil(controller);
    XCTAssertTrue([[controller valueForKey:@"restrictedToMultiMonitorControls"] boolValue]);
    NSView *settingsPanel = MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel");
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(settingsPanel, @"characters"));
    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(settingsPanel, @"reset-controls"));
    for (NSString *identifier in @[@"replay", @"intro", @"messages", @"images", @"countdowns"]) {
        XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(settingsPanel, identifier),
                     @"%@",
                     identifier);
    }
}

- (void)testMultiMonitorControlHostIgnoresSingleDisplayPauseAndEditorShortcuts {
    NSDictionary *session = @{
        @"screens": @[@{}, @{}],
        @"currentScreenId": @"center",
        @"controlsScreenId": @"center",
    };
    MatrixCodeRainHostView *hostView = [[MatrixCodeRainHostView alloc]
        initWithFrame:NSZeroRect
                 mode:MatrixCodeRainHostModeStandalone
              session:session
suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:@YES forKey:@"hostActive"];

    [hostView keyDown:MatrixCodePKeyEvent(NO)];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"i")];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"m")];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"c")];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"n")];
    [hostView keyDown:MatrixCodeLetterKeyEvent(@"x")];

    XCTAssertFalse([[hostView valueForKey:@"userPaused"] boolValue]);
    XCTAssertNil([hostView valueForKey:@"configurationController"]);
    XCTAssertEqual(probe.animationStates.count, 0u);
}

- (void)testLegacyMultiMonitorSessionComputesControlHost {
    NSDictionary *session = @{
        @"screens": @[
            @{@"id": @"left", @"left": @(-1920), @"top": @0, @"width": @1920, @"height": @1080},
            @{@"id": @"center", @"left": @0, @"top": @0, @"width": @1920, @"height": @1080},
            @{@"id": @"right", @"left": @1920, @"top": @0, @"width": @1920, @"height": @1080},
        ],
        @"currentScreenId": @"center",
    };
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];

    XCTAssertNotNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"presentation-chrome"));
}

- (void)testNonCentremostMultiMonitorHostKeepsControlsHidden {
    NSDictionary *session = @{
        @"screens": @[@{}, @{}],
        @"currentScreenId": @"left",
        @"controlsScreenId": @"center",
    };
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 520)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView mouseMoved:MatrixCodeMouseMovedEvent(window)];
    [hostView layoutSubtreeIfNeeded];
    [hostView showSettingsOverlay];

    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"presentation-chrome"));
    XCTAssertNil([hostView valueForKey:@"configurationController"]);
}

- (void)testFKeyTogglesStandaloneFullScreen {
    MatrixCodeEscapeTestWindow *window =
        [[MatrixCodeEscapeTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                                      styleMask:NSWindowStyleMaskTitled
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    window.contentView = hostView;

    [hostView keyDown:MatrixCodeFKeyEvent(NO)];

    XCTAssertTrue(window.toggledFullScreen);
    XCTAssertFalse(hostView.fpsOverlayVisible);
}

- (void)testCommandShiftMKeyEquivalentRequestsStandaloneMultiMonitor {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];

    __block BOOL requestedMultiMonitor = NO;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodeRainHostRequestMultiMonitorNotification
                    object:hostView
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        requestedMultiMonitor = YES;
    }];

    BOOL handled = [hostView performKeyEquivalent:MatrixCodeCommandShiftMKeyEvent(NO)];

    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue(handled);
    XCTAssertTrue(requestedMultiMonitor);
}

- (void)testCommandShiftMKeyEquivalentExitsStandaloneMultiMonitor {
    NSDictionary *session = @{@"screens": @[@{}, @{}]};
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];

    __block BOOL requestedExit = NO;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodeRainHostRequestExitMultiMonitorNotification
                    object:hostView
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        requestedExit = YES;
    }];

    BOOL handled = [hostView performKeyEquivalent:MatrixCodeCommandShiftMKeyEvent(NO)];

    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue(handled);
    XCTAssertTrue(requestedExit);
}

- (void)testCommandShiftMKeyEquivalentDispatchesExitToAppDelegateWhenAvailable {
    NSDictionary *session = @{@"screens": @[@{}, @{}]};
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:session
                                suppressesIntroOverlay:YES];
    MatrixCodeMultiMonitorDelegateProbe *probe = [[MatrixCodeMultiMonitorDelegateProbe alloc] init];
    NSApp.delegate = probe;

    BOOL handled = [hostView performKeyEquivalent:MatrixCodeCommandShiftMKeyEvent(NO)];

    XCTAssertTrue(handled);
    XCTAssertEqual(probe.exitSender, hostView);
}

- (void)testPKeyTogglesUserPauseWithoutRepeating {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = YES;
    window.contentView = hostView;
    [hostView startAnimation];
    MatrixCodeMetalView *metalView = [hostView valueForKey:@"metalView"];
    XCTAssertNotNil(metalView);
    XCTAssertFalse(metalView.isPaused);

    [hostView keyDown:MatrixCodePKeyEvent(NO)];
    XCTAssertTrue([[hostView valueForKey:@"userPaused"] boolValue]);
    XCTAssertTrue(metalView.isPaused);

    [hostView keyDown:MatrixCodePKeyEvent(YES)];
    XCTAssertTrue([[hostView valueForKey:@"userPaused"] boolValue]);
    XCTAssertTrue(metalView.isPaused);

    [hostView keyDown:MatrixCodePKeyEvent(NO)];
    XCTAssertFalse([[hostView valueForKey:@"userPaused"] boolValue]);
    XCTAssertFalse(metalView.isPaused);
}

- (void)testStandaloneAnimationUsesMetalDisplayLinkInsteadOfDuplicateTimer {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = YES;
    window.contentView = hostView;

    [hostView startAnimation];

    MatrixCodeMetalView *metalView = [hostView valueForKey:@"metalView"];
    XCTAssertNotNil(metalView);
    XCTAssertFalse(metalView.isPaused);
    XCTAssertNil([hostView valueForKey:@"animationTimer"]);
    XCTAssertEqual(metalView.preferredFramesPerSecond,
                   [MatrixCodeMetalView maximumFramesPerSecondForScreen:window.screen ?: NSScreen.mainScreen]);
}

- (void)testOptionFKeyTogglesMeasuredFPSOverlayWithoutExtraTimer {
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = YES;
    window.contentView = hostView;
    [hostView startAnimation];
    MatrixCodeMetalView *metalView = [hostView valueForKey:@"metalView"];
    XCTAssertNotNil(metalView);
    __block NSNumber *notifiedVisible = nil;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodeRainHostFPSOverlayVisibilityDidChangeNotification
                    object:hostView
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        notifiedVisible = notification.userInfo[MatrixCodeRainHostFPSOverlayVisibleKey];
    }];

    [hostView keyDown:MatrixCodeOptionFKeyEvent(NO)];
    NSTextField *overlay = (NSTextField *)MatrixCodeHostDescendantWithIdentifier(hostView, @"fps-overlay");
    XCTAssertNotNil(overlay);
    XCTAssertFalse(overlay.hidden);
    CGSize initialSize = metalView.currentRenderSize;
    NSString *initialDiagnostics = [NSString stringWithFormat:
        @"0 fps · %ld%% res · %ld×%ld",
        (long)floor(metalView.currentRenderScale * 100 + 0.5),
        (long)floor(initialSize.width + 0.5),
        (long)floor(initialSize.height + 0.5)];
    XCTAssertEqualObjects(overlay.stringValue, initialDiagnostics);
    XCTAssertEqualObjects(notifiedVisible, @YES);
    NSDictionary *storedUIState = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-ui-state"]);
    XCTAssertEqualObjects(storedUIState[@"fpsOverlayVisible"], @YES);
    XCTAssertNil([hostView valueForKey:@"animationTimer"]);

    MatrixCodeMetalFrameHandler handler = metalView.frameHandler;
    XCTAssertNotNil(handler);
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    for (NSUInteger frame = 0; frame <= 32; frame++) {
        handler(metalView, [start dateByAddingTimeInterval:frame / 120.0], 120);
    }
    NSString *runningDiagnostics = [NSString stringWithFormat:
        @"120 fps · %ld%% res · %ld×%ld",
        (long)floor(metalView.currentRenderScale * 100 + 0.5),
        (long)floor(metalView.currentRenderSize.width + 0.5),
        (long)floor(metalView.currentRenderSize.height + 0.5)];
    XCTAssertEqualObjects(overlay.stringValue, runningDiagnostics);

    [hostView keyDown:MatrixCodeOptionFKeyEvent(YES)];
    XCTAssertFalse(overlay.hidden);

    [hostView keyDown:MatrixCodeOptionFKeyEvent(NO)];
    XCTAssertTrue(overlay.hidden);
    XCTAssertEqualObjects(notifiedVisible, @NO);
    XCTAssertNil([self.preferences storedValues][@"mx-ui-state"]);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testStoredFPSOverlayVisibilityIsRestoredOnLaunch {
    [self.preferences commitValues:@{
        @"mx-ui-state": MatrixCodeJSONString(@{@"fpsOverlayVisible": @YES}),
    }];
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:window.contentView.bounds
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    hostView.usesInternalAnimationTimer = YES;
    window.contentView = hostView;
    [hostView startAnimation];

    NSTextField *overlay = (NSTextField *)MatrixCodeHostDescendantWithIdentifier(hostView, @"fps-overlay");
    XCTAssertNotNil(overlay);
    XCTAssertTrue(hostView.fpsOverlayVisible);
    XCTAssertFalse(overlay.hidden);
    MatrixCodeMetalView *metalView = [hostView valueForKey:@"metalView"];
    NSString *diagnostics = [NSString stringWithFormat:
        @"0 fps · %ld%% res · %ld×%ld",
        (long)floor(metalView.currentRenderScale * 100 + 0.5),
        (long)floor(metalView.currentRenderSize.width + 0.5),
        (long)floor(metalView.currentRenderSize.height + 0.5)];
    XCTAssertEqualObjects(overlay.stringValue, diagnostics);
}

- (void)testFPSOverlayUsesWebDiagnosticsFormatAndPassedRendererFPS {
    MatrixCodeRainHostView *hostView =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSZeroRect
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRampMetalProbe *probe = [[MatrixCodeRampMetalProbe alloc] init];
    probe.currentRenderScale = 0.75;
    probe.currentRenderSize = CGSizeMake(1440, 900);
    NSTextField *overlay = [NSTextField labelWithString:@""];
    [hostView setValue:probe forKey:@"metalView"];
    [hostView setValue:overlay forKey:@"fpsOverlay"];
    [hostView setValue:@YES forKey:@"fpsOverlayVisible"];

    [hostView updateFPSOverlayWithFramesPerSecond:59.5];

    XCTAssertEqualObjects(overlay.stringValue, @"60 fps · 75% res · 1440×900");
}

- (void)testNumericFPSOverlayFlagIsRejectedLikeWebBooleanSanitizer {
    [self.preferences commitValues:@{
        @"mx-ui-state": @"{\"fpsOverlayVisible\":1}",
    }];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 640, 480)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    MatrixCodeRainHostView *hostView = [[MatrixCodeRainHostView alloc]
        initWithFrame:window.contentView.bounds
                 mode:MatrixCodeRainHostModeStandalone
              session:nil
suppressesIntroOverlay:YES];
    window.contentView = hostView;
    [hostView startAnimation];

    XCTAssertFalse(hostView.fpsOverlayVisible);
}

@end
