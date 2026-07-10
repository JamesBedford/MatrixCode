#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainHostView.h"

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

@interface MatrixCodeRainHostViewTests : XCTestCase
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalStoredValues;
@end

@implementation MatrixCodeRainHostViewTests

- (void)setUp {
    [super setUp];
    self.preferences = [[MatrixCodePreferences alloc] init];
    self.originalStoredValues = [self.preferences storedValues];
    [self.preferences commitValues:@{}];
}

- (void)tearDown {
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

static NSEvent *MatrixCodeLetterKeyEvent(NSString *letter) {
    NSDictionary<NSString *, NSNumber *> *keyCodes = @{
        @"h": @4,
        @"i": @34,
        @"m": @46,
        @"c": @8,
        @"n": @45,
        @"-": @27,
        @"=": @24,
    };
    return MatrixCodeKeyEvent(nil, letter, [keyCodes[letter] unsignedShortValue], NO);
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
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-panel"));
}

- (void)testWebEditorShortcutKeysOpenMatchingNativeEditors {
    NSArray<NSArray<NSString *> *> *shortcuts = @[
        @[@"i", @"intro"],
        @[@"m", @"messages"],
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
    XCTAssertNil(MatrixCodeHostDescendantWithIdentifier(hostView, @"settings-hover-overlay"));

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"n")];
    messages = MatrixCodeHostStoredMessages(hostView);
    XCTAssertFalse([messages[@"enabled"] boolValue]);
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

    [hostView keyDown:MatrixCodeLetterKeyEvent(@"-")];
    controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2.0, 0.0001);
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
    XCTAssertEqualObjects(multiMonitor.toolTip, @"Start multi-monitor mode");
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
    XCTAssertEqualObjects(overlay.stringValue, @"0 FPS");
    XCTAssertEqualObjects(notifiedVisible, @YES);
    XCTAssertNil([hostView valueForKey:@"animationTimer"]);

    MatrixCodeMetalFrameHandler handler = metalView.frameHandler;
    XCTAssertNotNil(handler);
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    for (NSUInteger frame = 0; frame <= 32; frame++) {
        handler(metalView, [start dateByAddingTimeInterval:frame / 120.0], 120);
    }
    XCTAssertEqualObjects(overlay.stringValue, @"120 FPS");

    [hostView keyDown:MatrixCodeOptionFKeyEvent(YES)];
    XCTAssertFalse(overlay.hidden);

    [hostView keyDown:MatrixCodeOptionFKeyEvent(NO)];
    XCTAssertTrue(overlay.hidden);
    XCTAssertEqualObjects(notifiedVisible, @NO);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

@end
