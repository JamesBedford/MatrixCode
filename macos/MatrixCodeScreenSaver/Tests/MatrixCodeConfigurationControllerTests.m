#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeRainSimulation.h"

@interface MatrixCodeConfigurationController (Testing)
- (void)controlChanged:(id)sender;
- (void)imageNumberChanged:(NSTextField *)sender;
- (void)messageChoiceChanged:(NSPopUpButton *)sender;
- (void)moveIntroLine:(NSButton *)sender;
- (void)moveImage:(NSButton *)sender;
- (void)moveMessage:(NSButton *)sender;
- (void)moveMoment:(NSButton *)sender;
- (void)nudgeDensityByFactor:(double)factor;
- (void)openEditor:(NSButton *)sender;
- (void)previewIntro:(id)sender;
- (void)previewMessage:(id)sender;
- (void)resetControls:(id)sender;
- (NSDictionary<NSString *, NSString *> *)serializedValues;
- (void)setSettingsPanelVisible:(BOOL)visible immediate:(BOOL)immediate;
- (void)showPreviewWithIntro:(BOOL)intro message:(BOOL)message;
@end

static NSView *MatrixCodeDescendantWithIdentifier(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *subview in view.subviews) {
        NSView *match = MatrixCodeDescendantWithIdentifier(subview, identifier);
        if (match) return match;
    }
    return nil;
}

static void MatrixCodeSelectRepresentedValue(NSPopUpButton *popup, NSString *value) {
    for (NSMenuItem *item in popup.itemArray) {
        if ([item.representedObject isEqual:value]) {
            [popup selectItem:item];
            return;
        }
    }
    XCTFail(@"Missing represented value %@ in %@", value, popup.identifier);
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

static BOOL MatrixCodeContainsLabel(NSView *view, NSString *label) {
    if ([view isKindOfClass:NSTextField.class] &&
        [[[(NSTextField *)view stringValue] uppercaseString] isEqualToString:label.uppercaseString]) {
        return YES;
    }
    for (NSView *subview in view.subviews) {
        if (MatrixCodeContainsLabel(subview, label)) return YES;
    }
    return NO;
}

@interface MatrixCodeConfigurationControllerTests : XCTestCase
@property(nonatomic, strong) MatrixCodePreferences *preferences;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalStoredValues;
@end

@implementation MatrixCodeConfigurationControllerTests

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

- (void)testNativeConfigurationSheetBuildsWebStylePanelOverRain {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    XCTAssertNotNil(controller.window);
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-rain-backdrop"));
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-hover-overlay"));
    NSView *panel = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-panel");
    XCTAssertNotNil(panel);
    [controller.window.contentView layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(panel.frame.size.width, 320, 0.5);
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView, @"Rain"));
    for (NSString *identifier in @[@"characters", @"intro", @"messages", @"images", @"countdowns",
                                    @"reset-controls"]) {
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(panel, identifier), @"%@", identifier);
    }
    // The dismiss button lives in the settings window's top-right corner over
    // the rain, not inside the panel column.
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-close"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-done"));
    NSButton *close = (NSButton *)MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                                     @"settings-close");
    XCTAssertNotNil(close);
    XCTAssertTrue([close isKindOfClass:NSButton.class]);
    XCTAssertEqualObjects(close.target, controller);
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-hint"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                    @"ambient-title"));
}

- (void)testSettingsCloseButtonDismissesConfigurationSheet {
    __block BOOL closed = NO;
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{ closed = YES; }];
    NSButton *close = (NSButton *)MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                                     @"settings-close");
    XCTAssertNotNil(close);

    // Controls already persist as they change, so a nudge is committed before
    // the corner button is used purely to dismiss the sheet.
    [controller nudgeDensityByFactor:1.5];
    NSDictionary *controls = MatrixCodeJSONDictionary([self.preferences storedValues][@"mx-controls"]);
    XCTAssertNotNil(controls);
    XCTAssertGreaterThan([controls[@"density"] doubleValue], 2.0);

    [close performClick:nil];
    XCTAssertTrue(closed);
}

- (void)testSettingsBackdropUsesMetalDisplayLinkWithoutDuplicateTimer {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    MatrixCodeMetalView *background = [controller valueForKey:@"settingsMetalView"];
    XCTAssertTrue([background isKindOfClass:MatrixCodeMetalView.class]);
    XCTAssertFalse(background.isPaused);
    XCTAssertNil([controller valueForKey:@"settingsAnimationTimer"]);
}

- (void)testSettingsCommitPreservesIntroSeenWrittenAfterControllerOpened {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    [self.preferences setImmediateValue:@"1" forKey:@"mx-intro-seen"];

    [controller nudgeDensityByFactor:1.2];

    XCTAssertEqualObjects([self.preferences storedValues][@"mx-intro-seen"], @"1");
}

- (void)testStandalonePreviewUsesMetalDisplayLinkWithoutDuplicateTimer {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    [controller setValue:@NO forKey:@"previewReducedMotionOverride"];
    [controller showPreviewWithIntro:YES message:NO];
    NSWindowController *previewController = [controller valueForKey:@"previewController"];
    MatrixCodeMetalView *metalView = [previewController valueForKey:@"metalView"];
    XCTAssertTrue([metalView isKindOfClass:MatrixCodeMetalView.class]);
    XCTAssertFalse(metalView.isPaused);
    XCTAssertNil([previewController valueForKey:@"timer"]);
    XCTAssertNotNil(metalView.frameHandler);
    MatrixCodeIntroOverlayView *introView = [previewController valueForKey:@"introView"];
    XCTAssertTrue(introView.playing);
    XCTAssertNil([previewController valueForKey:@"rainStartDate"]);
    XCTAssertEqualWithAccuracy([[metalView valueForKey:@"densityScale"] doubleValue], 0, 0.001);
    XCTAssertLessThan([[metalView valueForKey:@"rainElapsed"] doubleValue], 0);

    [metalView setAnimationActive:NO];
    NSDate *startDate = [previewController valueForKey:@"startDate"];
    NSDate *completionDate =
        [startDate dateByAddingTimeInterval:introView.totalDuration + 0.01];
    metalView.frameHandler(metalView, completionDate, 60);
    XCTAssertFalse(introView.playing);
    XCTAssertEqualObjects([previewController valueForKey:@"rainStartDate"], completionDate);
    metalView.frameHandler(metalView,
                           [completionDate dateByAddingTimeInterval:4],
                           60);
    XCTAssertEqualWithAccuracy([[metalView valueForKey:@"densityScale"] doubleValue],
                               MatrixCodeRainRampEase(0.5),
                               0.001);

    [previewController close];
}

