#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"

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
    XCTAssertEqual(tabs.numberOfTabViewItems, 4);
    XCTAssertEqualObjects([tabs.tabViewItems valueForKey:@"label"],
                          (@[@"Rain", @"Intro", @"Messages", @"Countdowns"]));
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
        @"density", @"rampUpMs", @"trailLength", @"speed", @"glyphRate",
        @"glyphScale", @"glow", @"leadBrightness", @"vignette",
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
