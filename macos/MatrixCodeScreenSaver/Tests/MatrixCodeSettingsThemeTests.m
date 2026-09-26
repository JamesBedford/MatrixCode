#import <XCTest/XCTest.h>

#import "MatrixCodeSettingsTheme.h"

@interface MatrixCodeSettingsThemeTests : XCTestCase
@end

@implementation MatrixCodeSettingsThemeTests

- (void)setUp {
    [super setUp];
    [MatrixCodeSettingsTheme.sharedTheme refreshColorsAtDate:[NSDate dateWithTimeIntervalSince1970:0]
                                                  timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
}

- (void)tearDown {
    MatrixCodeSettingsTheme.sharedTheme.presetName = @"classic";
    [super tearDown];
}

- (void)assertColor:(NSColor *)color
                red:(CGFloat)red
              green:(CGFloat)green
               blue:(CGFloat)blue {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(rgb.redComponent, red / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(rgb.greenComponent, green / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(rgb.blueComponent, blue / 255.0, 0.001);
}

- (void)testClassicAndAlternatePresetsMatchWebColors {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    theme.presetName = @"classic";
    [self assertColor:theme.backgroundColor red:13 green:2 blue:8];
    [self assertColor:theme.dimColor red:0 green:143 blue:17];
    [self assertColor:theme.accentColor red:0 green:255 blue:65];

    theme.presetName = @"purple";
    [self assertColor:theme.backgroundColor red:8 green:2 blue:13];
    [self assertColor:theme.dimColor red:110 green:0 blue:168];
    [self assertColor:theme.accentColor red:178 green:59 blue:255];
    NSColor *panel = [theme.panelColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(panel.alphaComponent, 0.82, 0.001);
    [self assertColor:theme.panelColor red:8 green:2 blue:13];

    theme.presetName = @"gold";
    [self assertColor:theme.backgroundColor red:12 green:8 blue:0];
    [self assertColor:theme.dimColor red:184 green:134 blue:11];
    [self assertColor:theme.accentColor red:255 green:215 blue:0];

    [theme applyControls:@{ @"preset": @"custom", @"customColor": @"#ff6600" }];
    [self assertColor:theme.backgroundColor red:13 green:5 blue:0];
    [self assertColor:theme.dimColor red:168 green:67 blue:0];
    [self assertColor:theme.accentColor red:255 green:102 blue:0];

    theme.presetName = @"not-a-preset";
    XCTAssertEqualObjects(theme.presetName, @"classic");
}

- (void)testPresetChangeRestylesRegisteredControlsAndPostsNotification {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    theme.presetName = @"classic";
    NSButton *button = [NSButton buttonWithTitle:@"Save" target:nil action:nil];
    [theme styleButton:button];

    XCTestExpectation *changed =
        [self expectationForNotification:MatrixCodeSettingsThemeDidChangeNotification
                                  object:theme handler:nil];
    theme.presetName = @"amber";
    [self waitForExpectations:@[changed] timeout:0.2];

    NSColor *titleColor = [button.attributedTitle attribute:NSForegroundColorAttributeName
                                                   atIndex:0 effectiveRange:nil];
    [self assertColor:titleColor red:255 green:176 blue:0];
}

- (void)testVisualUppercaseDoesNotLoseAccessibleButtonLabel {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    NSButton *button = [NSButton buttonWithTitle:@"Reset to default" target:nil action:nil];
    button.accessibilityLabel = @"Restore the original rain settings";

    [theme styleButton:button];

    XCTAssertEqualObjects(button.attributedTitle.string, @"RESET TO DEFAULT");
    XCTAssertEqualObjects(button.accessibilityLabel, @"Restore the original rain settings");
}

- (void)testToggleUsesWebOnOffTitlesAndSelectedFill {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    NSButton *toggle = [NSButton buttonWithTitle:@"Scanlines" target:nil action:nil];
    [theme styleToggleButton:toggle on:YES];
    CGColorRef selected = toggle.layer.backgroundColor;

    XCTAssertEqualObjects(toggle.title, @"On");
    XCTAssertEqual(toggle.state, NSControlStateValueOn);
    XCTAssertEqualObjects(toggle.accessibilityLabel, @"Scanlines");

    [theme styleToggleButton:toggle on:NO];
    XCTAssertEqualObjects(toggle.title, @"Off");
    XCTAssertEqual(toggle.state, NSControlStateValueOff);
    XCTAssertNotEqual(selected, toggle.layer.backgroundColor);
}

- (void)testStaticLabelsCannotEnterFieldEditorOrLoseThemeColors {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 120)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSTextField *label = [NSTextField wrappingLabelWithString:@"Horizontal randomness (%)"];
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Randomness applies across the desktop."];
    [window.contentView addSubview:label];
    [window.contentView addSubview:hint];
    [theme styleLabel:label];
    [theme styleHintLabel:hint];

    for (NSString *preset in @[@"gold", @"classic", @"purple"]) {
        theme.presetName = preset;
        for (NSTextField *field in @[label, hint]) {
            XCTAssertFalse(field.isEditable);
            XCTAssertFalse(field.isSelectable);
            XCTAssertFalse(field.acceptsFirstResponder);
            NSAttributedString *before = [field.attributedStringValue copy];
            [field selectText:nil];
            [window makeFirstResponder:field];
            XCTAssertNil(field.currentEditor);
            XCTAssertEqualObjects(field.attributedStringValue, before);
        }
        NSColor *labelColor = [label.attributedStringValue attribute:NSForegroundColorAttributeName
                                                            atIndex:0 effectiveRange:nil];
        XCTAssertEqualObjects(labelColor, theme.labelColor);
        XCTAssertEqualObjects(hint.textColor, [theme.accentColor colorWithAlphaComponent:0.5]);
        XCTAssertEqualObjects(label.accessibilityLabel, @"Horizontal randomness (%)");
    }
    [window close];
}

- (void)testPanelAndCardExposeExpectedGeometry {
    MatrixCodeSettingsPanelView *panel =
        [[MatrixCodeSettingsPanelView alloc] initWithFrame:NSMakeRect(0, 0, 560, 400)];
    panel.modal = YES;
    MatrixCodeSettingsCardView *card =
        [[MatrixCodeSettingsCardView alloc] initWithFrame:NSMakeRect(0, 0, 500, 60)];

    XCTAssertTrue(panel.wantsLayer);
    XCTAssertTrue(panel.modal);
    XCTAssertFalse(panel.isOpaque);
    XCTAssertTrue(card.wantsLayer);
    XCTAssertFalse(card.isOpaque);
}

@end