- (void)testStandaloneMessagePreviewFiresImmediatelyWithoutRewritingDraftTiming {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    [controller setValue:@NO forKey:@"previewReducedMotionOverride"];

    [controller previewMessage:nil];

    NSWindowController *previewController = [controller valueForKey:@"previewController"];
    MatrixCodeMetalView *metalView = [previewController valueForKey:@"metalView"];
    [metalView diagnosticPackedStateWithWidth:800 height:500];
    MatrixCodeRainSimulation *simulation = [metalView valueForKey:@"rainSimulation"];
    NSDictionary *messages = [metalView valueForKey:@"messages"];
    XCTAssertTrue(simulation.hasMessageTargets);
    XCTAssertTrue([[metalView valueForKey:@"messageDraftPreviewActive"] boolValue]);
    XCTAssertEqualWithAccuracy([messages[@"frequencyMs"] doubleValue], 8000, 0.001);

    [previewController close];
}

- (void)testStandalonePreviewRespectsReducedMotionWithWarmedStaticRain {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    [controller setValue:@YES forKey:@"previewReducedMotionOverride"];

    [controller showPreviewWithIntro:YES message:YES];

    NSWindowController *previewController = [controller valueForKey:@"previewController"];
    MatrixCodeMetalView *metalView = [previewController valueForKey:@"metalView"];
    NSData *state = [metalView diagnosticPackedStateWithWidth:800 height:500];
    MatrixCodeRainSimulation *simulation = [metalView valueForKey:@"rainSimulation"];
    const uint8_t *bytes = state.bytes;
    BOOL hasRain = NO;
    for (NSUInteger offset = 0; offset + 3 < state.length; offset += 4) {
        if (bytes[offset + 1] > 0) {
            hasRain = YES;
            break;
        }
    }
    XCTAssertTrue(metalView.isPaused);
    XCTAssertNil(metalView.frameHandler);
    XCTAssertNil([previewController valueForKey:@"introView"]);
    XCTAssertEqualWithAccuracy([[metalView valueForKey:@"densityScale"] doubleValue], 1, 0.001);
    XCTAssertTrue(hasRain);
    XCTAssertFalse(simulation.hasMessageTargets);

    [previewController close];
}

- (void)testSettingsPanelFadesAsHoverHudInsteadOfPermanentModalSurface {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSView *overlay = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                        @"settings-hover-overlay");
    NSView *panel = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-panel");
    XCTAssertNotNil(overlay);
    XCTAssertNotNil(panel);
    XCTAssertFalse(panel.hidden);
    XCTAssertEqualWithAccuracy(panel.alphaValue, 1, 0.001);

    [controller setSettingsPanelVisible:NO immediate:YES];
    XCTAssertTrue(panel.hidden);
    XCTAssertEqualWithAccuracy(panel.alphaValue, 0, 0.001);
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-rain-backdrop"));

    [controller setSettingsPanelVisible:YES immediate:YES];
    XCTAssertFalse(panel.hidden);
    XCTAssertEqualWithAccuracy(panel.alphaValue, 1, 0.001);
}

- (void)testEmbeddedReplayButtonInvokesLiveHostCallbackAndHidesPanel {
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    __block NSUInteger replayCount = 0;
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc]
            initEmbeddedInView:hostView
                  closeHandler:^{}
            replayIntroHandler:^{ replayCount++; }];
    XCTAssertNotNil(controller);
    NSButton *replay = (NSButton *)MatrixCodeDescendantWithIdentifier(hostView, @"replay");
    NSView *panel = MatrixCodeDescendantWithIdentifier(hostView, @"settings-panel");
    XCTAssertNotNil(replay);
    XCTAssertNotNil(panel);
    XCTAssertFalse(panel.hidden);

    [replay sendAction:replay.action to:replay.target];

    XCTAssertEqual(replayCount, 1u);
    XCTAssertTrue(panel.hidden);
}

- (void)testRestrictedMultiMonitorPanelExposesOnlySafeActions {
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    __block NSUInteger replayCount = 0;
    MatrixCodeConfigurationController *controller = [[MatrixCodeConfigurationController alloc]
        initEmbeddedInView:hostView
              closeHandler:^{}
        replayIntroHandler:^{ replayCount++; }
       introPreviewHandler:^(NSDictionary<NSString *,NSString *> *values,
                             dispatch_block_t completion) {
            (void)values;
            completion();
        }
     messagePreviewHandler:^(NSDictionary<NSString *,NSString *> *values) {
            (void)values;
        }
         resetRainHandler:^{}
restrictedToMultiMonitorControls:YES];
    NSView *panel = MatrixCodeDescendantWithIdentifier(hostView, @"settings-panel");

    XCTAssertTrue([[controller valueForKey:@"restrictedToMultiMonitorControls"] boolValue]);
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(panel, @"characters"));
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(panel, @"reset-controls"));
    for (NSString *identifier in @[@"replay", @"intro", @"messages", @"images", @"countdowns"]) {
        XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, identifier), @"%@", identifier);
    }

    [controller openEditorKind:@"messages"];
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(hostView, @"settings-editor-backdrop"));
    XCTAssertEqual(replayCount, 0u);
    [controller openEditorKind:@"characters"];
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(hostView, @"settings-editor-card-characters"));
}

