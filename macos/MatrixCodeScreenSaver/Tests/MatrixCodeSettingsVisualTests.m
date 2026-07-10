#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodeSettingsTheme.h"

@interface MatrixCodeConfigurationController (VisualTesting)
- (void)presentEditorKind:(NSString *)kind;
- (void)rebuildConfigurationInterface;
@end

static NSView *MatrixCodeVisualDescendant(NSView *view, NSString *identifier) {
    if ([view.identifier isEqualToString:identifier]) return view;
    for (NSView *subview in view.subviews) {
        NSView *match = MatrixCodeVisualDescendant(subview, identifier);
        if (match) return match;
    }
    return nil;
}

static NSBitmapImageRep *MatrixCodeRenderView(NSView *view) {
    [view layoutSubtreeIfNeeded];
    [view displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    if (!bitmap) return nil;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    return bitmap;
}

static NSColor *MatrixCodeDeviceRGBColor(NSColor *color) {
    return [color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
}

static NSColor *MatrixCodeLayerColor(CGColorRef color) {
    return color ? MatrixCodeDeviceRGBColor([NSColor colorWithCGColor:color]) : nil;
}

static BOOL MatrixCodeColorIsGreenAccent(NSColor *color) {
    NSColor *rgb = MatrixCodeDeviceRGBColor(color);
    return rgb && rgb.greenComponent > 0.35 &&
        rgb.greenComponent > rgb.redComponent * 1.35 &&
        rgb.greenComponent > rgb.blueComponent * 1.15;
}

static NSUInteger MatrixCodeDistinctOpaqueColors(NSBitmapImageRep *bitmap,
                                                  NSUInteger *greenPixelCount) {
    NSMutableSet<NSNumber *> *colors = [NSMutableSet set];
    NSUInteger green = 0;
    NSInteger width = bitmap.pixelsWide;
    NSInteger height = bitmap.pixelsHigh;
    for (NSInteger y = 0; y < height; y += 2) {
        for (NSInteger x = 0; x < width; x += 2) {
            NSColor *color = MatrixCodeDeviceRGBColor([bitmap colorAtX:x y:y]);
            if (!color || color.alphaComponent < 0.05) continue;
            NSUInteger red = (NSUInteger)lrint(color.redComponent * 31);
            NSUInteger greenChannel = (NSUInteger)lrint(color.greenComponent * 31);
            NSUInteger blue = (NSUInteger)lrint(color.blueComponent * 31);
            [colors addObject:@((red << 10) | (greenChannel << 5) | blue)];
            if (MatrixCodeColorIsGreenAccent(color)) green++;
        }
    }
    if (greenPixelCount) *greenPixelCount = green;
    return colors.count;
}

static NSUInteger MatrixCodeGreenPixelsAlongBorder(NSBitmapImageRep *bitmap) {
    NSUInteger count = 0;
    NSInteger width = bitmap.pixelsWide;
    NSInteger height = bitmap.pixelsHigh;
    NSInteger band = MAX(2, MIN(width, height) / 150);
    for (NSInteger y = 0; y < height; y++) {
        for (NSInteger x = 0; x < width; x++) {
            if (x >= band && x < width - band && y >= band && y < height - band) continue;
            if (MatrixCodeColorIsGreenAccent([bitmap colorAtX:x y:y])) count++;
        }
    }
    return count;
}

@interface MatrixCodeSettingsVisualTests : XCTestCase
@property(nonatomic, strong) NSMutableArray<MatrixCodeConfigurationController *> *controllers;
@end

@implementation MatrixCodeSettingsVisualTests

- (void)setUp {
    [super setUp];
    self.controllers = [NSMutableArray array];
}

- (void)tearDown {
    for (MatrixCodeConfigurationController *controller in self.controllers) {
        NSTimer *timer = [controller valueForKey:@"settingsAnimationTimer"];
        [timer invalidate];
        MatrixCodeMetalView *metalView = [controller valueForKey:@"settingsMetalView"];
        [metalView setAnimationActive:NO];
        [controller close];
    }
    self.controllers = nil;
    [super tearDown];
}

- (MatrixCodeConfigurationController *)controllerWithContentSize:(NSSize)size {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    NSMutableDictionary *controls = [controller valueForKey:@"controls"];
    controls[@"preset"] = @"classic";
    [controller rebuildConfigurationInterface];
    controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [controller.window setContentSize:size];
    [controller.window.contentView layoutSubtreeIfNeeded];
    [controller.window.contentView displayIfNeeded];
    [self.controllers addObject:controller];
    return controller;
}

- (void)testPrimaryPanelRendersWithMatrixPaletteAtDefaultAndMinimumSizes {
    NSArray<NSValue *> *sizes = @[
        [NSValue valueWithSize:NSMakeSize(920, 700)],
        [NSValue valueWithSize:NSMakeSize(700, 560)],
    ];
    for (NSValue *sizeValue in sizes) {
        NSSize size = sizeValue.sizeValue;
        MatrixCodeConfigurationController *controller =
            [self controllerWithContentSize:size];
        NSView *content = controller.window.contentView;
        NSView *panel = MatrixCodeVisualDescendant(content, @"settings-panel");
        XCTAssertNotNil(panel, @"Missing primary settings panel at %@", sizeValue);
        XCTAssertNotNil(MatrixCodeVisualDescendant(content, @"settings-rain-backdrop"));
        XCTAssertNotNil(MatrixCodeVisualDescendant(panel, @"settings-title"));

        XCTAssertEqualWithAccuracy(panel.frame.origin.x, 16, 0.5);
        XCTAssertEqualWithAccuracy(panel.frame.origin.y, 16, 0.5);
        XCTAssertEqualWithAccuracy(panel.frame.size.width, 320, 0.5);
        XCTAssertEqualWithAccuracy(panel.frame.size.height, size.height - 32, 0.5);
        XCTAssertTrue(NSContainsRect(content.bounds, panel.frame));
        XCTAssertTrue([panel isKindOfClass:MatrixCodeSettingsPanelView.class]);
        XCTAssertFalse(((MatrixCodeSettingsPanelView *)panel).modal);

        NSColor *background = MatrixCodeLayerColor(content.layer.backgroundColor);
        XCTAssertNotNil(background);
        XCTAssertEqualWithAccuracy(background.redComponent, 0.051, 0.015);
        XCTAssertEqualWithAccuracy(background.greenComponent, 0.008, 0.015);
        XCTAssertEqualWithAccuracy(background.blueComponent, 0.031, 0.015);
        NSColor *border = MatrixCodeSettingsTheme.sharedTheme.borderColor;
        XCTAssertTrue(MatrixCodeColorIsGreenAccent(border));
        XCTAssertGreaterThan(border.alphaComponent, 0.25);

        NSBitmapImageRep *bitmap = MatrixCodeRenderView(panel);
        XCTAssertNotNil(bitmap);
        XCTAssertGreaterThan(bitmap.pixelsWide, 250);
        XCTAssertGreaterThan(bitmap.pixelsHigh, 400);
        NSUInteger greenPixels = 0;
        NSUInteger distinctColors = MatrixCodeDistinctOpaqueColors(bitmap, &greenPixels);
        XCTAssertGreaterThan(distinctColors, 12,
                             @"Offscreen panel render appears blank at %@", sizeValue);
        XCTAssertGreaterThan(greenPixels, 20,
                             @"Offscreen panel render lost its green accent at %@", sizeValue);
        XCTAssertGreaterThan(MatrixCodeGreenPixelsAlongBorder(bitmap), 20,
                             @"Drawn panel border lost its accent at %@", sizeValue);
    }
}

- (void)testIntroEditorCardRendersWithoutObviousClippingAtDefaultAndMinimumSizes {
    NSArray<NSValue *> *sizes = @[
        [NSValue valueWithSize:NSMakeSize(920, 700)],
        [NSValue valueWithSize:NSMakeSize(700, 560)],
    ];
    for (NSValue *sizeValue in sizes) {
        NSSize size = sizeValue.sizeValue;
        MatrixCodeConfigurationController *controller =
            [self controllerWithContentSize:size];
        [controller presentEditorKind:@"intro"];
        NSView *content = controller.window.contentView;
        [content layoutSubtreeIfNeeded];

        NSView *backdrop = MatrixCodeVisualDescendant(content, @"settings-editor-backdrop");
        NSView *card = MatrixCodeVisualDescendant(content, @"settings-editor-card-intro");
        XCTAssertNotNil(backdrop);
        XCTAssertNotNil(card);
        XCTAssertTrue(NSEqualRects(backdrop.frame, content.bounds));
        XCTAssertTrue(NSContainsRect(backdrop.bounds, card.frame),
                      @"Editor card escapes its backdrop at %@", sizeValue);
        XCTAssertEqualWithAccuracy(card.frame.size.width, 620, 0.5);
        XCTAssertLessThanOrEqual(card.frame.size.height, size.height - 48 + 0.5);
        XCTAssertGreaterThanOrEqual(NSMinX(card.frame), 24);
        XCTAssertGreaterThanOrEqual(NSMinY(card.frame), 24);
        XCTAssertTrue([card isKindOfClass:MatrixCodeSettingsPanelView.class]);
        XCTAssertTrue(((MatrixCodeSettingsPanelView *)card).modal);
        XCTAssertTrue(MatrixCodeColorIsGreenAccent(
            MatrixCodeSettingsTheme.sharedTheme.borderColor));

        for (NSString *identifier in @[@"editor-reset", @"editor-cancel", @"editor-save"]) {
            NSView *button = MatrixCodeVisualDescendant(card, identifier);
            XCTAssertNotNil(button, @"Missing %@ at %@", identifier, sizeValue);
            NSRect frameInCard = [button.superview convertRect:button.frame toView:card];
            XCTAssertTrue(NSContainsRect(card.bounds, frameInCard),
                          @"%@ is clipped outside the editor card at %@", identifier, sizeValue);
        }

        NSBitmapImageRep *bitmap = MatrixCodeRenderView(card);
        XCTAssertNotNil(bitmap);
        NSUInteger greenPixels = 0;
        NSUInteger distinctColors = MatrixCodeDistinctOpaqueColors(bitmap, &greenPixels);
        XCTAssertGreaterThan(distinctColors, 12,
                             @"Offscreen editor render appears blank at %@", sizeValue);
        XCTAssertGreaterThan(greenPixels, 20,
                             @"Offscreen editor render lost its green accent at %@", sizeValue);
        XCTAssertGreaterThan(MatrixCodeGreenPixelsAlongBorder(bitmap), 20,
                             @"Drawn editor border lost its accent at %@", sizeValue);
    }
}

- (void)testCharacterEditorKeepsGlyphControlsInsideCardAndShowsPreview {
    NSArray<NSValue *> *sizes = @[
        [NSValue valueWithSize:NSMakeSize(920, 700)],
        [NSValue valueWithSize:NSMakeSize(700, 560)],
    ];
    for (NSValue *sizeValue in sizes) {
        NSSize size = sizeValue.sizeValue;
        MatrixCodeConfigurationController *controller =
            [self controllerWithContentSize:size];
        [controller presentEditorKind:@"characters"];
        NSView *content = controller.window.contentView;
        [content layoutSubtreeIfNeeded];

        NSView *card = MatrixCodeVisualDescendant(content, @"settings-editor-card-characters");
        NSSlider *glyphRate = (NSSlider *)MatrixCodeVisualDescendant(card, @"glyphRate");
        NSView *preview = MatrixCodeVisualDescendant(card, @"settings-character-preview");
        NSView *previewRain = MatrixCodeVisualDescendant(card, @"settings-character-preview-rain");
        XCTAssertNotNil(card);
        XCTAssertTrue([glyphRate isKindOfClass:NSSlider.class]);
        XCTAssertNotNil(preview);
        XCTAssertTrue([previewRain isKindOfClass:MatrixCodeMetalView.class]);

        NSRect cardInset = NSInsetRect(card.bounds, 16, 16);
        NSRect sliderFrame = [glyphRate.superview convertRect:glyphRate.frame toView:card];
        NSRect previewFrame = [preview.superview convertRect:preview.frame toView:card];
        XCTAssertTrue(NSContainsRect(cardInset, sliderFrame),
                      @"Glyph change slider clips against the Characters card at %@", sizeValue);
        XCTAssertTrue(NSContainsRect(cardInset, previewFrame),
                      @"Rain preview clips against the Characters card at %@", sizeValue);
        XCTAssertLessThanOrEqual(NSMaxX(sliderFrame), NSWidth(card.bounds) - 20 + 0.5);

        NSBitmapImageRep *bitmap = MatrixCodeRenderView(card);
        XCTAssertNotNil(bitmap);
        NSUInteger greenPixels = 0;
        NSUInteger distinctColors = MatrixCodeDistinctOpaqueColors(bitmap, &greenPixels);
        XCTAssertGreaterThan(distinctColors, 12,
                             @"Offscreen Characters editor render appears blank at %@", sizeValue);
        XCTAssertGreaterThan(greenPixels, 20,
                             @"Characters editor render lost its green accent at %@", sizeValue);
    }
}

@end
