#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"
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
@end

@implementation MatrixCodeRainHostViewTests

static NSEvent *MatrixCodeKeyEvent(NSWindow *window,
                                   NSString *characters,
                                   unsigned short keyCode,
                                   BOOL repeat) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:0
                           timestamp:0
                        windowNumber:window.windowNumber
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:repeat
                             keyCode:keyCode];
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

static NSView *MatrixCodeHostDescendantWithIdentifier(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *subview in view.subviews) {
        NSView *match = MatrixCodeHostDescendantWithIdentifier(subview, identifier);
        if (match) return match;
    }
    return nil;
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

- (void)testFKeyTogglesMeasuredFPSOverlayWithoutExtraTimer {
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

    [hostView keyDown:MatrixCodeFKeyEvent(NO)];
    NSTextField *overlay = (NSTextField *)MatrixCodeHostDescendantWithIdentifier(hostView, @"fps-overlay");
    XCTAssertNotNil(overlay);
    XCTAssertFalse(overlay.hidden);
    XCTAssertEqualObjects(overlay.stringValue, @"0 FPS");
    XCTAssertNil([hostView valueForKey:@"animationTimer"]);

    MatrixCodeMetalFrameHandler handler = metalView.frameHandler;
    XCTAssertNotNil(handler);
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    for (NSUInteger frame = 0; frame <= 32; frame++) {
        handler(metalView, [start dateByAddingTimeInterval:frame / 120.0], 120);
    }
    XCTAssertEqualObjects(overlay.stringValue, @"120 FPS");

    [hostView keyDown:MatrixCodeFKeyEvent(YES)];
    XCTAssertFalse(overlay.hidden);

    [hostView keyDown:MatrixCodeFKeyEvent(NO)];
    XCTAssertTrue(overlay.hidden);
}

@end