- (void)testEmbeddedIntroPreviewSendsUnsavedDraftToHostAndRestoresEditorOnCompletion {
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    __block NSDictionary<NSString *, NSString *> *previewValues = nil;
    __block dispatch_block_t previewCompletion = nil;
    MatrixCodeConfigurationController *controller = [[MatrixCodeConfigurationController alloc]
        initEmbeddedInView:hostView
              closeHandler:^{}
        replayIntroHandler:nil
       introPreviewHandler:^(NSDictionary<NSString *,NSString *> *storedValues,
                             dispatch_block_t completion) {
            previewValues = storedValues;
            previewCompletion = completion;
        }
     messagePreviewHandler:nil
         resetRainHandler:nil];
    [controller openEditorKind:@"intro"];
    [controller setValue:[@[
        [@{@"text": @"UNSAVED INTRO", @"holdMs": @100, @"pauseMs": @0} mutableCopy]
    ] mutableCopy] forKey:@"introLines"];
    NSView *backdrop = MatrixCodeDescendantWithIdentifier(hostView, @"settings-editor-backdrop");

    [controller previewIntro:nil];

    XCTAssertNotNil(previewValues);
    XCTAssertNotNil(previewCompletion);
    XCTAssertTrue(backdrop.hidden);
    XCTAssertNil([controller valueForKey:@"previewController"]);
    NSDictionary *intro = MatrixCodeJSONDictionary(previewValues[@"mx-intro"]);
    XCTAssertEqualObjects([intro[@"lines"] firstObject][@"text"], @"UNSAVED INTRO");
    XCTAssertNil([self.preferences storedValues][@"mx-intro-seen"]);

    previewCompletion();
    XCTAssertFalse(backdrop.hidden);
}

- (void)testEmbeddedMessagePreviewSendsUnsavedDraftToHostAndRestoresAfterWebCap {
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    __block NSDictionary<NSString *, NSString *> *previewValues = nil;
    MatrixCodeConfigurationController *controller = [[MatrixCodeConfigurationController alloc]
        initEmbeddedInView:hostView
              closeHandler:^{}
        replayIntroHandler:nil
       introPreviewHandler:nil
     messagePreviewHandler:^(NSDictionary<NSString *,NSString *> *storedValues) {
            previewValues = storedValues;
        }
         resetRainHandler:nil];
    [controller openEditorKind:@"messages"];
    [controller setValue:[@[@"UNSAVED MESSAGE"] mutableCopy] forKey:@"messageLines"];
    NSView *backdrop = MatrixCodeDescendantWithIdentifier(hostView, @"settings-editor-backdrop");

    NSDate *previewStartDate = NSDate.date;
    [controller previewMessage:nil];
    NSDate *previewFinishDate = NSDate.date;

    XCTAssertTrue(backdrop.hidden);
    XCTAssertNil([controller valueForKey:@"previewController"]);
    NSDictionary *messages = MatrixCodeJSONDictionary(previewValues[@"mx-messages"]);
    XCTAssertEqualObjects(messages[@"messages"], (@[@"UNSAVED MESSAGE"]));
    NSTimer *restoreTimer = [controller valueForKey:@"messagePreviewRestoreTimer"];
    XCTAssertNotNil(restoreTimer);
    XCTAssertTrue(restoreTimer.isValid);
    XCTAssertGreaterThan([restoreTimer.fireDate timeIntervalSinceDate:previewStartDate], 7.99);
    XCTAssertLessThan([restoreTimer.fireDate timeIntervalSinceDate:previewFinishDate], 8.01);

    [restoreTimer fire];
    XCTAssertFalse(backdrop.hidden);
    XCTAssertNil([controller valueForKey:@"messagePreviewRestoreTimer"]);
}

- (void)testCancelAfterMessagePreviewReconfiguresLiveSchedulerToStoredDocument {
    NSDictionary *originalMessages = @{
        @"enabled": @YES,
        @"messages": @[@"ORIGINAL"],
        @"frequencyMs": @8000,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
    };
    NSDictionary<NSString *, NSString *> *originalValues = @{
        @"mx-messages": MatrixCodeJSONString(originalMessages),
    };
    [self.preferences commitValues:originalValues];
    MatrixCodeMetalView *metalView = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:@{
                  @"seed": @12345,
                  @"epoch": @1700000000000,
                  @"currentScreenId": @"screen",
                  @"screens": @[@{@"id": @"screen", @"left": @0, @"top": @0,
                                  @"width": @640, @"height": @360}],
              }
         storedValues:originalValues];
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    MatrixCodeConfigurationController *controller = [[MatrixCodeConfigurationController alloc]
        initEmbeddedInView:hostView
              closeHandler:^{}
        replayIntroHandler:nil
       introPreviewHandler:nil
     messagePreviewHandler:^(NSDictionary<NSString *,NSString *> *storedValues) {
            [metalView previewMessageWithStoredValues:storedValues atDate:NSDate.date];
        }
         resetRainHandler:nil];
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodePreviewValuesDidChangeNotification
                    object:controller
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        [metalView reloadStoredValues:notification.userInfo[MatrixCodePreviewValuesKey]];
    }];
    [controller openEditorKind:@"messages"];
    [controller setValue:[@[@"UNSAVED DRAFT"] mutableCopy] forKey:@"messageLines"];

    [controller previewMessage:nil];

    XCTAssertTrue([[metalView valueForKey:@"messageDraftPreviewActive"] boolValue]);
    [[controller valueForKey:@"messagePreviewRestoreTimer"] fire];
    [controller cancelOperation:nil];

    XCTAssertEqualObjects([metalView valueForKey:@"messages"][@"messages"],
                          (@[@"ORIGINAL"]));
    XCTAssertFalse([[metalView valueForKey:@"messageDraftPreviewActive"] boolValue]);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testEmbeddedResetNotifiesHostAfterCommittingControlDefaults {
    NSView *hostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 520)];
    __block NSUInteger resetCount = 0;
    MatrixCodeConfigurationController *controller = [[MatrixCodeConfigurationController alloc]
        initEmbeddedInView:hostView
              closeHandler:^{}
        replayIntroHandler:nil
       introPreviewHandler:nil
     messagePreviewHandler:nil
         resetRainHandler:^{ resetCount++; }];

    [controller resetControls:nil];

    XCTAssertEqual(resetCount, 1u);
    NSDictionary *storedControls = MatrixCodeJSONDictionary(
        [self.preferences storedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy([storedControls[@"rampUpMs"] doubleValue], 8000, 0.001);
}

- (void)testValidWrongShapeMessagesJSONSanitizesToEmptyListInsteadOfDefaults {
    for (NSString *rawMessages in @[@"[]", @"null"]) {
        [self.preferences commitValues:@{@"mx-messages": rawMessages}];
        MatrixCodeConfigurationController *controller =
            [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
        NSDictionary *messages = MatrixCodeJSONDictionary(
            [controller serializedValues][@"mx-messages"]);
        XCTAssertEqualObjects(messages[@"messages"], @[], @"%@", rawMessages);
    }
}

- (void)testEditorButtonsOpenCenteredCustomCards {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    for (NSString *kind in @[@"characters", @"intro", @"messages", @"images", @"countdowns"]) {
        NSButton *button = (NSButton *)MatrixCodeDescendantWithIdentifier(
            controller.window.contentView, kind);
        XCTAssertTrue([button isKindOfClass:NSButton.class]);
        [controller openEditor:button];
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                           @"settings-editor-backdrop"));
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(
            controller.window.contentView,
            [@"settings-editor-card-" stringByAppendingString:kind]));
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                           @"editor-reset"));
        NSView *cancel = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                            @"editor-cancel");
        if ([kind isEqualToString:@"characters"]) XCTAssertNil(cancel);
        else XCTAssertNotNil(cancel);
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                           @"editor-save"));
    }
}

