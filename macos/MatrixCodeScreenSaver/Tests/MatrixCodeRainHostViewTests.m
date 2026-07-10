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

static NSEvent *MatrixCodeShiftXKeyEvent(void) {
    return MatrixCodeKeyEventWithFlags(nil, @"X", 7, NSEventModifierFlagShift, NO);
}

static NSEvent *MatrixCodeShiftMKeyEvent(void) {
    return MatrixCodeKeyEventWithFlags(nil, @"M", 46, NSEventModifierFlagShift, NO);
}

static NSEvent *MatrixCodeLetterKeyEvent(NSString *letter) {
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
    XCTAssertNotNil([hostView valueForKey:@"configurationController"]);
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
    XCTAssertEqualObjects(overlay.stringValue, @"0 FPS");
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
    XCTAssertEqualObjects(overlay.stringValue, @"120 FPS");

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
    XCTAssertEqualObjects(overlay.stringValue, @"0 FPS");
}

@end
