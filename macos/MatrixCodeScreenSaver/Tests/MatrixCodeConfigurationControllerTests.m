#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"

@interface MatrixCodeConfigurationController (Testing)
- (void)controlChanged:(id)sender;
@end

static NSView *MatrixCodeDescendantWithIdentifier(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *subview in view.subviews) {
        NSView *match = MatrixCodeDescendantWithIdentifier(subview, identifier);
        if (match) return match;
    }
    return nil;
}

@interface MatrixCodeConfigurationControllerTests : XCTestCase
@end

@implementation MatrixCodeConfigurationControllerTests

- (void)testNativeConfigurationSheetBuildsAllFeatureTabs {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    XCTAssertNotNil(controller.window);
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    XCTAssertNotNil(tabs);
    XCTAssertEqual(tabs.numberOfTabViewItems, 5);
    XCTAssertEqualObjects([tabs.tabViewItems valueForKey:@"label"],
                          (@[@"Rain", @"Characters", @"Intro", @"Messages", @"Countdowns"]));
}

- (void)testEveryFeatureTabStartsAtTopOfItsForm {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    XCTAssertNotNil(tabs);
    [controller.window.contentView layoutSubtreeIfNeeded];

    for (NSTabViewItem *item in tabs.tabViewItems) {
        [tabs selectTabViewItem:item];
        NSScrollView *scroll = [item.view isKindOfClass:NSScrollView.class]
            ? (NSScrollView *)item.view : nil;
        XCTAssertNotNil(scroll, @"%@ should use a scroll view", item.label);
        [scroll layoutSubtreeIfNeeded];
        XCTAssertTrue(scroll.documentView.isFlipped,
                      @"%@ should use a top-origin document view", item.label);
        XCTAssertEqualWithAccuracy(scroll.contentView.bounds.origin.y, 0, 0.001,
                                   @"%@ should initially show its first controls", item.label);
    }
}

- (void)testRainSlidersShowLiveNumericValues {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    NSView *rain = tabs.tabViewItems.firstObject.view;
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

    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(rain, @"speed");
    NSTextField *speedReadout = (NSTextField *)MatrixCodeDescendantWithIdentifier(
        rain, @"speed-value");
    speed.doubleValue = 2.25;
    [speed sendAction:speed.action to:speed.target];
    XCTAssertEqualObjects(speedReadout.stringValue, @"2.25");

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

- (void)testCharacterTabContainsGlyphSettings {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    NSView *characters = tabs.tabViewItems[1].view;
    NSPopUpButton *glyphMode = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphMode");
    NSPopUpButton *glyphFont = (NSPopUpButton *)MatrixCodeDescendantWithIdentifier(characters, @"glyphFont");
    NSSlider *glyphRate = (NSSlider *)MatrixCodeDescendantWithIdentifier(characters, @"glyphRate");
    NSButton *mirror = (NSButton *)MatrixCodeDescendantWithIdentifier(characters, @"mirror");
    XCTAssertTrue([glyphMode isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([glyphFont isKindOfClass:NSPopUpButton.class]);
    XCTAssertTrue([glyphRate isKindOfClass:NSSlider.class]);
    XCTAssertTrue([mirror isKindOfClass:NSButton.class]);
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
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    NSView *characters = tabs.tabViewItems[1].view;
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

        [glyphMode selectItemWithTitle:mode];
        XCTAssertEqualObjects(glyphMode.titleOfSelectedItem, mode);
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
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    NSSlider *speed = (NSSlider *)MatrixCodeDescendantWithIdentifier(
        tabs.tabViewItems.firstObject.view, @"speed");
    speed.doubleValue = 2.25;
    [speed sendAction:speed.action to:speed.target];

    XCTAssertNotNil(previewValues);
    NSData *data = [previewValues[@"mx-controls"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *controls = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 2.25, 0.001);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

@end