- (void)testEditorBackdropClicksDoNotDismissCustomCards {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    for (NSString *kind in @[@"characters", @"intro", @"messages", @"images", @"countdowns"]) {
        NSButton *button = (NSButton *)MatrixCodeDescendantWithIdentifier(
            controller.window.contentView, kind);
        [controller openEditor:button];
        NSView *backdrop = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                              @"settings-editor-backdrop");
        XCTAssertNotNil(backdrop);
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:NSMakePoint(1, 1)
                                      modifierFlags:0
                                          timestamp:0
                                       windowNumber:controller.window.windowNumber
                                            context:nil
                                        eventNumber:0
                                         clickCount:1
                                           pressure:1];

        [backdrop mouseDown:event];

        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                           @"settings-editor-backdrop"));
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(
            controller.window.contentView,
            [@"settings-editor-card-" stringByAppendingString:kind]));
    }
}

- (void)testRainSlidersShowLiveNumericValues {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSView *rain = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                      @"settings-panel");
    NSArray<NSString *> *keys = @[
        @"density", @"rampUpMs", @"trailLength", @"trailVariation", @"speed", @"glyphScale",
        @"glow", @"leadBrightness", @"vignette",
    ];
    for (NSString *key in keys) {
        NSSlider *slider = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, key);
        NSTextField *readout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
            rain, [key stringByAppendingString:@"-value"]);
        XCTAssertTrue([slider isKindOfClass:NSSlider.class], @"Missing %@ slider", key);
        XCTAssertTrue([readout isKindOfClass:NSTextField.class], @"Missing %@ readout", key);
        XCTAssertGreaterThan(readout.stringValue.length, 0);
    }
    NSSlider *density = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"density");
    NSSlider *ramp = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"rampUpMs");
    XCTAssertEqualWithAccuracy(density.minValue, 0.1, 0.001);
    XCTAssertEqualWithAccuracy(ramp.maxValue, 60000, 0.001);

    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"speed");
    NSTextField *speedReadout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        rain, @"speed-value");
    speed.doubleValue = 2.25;
    [speed sendAction:speed.action to:speed.target];
    XCTAssertEqualObjects(speedReadout.stringValue, @"2.25×");
    XCTAssertEqualWithAccuracy(speed.minValue, 0.1, 0.001);

    NSSlider *trail = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"trailLength");
    NSTextField *trailReadout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        rain, @"trailLength-value");
    XCTAssertEqualObjects(trailReadout.stringValue, @"50%");
    trail.doubleValue = 0.5;
    [trail sendAction:trail.action to:trail.target];
    XCTAssertEqualObjects(trailReadout.stringValue, @"100%");

    NSSlider *variation = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"trailVariation");
    NSTextField *variationReadout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        rain, @"trailVariation-value");
    XCTAssertEqualObjects(variationReadout.stringValue, @"100%");
    variation.doubleValue = 0.35;
    [variation sendAction:variation.action to:variation.target];
    XCTAssertEqualObjects(variationReadout.stringValue, @"35%");
}

- (void)testRainSlidersQuantizeToWebStepValues {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSView *panel = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                       @"settings-panel");
    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(panel, @"speed");
    speed.doubleValue = 2.237;
    [speed sendAction:speed.action to:speed.target];

    NSDictionary *controls = MatrixCodeJSONDictionary([controller serializedValues][@"mx-controls"]);
    XCTAssertEqualWithAccuracy(speed.doubleValue, 2.25, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 2.25, 0.0001);
}

- (void)testConfigurationLoadsControlsThroughStrictWebSanitizer {
    [self.preferences commitValues:@{
        @"mx-controls": MatrixCodeJSONString(@{
            @"speed": @99,
            @"density": @(-5),
            @"rampUpMs": @YES,
            @"preset": @"invalid",
            @"mirror": @0,
            @"vignette": @YES,
            @"quality": @"ultra",
        }),
    }];
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSDictionary *controls = [controller valueForKey:@"controls"];

    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 3, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 0.1, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"rampUpMs"] doubleValue], 8000, 0.0001);
    XCTAssertEqualObjects(controls[@"preset"], @"classic");
    XCTAssertEqualObjects(controls[@"mirror"], @YES);
    XCTAssertEqualWithAccuracy([controls[@"vignette"] doubleValue], 0.42, 0.0001);
    XCTAssertEqualObjects(controls[@"quality"], @"high");
}

