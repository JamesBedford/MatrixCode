#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodePreferences.h"

@interface MatrixCodeConfigurationController (Testing)
- (void)controlChanged:(id)sender;
- (void)openEditor:(NSButton *)sender;
- (void)setSettingsPanelVisible:(BOOL)visible immediate:(BOOL)immediate;
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
    for (NSString *identifier in @[@"characters", @"intro", @"messages", @"countdowns",
                                    @"reset-controls"]) {
        XCTAssertNotNil(MatrixCodeDescendantWithIdentifier(panel, identifier), @"%@", identifier);
    }
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-cancel"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-save"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(panel, @"settings-hint"));
    XCTAssertNil(MatrixCodeDescendantWithIdentifier(controller.window.contentView,
                                                    @"ambient-title"));
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
    for (NSString *kind in @[@"characters", @"intro", @"messages", @"countdowns"]) {
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

@end
