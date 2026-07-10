#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"

@interface MatrixCodeConfigurationController (Testing)
- (void)controlChanged:(id)sender;
- (void)imageNumberChanged:(NSTextField *)sender;
- (void)messageChoiceChanged:(NSPopUpButton *)sender;
- (void)moveIntroLine:(NSButton *)sender;
- (void)moveImage:(NSButton *)sender;
- (void)moveMessage:(NSButton *)sender;
- (void)moveMoment:(NSButton *)sender;
- (void)openEditor:(NSButton *)sender;
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
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-cancel"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-save"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-hint"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                    @"ambient-title"));
}

- (void)testSettingsBackdropUsesMetalDisplayLinkWithoutDuplicateTimer {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    MatrixCodeMetalView *background = [controller valueForKey:@"settingsMetalView"];
    XCTAssertTrue([background isKindOfClass:MatrixCodeMetalView.class]);
    XCTAssertFalse(background.isPaused);
    XCTAssertNil([controller valueForKey:@"settingsAnimationTimer"]);
}

- (void)testStandalonePreviewUsesMetalDisplayLinkWithoutDuplicateTimer {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    [controller showPreviewWithIntro:YES message:NO];
    NSWindowController *previewController = [controller valueForKey:@"previewController"];
    MatrixCodeMetalView *metalView = [previewController valueForKey:@"metalView"];
    XCTAssertTrue([metalView isKindOfClass:MatrixCodeMetalView.class]);
    XCTAssertFalse(metalView.isPaused);
    XCTAssertNil([previewController valueForKey:@"timer"]);
    XCTAssertNotNil(metalView.frameHandler);

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
    XCTAssertEqualWithAccuracy(density.minValue, 0.2, 0.001);
    XCTAssertEqualWithAccuracy(ramp.maxValue, 30000, 0.001);

    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"speed");
    NSTextField *speedReadout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        rain, @"speed-value");
    speed.doubleValue = 2.25;
    [speed sendAction:speed.action to:speed.target];
    XCTAssertEqualObjects(speedReadout.stringValue, @"2.25×");
    XCTAssertEqualWithAccuracy(speed.minValue, 0.2, 0.001);

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

- (void)testGlyphModeSelectionImmediatelyRefreshesBackgroundRainGlyphs {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    MatrixCodeMetalView *background = [controller valueForKey:@"settingsMetalView"];
    XCTAssertTrue([background isKindOfClass:MatrixCodeMetalView.class]);
    [background setDensityScale:1 rainElapsed:18.0];
    NSArray<NSNumber *> *matrixSnapshot =
        [background diagnosticGlyphStateSnapshotWithWidth:420 height:260];
    XCTAssertGreaterThan(matrixSnapshot.count, (NSUInteger)0);
    BOOL sawNonBinaryGlyph = NO;
    NSInteger binaryStart = MatrixCodeRainDigitStartIndex();
    for (NSNumber *glyph in matrixSnapshot) {
        NSInteger value = glyph.integerValue;
        if (value < binaryStart || value > binaryStart + 1) {
            sawNonBinaryGlyph = YES;
            break;
        }
    }
    XCTAssertTrue(sawNonBinaryGlyph);

    NSButton *open = (NSButton *)MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"characters");
    [controller openEditor:open];
    NSView *characters = MatrixCodeDescendantWithIdentifier(
        controller.window.contentView, @"settings-editor-card-characters");
    NSPopUpButton *glyphMode = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphMode");
    MatrixCodeSelectRepresentedValue(glyphMode, @"binary");
    [controller controlChanged:glyphMode];

    [background setDensityScale:1 rainElapsed:18.0];
    NSArray<NSNumber *> *binarySnapshot =
        [background diagnosticGlyphStateSnapshotWithWidth:420 height:260];
    XCTAssertEqual(binarySnapshot.count, matrixSnapshot.count);
    for (NSNumber *glyph in binarySnapshot) {
        NSInteger value = glyph.integerValue;
        XCTAssertTrue(value >= binaryStart && value <= binaryStart + 1,
                      @"Unexpected binary glyph index %@", glyph);
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