- (void)testRampSliderDebouncesAndReplaysSettingsRainFromEmpty {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSSlider *ramp = (NSSlider *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"rampUpMs");
    MatrixCodeMetalView *metalView = [controller valueForKey:@"settingsMetalView"];
    XCTAssertNotNil(ramp);
    XCTAssertNotNil(metalView);

    ramp.doubleValue = 1000;
    [ramp sendAction:ramp.action to:ramp.target];
    NSTimer *timer = [controller valueForKey:@"settingsRampPreviewTimer"];
    XCTAssertTrue(timer.isValid);

    [timer fire];

    NSDate *startDate = [controller valueForKey:@"settingsRampStartDate"];
    XCTAssertNotNil(startDate);
    XCTAssertNil([controller valueForKey:@"settingsRampPreviewTimer"]);
    MatrixCodeMetalFrameHandler frameHandler = metalView.frameHandler;
    XCTAssertNotNil(frameHandler);
    frameHandler(metalView, [startDate dateByAddingTimeInterval:0.5], 60);
    XCTAssertEqualWithAccuracy([[metalView valueForKey:@"rainElapsed"] doubleValue], 0.5, 0.0001);
    XCTAssertEqualWithAccuracy([[metalView valueForKey:@"densityScale"] doubleValue],
                               MatrixCodeRainRampEase(0.5),
                               0.0001);

    ramp.doubleValue = 2000;
    [ramp sendAction:ramp.action to:ramp.target];
    NSTimer *teardownTimer = [controller valueForKey:@"settingsRampPreviewTimer"];
    XCTAssertTrue(teardownTimer.isValid);

    [controller cancelOperation:nil];

    XCTAssertFalse(teardownTimer.isValid);
    XCTAssertNil([controller valueForKey:@"settingsRampPreviewTimer"]);
    XCTAssertNil(metalView.frameHandler);
}

- (void)testCountdownEditorShowsTickingWebStylePreview {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"countdowns");
    [controller openEditor:open];

    NSTextField *preview = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"countdown-preview");
    XCTAssertNotNil(preview);
    XCTAssertTrue([preview.stringValue hasPrefix:@"Preview: "],
                  @"Unexpected countdown preview: %@", preview.stringValue);
    XCTAssertTrue([preview.stringValue containsString:@" · "],
                  @"Unexpected countdown preview: %@", preview.stringValue);
    XCTAssertNotNil([controller valueForKey:@"countdownPreviewTimer"]);

    [controller cancelOperation:nil];
    XCTAssertNil([controller valueForKey:@"countdownPreviewTimer"]);
}

- (void)testEditorsPresentWebUnitsWhileKeepingStableStorageIdentifiers {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *intro = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"intro");
    [controller openEditor:intro];
    NSTextField *startDelay = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"startDelayMs-seconds");
    NSTextField *hold = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"holdMs-seconds");
    XCTAssertTrue([startDelay isKindOfClass:NSTextField.class]);
    XCTAssertTrue([hold isKindOfClass:NSTextField.class]);
    XCTAssertEqualWithAccuracy(startDelay.doubleValue, 0.6, 0.001);
    XCTAssertEqualWithAccuracy(hold.doubleValue, 2.8, 0.001);
}

- (void)testIntroAndMessagesEditorsShareCompleteDynamicTokenGuidance {
    [self.preferences commitValues:@{
        @"mx-countdown": @"{\"moments\":[{\"name\":\"launch\",\"targetMs\":1700000000000}]}",
    }];
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];

    [controller openEditorKind:@"intro"];
    NSTextField *introHint = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"intro-token-hint");
    XCTAssertNotNil(introHint);
    XCTAssertTrue([introHint.toolTip containsString:@"{countdown:launch}"]);
    XCTAssertTrue([introHint.toolTip containsString:@"PARTY ON (00:00–03:59)"]);
    XCTAssertTrue([introHint.toolTip containsString:@"newmoon, fullmoon"]);
    XCTAssertTrue([introHint.toolTip containsString:@"{countup:…}"]);

    [controller openEditorKind:@"messages"];
    NSTextField *messagesHint = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"messages-token-hint");
    XCTAssertNotNil(messagesHint);
    XCTAssertEqualObjects(messagesHint.toolTip, introHint.toolTip);
}

- (void)testMessagesEditorPersistsDropLayoutAndRelabelsAxisControls {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *messages = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"messages");
    [controller openEditor:messages];
    NSView *card = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-messages");
    NSPopUpButton *layout = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(card, @"messageLayout");
    NSPopUpButton *direction = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(card, @"messageDirection");
    XCTAssertTrue([layout isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([direction isKindOfClass:NSPopUpButton.class]);
    XCTAssertEqualObjects([layout.itemArray valueForKey:@"representedObject"], (@[@"row", @"drop"]));
    XCTAssertFalse(direction.enabled);
    XCTAssertTrue(MatrixCodeContainsLabel(card, @"Vertical position (%)"));

    MatrixCodeSelectRepresentedValue(layout, @"drop");
    [controller messageChoiceChanged:layout];
    card = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-messages");
    direction = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(card, @"messageDirection");
    XCTAssertTrue(direction.enabled);
    XCTAssertTrue(MatrixCodeContainsLabel(card, @"Horizontal position (%)"));
    XCTAssertTrue(MatrixCodeContainsLabel(card, @"Horizontal randomness (%)"));

    MatrixCodeSelectRepresentedValue(direction, @"bottomToTop");
    [controller messageChoiceChanged:direction];
    NSDictionary *stored = MatrixCodeJSONDictionary([controller serializedValues][@"mx-messages"]);
    XCTAssertEqualObjects(stored[@"messageLayout"], @"drop");
    XCTAssertEqualObjects(stored[@"messageDirection"], @"bottomToTop");
}

- (void)testMessagesEditorSanitizesInvalidLayoutChoicesToWebDefaults {
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"NEO"],
        @"messageLayout": @"diagonal",
        @"messageDirection": @"sideways",
    };
    [self.preferences commitValues:@{@"mx-messages": MatrixCodeJSONString(messages)}];

    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSDictionary *stored = MatrixCodeJSONDictionary([controller serializedValues][@"mx-messages"]);
    XCTAssertEqualObjects(stored[@"messageLayout"], @"row");
    XCTAssertEqualObjects(stored[@"messageDirection"], @"topToBottom");
}

- (void)testImagesEditorPersistsImportedMasksAndTimingControls {
    const uint8_t bytes[] = {0, 64, 128, 255};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSDictionary *images = @{
        @"enabled": @YES,
        @"frequencyMs": @250,
        @"persistenceMs": @1200,
        @"appearMs": @300,
        @"disappearMs": @400,
        @"flickerOut": @NO,
        @"brightnessFade": @YES,
        @"imageScale": @0.4,
        @"imagePlacementJitter": @0.2,
        @"images": @[
            @{@"name": @"Signal", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 2", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 3", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 4", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 5", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 6", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 7", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 8", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 9", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
            @{@"name": @"Signal 10", @"width": @2, @"height": @2,
              @"data": [mask base64EncodedStringWithOptions:0]},
        ],
    };
    [self.preferences commitValues:@{@"mx-images": MatrixCodeJSONString(images)}];

    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"images");
    [controller openEditor:open];
    NSView *card = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-images");
    XCTAssertNotNil(card);
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(card, @"imageName"));
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(card, @"imageScale-percent"));
    XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(card, @"imagePlacementJitter-percent"));
    XCTAssertTrue(MatrixCodeContainsLabel(card, @"Screen width (%)"));
    XCTAssertTrue(MatrixCodeContainsLabel(card, @"Placement randomness (%)"));

    NSTextField *scale = (NSTextField *)MatrixCodeDescendantWithIdentifier(card, @"imageScale-percent");
    scale.doubleValue = 85;
    [controller imageNumberChanged:scale];
    NSTextField *jitter = (NSTextField *)MatrixCodeDescendantWithIdentifier(card, @"imagePlacementJitter-percent");
    jitter.doubleValue = 60;
    [controller imageNumberChanged:jitter];

    NSDictionary *stored = MatrixCodeJSONDictionary([controller serializedValues][@"mx-images"]);
    XCTAssertEqual([stored[@"enabled"] boolValue], YES);
    XCTAssertEqualWithAccuracy([stored[@"frequencyMs"] doubleValue], 500, 0.001);
    XCTAssertEqualWithAccuracy([stored[@"imageScale"] doubleValue], 0.85, 0.001);
    XCTAssertEqualWithAccuracy([stored[@"imagePlacementJitter"] doubleValue], 0.6, 0.001);
    NSArray *storedImages = stored[@"images"];
    XCTAssertEqual(storedImages.count, (NSUInteger)10);
    XCTAssertEqualObjects(storedImages.firstObject[@"name"], @"Signal");
    XCTAssertEqualObjects(storedImages.firstObject[@"data"], [mask base64EncodedStringWithOptions:0]);
}

- (void)testImagesEditorMaxVisibilityButtonSetsOnlyVisibilityControls {
    const uint8_t bytes[] = {0, 255, 255, 0};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSDictionary *images = @{
        @"enabled": @NO,
        @"frequencyMs": @9000,
        @"persistenceMs": @3000,
        @"appearMs": @2000,
        @"disappearMs": @2000,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
        @"imageScale": @0.25,
        @"imagePlacementJitter": @0.75,
        @"images": @[@{@"name": @"Keep Me", @"width": @2, @"height": @2,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
    };
    NSDictionary *controls = @{
        @"density": @5,
        @"rampUpMs": @30000,
        @"trailLength": @0.1,
        @"trailVariation": @1,
        @"speed": @2.5,
        @"glyphScale": @3,
        @"glow": @2,
        @"leadBrightness": @2.5,
        @"vignette": @0.8,
        @"scanlines": @YES,
        @"allowOverlap": @YES,
        @"quality": @"low",
        @"glyphMode": @"matrix",
        @"glyphFont": @"matrix",
        @"glyphRate": @5,
        @"mirror": @YES,
        @"preset": @"amber",
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"KEEP"],
        @"frequencyMs": @2222,
        @"persistenceMs": @3333,
    };
    [self.preferences commitValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-images": MatrixCodeJSONString(images),
        @"mx-messages": MatrixCodeJSONString(messages),
    }];

    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"images");
    [controller openEditor:open];
    NSView *card = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-images");
    NSButton *button = (NSButton *)MatrixCodeDescendantWithIdentifier(card, @"imageMaxVisibility");
    XCTAssertNotNil(button);
    XCTAssertEqualObjects(button.title, @"MAX VISIBILITY");
    [button performClick:nil];

    NSDictionary *storedImages = MatrixCodeJSONDictionary([controller serializedValues][@"mx-images"]);
    NSDictionary *storedControls = MatrixCodeJSONDictionary([controller serializedValues][@"mx-controls"]);
    NSDictionary *storedMessages = MatrixCodeJSONDictionary([controller serializedValues][@"mx-messages"]);
    XCTAssertEqual([storedImages[@"enabled"] boolValue], YES);
    XCTAssertEqualWithAccuracy([storedImages[@"frequencyMs"] doubleValue], 500, 0.001);
    XCTAssertEqualWithAccuracy([storedImages[@"persistenceMs"] doubleValue], 60000, 0.001);
    XCTAssertEqualWithAccuracy([storedImages[@"appearMs"] doubleValue], 0, 0.001);
    XCTAssertEqualWithAccuracy([storedImages[@"disappearMs"] doubleValue], 0, 0.001);
    XCTAssertEqual([storedImages[@"flickerOut"] boolValue], NO);
    XCTAssertEqual([storedImages[@"brightnessFade"] boolValue], NO);
    XCTAssertEqualWithAccuracy([storedImages[@"imageScale"] doubleValue], 1, 0.001);
    XCTAssertEqualWithAccuracy([storedImages[@"imagePlacementJitter"] doubleValue], 0, 0.001);
    XCTAssertEqualObjects([storedImages[@"images"] firstObject][@"name"], @"Keep Me");

    XCTAssertEqualWithAccuracy([storedControls[@"density"] doubleValue], 90, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"rampUpMs"] doubleValue], 0, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"trailLength"] doubleValue], 0.45, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"trailVariation"] doubleValue], 0.2, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"speed"] doubleValue], 0.6, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"glyphScale"] doubleValue], 0.7, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"glow"] doubleValue], 0.6, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"leadBrightness"] doubleValue], 1, 0.001);
    XCTAssertEqualWithAccuracy([storedControls[@"vignette"] doubleValue], 0, 0.001);
    XCTAssertEqual([storedControls[@"scanlines"] boolValue], NO);
    XCTAssertEqual([storedControls[@"allowOverlap"] boolValue], NO);
    XCTAssertEqualObjects(storedControls[@"quality"], @"high");
    XCTAssertEqualObjects(storedControls[@"glyphMode"], @"latin");
    XCTAssertEqualObjects(storedControls[@"glyphFont"], @"mono");
    XCTAssertEqualWithAccuracy([storedControls[@"glyphRate"] doubleValue], 1, 0.001);
    XCTAssertEqual([storedControls[@"mirror"] boolValue], NO);
    XCTAssertEqualObjects(storedControls[@"preset"], @"amber");
    XCTAssertEqualObjects(storedMessages[@"messages"], (@[@"KEEP"]));

    NSView *updatedCard = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-images");
    NSTextField *scale = (NSTextField *)MatrixCodeDescendantWithIdentifier(updatedCard,
                                                                            @"imageScale-percent");
    XCTAssertEqualWithAccuracy(scale.doubleValue, 100, 0.001);
}

- (void)testCharacterTabContainsGlyphSettings {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"characters");
    [controller openEditor:open];
    NSView *characters = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-characters");
    NSPopUpButton *glyphMode = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphMode");
    NSPopUpButton *glyphFont = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphFont");
    NSSlider *glyphRate = (NSSlider *)MatrixCodeDescendantWithIdentifier(characters, @"glyphRate");
    NSButton *mirror = (NSButton *)MatrixCodeDescendantWithIdentifier(characters, @"mirror");
    NSView *previewCard = MatrixCodeDescendantWithIdentifier(characters, @"settings-character-preview");
    MatrixCodeMetalView *preview = (MatrixCodeMetalView *)MatrixCodeDescendantWithIdentifier(
        characters, @"settings-character-preview-rain");
    XCTAssertTrue([glyphMode isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([glyphFont isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([glyphRate isKindOfClass:NSSlider.class]);
    XCTAssertTrue([mirror isKindOfClass:NSButton.class]);
    XCTAssertTrue([previewCard isKindOfClass:NSView.class]);
    XCTAssertTrue([preview isKindOfClass:MatrixCodeMetalView.class]);
    XCTAssertTrue(preview.isPaused);
    NSArray<NSNumber *> *firstPreviewSnapshot =
        [preview diagnosticGlyphStateSnapshotWithWidth:508 height:190];
    NSArray<NSNumber *> *secondPreviewSnapshot =
        [preview diagnosticGlyphStateSnapshotWithWidth:508 height:190];
    XCTAssertEqualObjects(firstPreviewSnapshot, secondPreviewSnapshot);
    XCTAssertEqualObjects([glyphMode.itemArray valueForKey:@"title"],
                          (@[@"Matrix mix", @"Katakana", @"Binary", @"Digits", @"Latin", @"Symbols"]));
    XCTAssertEqualObjects([glyphMode.itemArray valueForKey:@"representedObject"],
                          (@[@"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols"]));
    XCTAssertEqualObjects([glyphFont.itemArray valueForKey:@"title"],
                          (@[@"Movie Gothic", @"Sharp Gothic", @"SF Mono",
                             @"Terminal Mono", @"Rounded", @"Mincho"]));
    XCTAssertEqualObjects([glyphFont.itemArray valueForKey:@"representedObject"],
                          (@[@"matrix", @"gothic", @"mono", @"terminal", @"rounded", @"mincho"]));
}

- (void)testGlyphModeSelectionImmediatelyRefreshesRenderedBackgroundRainGlyphs {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    MatrixCodeMetalView *background = [controller valueForKey:@"settingsMetalView"];
    XCTAssertTrue([background isKindOfClass:MatrixCodeMetalView.class]);
    id originalAtlas = [background valueForKey:@"atlas"];
    XCTAssertNotNil(originalAtlas);

    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"characters");
    [controller openEditor:open];
    NSView *characters = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-characters");
    NSPopUpButton *glyphMode = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphMode");
    MatrixCodeSelectRepresentedValue(glyphMode, @"binary");
    [controller controlChanged:glyphMode];

    NSDictionary<NSString *, id> *binaryControls = [background valueForKey:@"controls"];
    XCTAssertEqualObjects(binaryControls[@"glyphMode"], @"binary");
    XCTAssertNotEqual(originalAtlas, [background valueForKey:@"atlas"]);
    NSInteger rainGlyphCount = MatrixCodeRainGlyphCount();
    for (NSInteger index = 0; index < rainGlyphCount; index++) {
        NSString *glyph = [MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"?"
                                                                              index:index
                                                                     rainGlyphCount:rainGlyphCount
                                                                           controls:binaryControls];
        XCTAssertTrue(([@[@"0", @"1"] containsObject:glyph]),
                      @"Unexpected rendered binary glyph %@ at index %ld", glyph, (long)index);
    }
}

- (void)testRainPopupsUseWebLabelsAndPersistStableValues {
    __block NSDictionary<NSString *, NSString *> *previewValues = nil;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodePreviewValuesDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        previewValues = notification.userInfo[MatrixCodePreviewValuesKey];
    }];
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSView *rain = MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                      @"settings-panel");
    NSPopUpButton *preset = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(rain, @"preset");
    NSPopUpButton *quality = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(rain, @"quality");

    XCTAssertEqualObjects([preset.itemArray valueForKey:@"title"],
                          (@[@"Green (Classic)", @"Amber", @"Gold", @"Red",
                             @"Pink", @"Purple", @"Blue", @"White"]));
    XCTAssertEqualObjects([quality.itemArray valueForKey:@"title"],
                          (@[@"Low", @"Medium", @"High"]));

    MatrixCodeSelectRepresentedValue(preset, @"amber");
    [controller controlChanged:preset];
    MatrixCodeSelectRepresentedValue(quality, @"med");
    [controller controlChanged:quality];

    NSData *data = [previewValues[@"mx-controls"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *controls = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(controls[@"preset"], @"amber");
    XCTAssertEqualObjects(controls[@"quality"], @"med");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testGlyphModeSelectionAppliesPreferredMirrorState {
    __block NSDictionary<NSString *, NSString *> *previewValues = nil;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodePreviewValuesDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        previewValues = notification.userInfo[MatrixCodePreviewValuesKey];
    }];
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"characters");
    [controller openEditor:open];
    NSView *characters = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-characters");
    NSPopUpButton *glyphMode = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphMode");
    NSButton *mirror = (NSButton *)MatrixCodeDescendantWithIdentifier(characters, @"mirror");
    XCTAssertTrue([glyphMode isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([mirror isKindOfClass:NSButton.class]);
    NSDictionary<NSString *, NSNumber *> *expected = @{
        @"matrix": @YES,
        @"katakana": @YES,
        @"binary": @NO,
        @"digits": @NO,
        @"latin": @NO,
        @"symbols": @NO,
    };

    for (NSString *mode in @[@"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols"]) {
        BOOL expectedMirror = [expected[mode] boolValue];
        mirror.state = expectedMirror ? NSControlStateValueOff : NSControlStateValueOn;
        [controller controlChanged:mirror];

        MatrixCodeSelectRepresentedValue(glyphMode, mode);
        XCTAssertEqualObjects(glyphMode.selectedItem.representedObject, mode);
        [controller controlChanged:glyphMode];

        XCTAssertEqual(mirror.state == NSControlStateValueOn, expectedMirror, @"%@", mode);
        NSData *data = [previewValues[@"mx-controls"] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *controls = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        XCTAssertEqualObjects(controls[@"glyphMode"], mode);
        XCTAssertEqual([controls[@"mirror"] boolValue], expectedMirror, @"%@", mode);
    }
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testRainSliderPublishesDraftToLivePreview {
    __block NSDictionary<NSString *, NSString *> *previewValues = nil;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:MatrixCodePreviewValuesDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        previewValues = notification.userInfo[MatrixCodePreviewValuesKey];
    }];
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"speed");
    speed.doubleValue = 2.25;
    [speed sendAction:speed.action to:speed.target];

    XCTAssertNotNil(previewValues);
    NSData *data = [previewValues[@"mx-controls"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *controls = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 2.25, 0.001);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testEditorMoveActionsIgnoreInvalidSourceTags {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSMutableArray *introLines = [@[
        [@{@"text": @"wake", @"holdMs": @2800, @"pauseMs": @0} mutableCopy],
        [@{@"text": @"up", @"holdMs": @2800, @"pauseMs": @0} mutableCopy],
    ] mutableCopy];
    NSMutableArray *messageLines = [@[@"NEO", @"TRINITY"] mutableCopy];
    NSMutableArray *imageItems = [@[
        [@{@"name": @"one", @"width": @1, @"height": @1, @"data": @"AA=="} mutableCopy],
        [@{@"name": @"two", @"width": @1, @"height": @1, @"data": @"AA=="} mutableCopy],
    ] mutableCopy];
    NSMutableArray *moments = [@[
        [@{@"name": @"one", @"targetMs": NSNull.null} mutableCopy],
        [@{@"name": @"two", @"targetMs": NSNull.null} mutableCopy],
    ] mutableCopy];
    [controller setValue:introLines forKey:@"introLines"];
    [controller setValue:messageLines forKey:@"messageLines"];
    [controller setValue:imageItems forKey:@"imageItems"];
    [controller setValue:moments forKey:@"moments"];

    NSButton *introMove = [NSButton buttonWithTitle:@"" target:nil action:nil];
    introMove.identifier = @"up";
    introMove.tag = introLines.count;
    XCTAssertNoThrow([controller moveIntroLine:introMove]);
    XCTAssertEqualObjects([controller valueForKey:@"introLines"], introLines);

    NSButton *messageMove = [NSButton buttonWithTitle:@"" target:nil action:nil];
    messageMove.identifier = @"up";
    messageMove.tag = messageLines.count;
    XCTAssertNoThrow([controller moveMessage:messageMove]);
    XCTAssertEqualObjects([controller valueForKey:@"messageLines"], messageLines);

    NSButton *imageMove = [NSButton buttonWithTitle:@"" target:nil action:nil];
    imageMove.identifier = @"up";
    imageMove.tag = imageItems.count;
    XCTAssertNoThrow([controller moveImage:imageMove]);
    XCTAssertEqualObjects([controller valueForKey:@"imageItems"], imageItems);

    NSButton *momentMove = [NSButton buttonWithTitle:@"" target:nil action:nil];
    momentMove.identifier = @"up";
    momentMove.tag = moments.count;
    XCTAssertNoThrow([controller moveMoment:momentMove]);
    XCTAssertEqualObjects([controller valueForKey:@"moments"], moments);
}

@end
