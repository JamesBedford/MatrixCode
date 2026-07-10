#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"
#import "MatrixCodeRainLifecycle.h"

@interface MatrixCodeMetalView (MessageTesting)
- (void)updateMessageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows;
- (void)updateActiveMessageFrameStateAtTime:(NSTimeInterval)now
                            framesPerSecond:(double)framesPerSecond;
- (void)updateImageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows;
- (void)updateActiveImageFrameStateAtTime:(NSTimeInterval)now;
- (double)updateMeasuredFramesPerSecondAtTime:(NSTimeInterval)time;
@end

@interface MatrixCodeMetalViewTests : XCTestCase
@end

@implementation MatrixCodeMetalViewTests

static NSString *MatrixCodeJSONString(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSUInteger MatrixCodeGreenPixelCount(NSData *frame) {
    const uint8_t *pixels = frame.bytes;
    NSUInteger greenPixels = 0;
    for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
        uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
        if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
    }
    return greenPixels;
}

static NSInteger MatrixCodeMessageTargetAt(MatrixCodeMetalView *view, NSInteger offset) {
    NSData *data = [view valueForKey:@"messageTargetGlyphData"];
    const NSInteger *targets = data.bytes;
    return targets[offset];
}

static NSUInteger MatrixCodeMessageClaimedCount(MatrixCodeMetalView *view) {
    NSData *data = [view valueForKey:@"messageClaimedData"];
    const uint8_t *claims = data.bytes;
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < data.length; index++) {
        if (claims[index] != 0) count++;
    }
    return count;
}

- (void)testTrailSliderUsesExponentialScale {
    const float rows = 72.0f;
    const float averageSpeed = 3.5f + 8.0f * 0.5f;
    float trail = [MatrixCodeMetalView diagnosticEffectiveTrailLength:0.255f
                                                                rows:rows
                                                        speedControl:1.0f];
    float visibleRows = averageSpeed * 1.2f * logf(0.004f) / logf(trail);
    XCTAssertEqualWithAccuracy(visibleRows, rows * sqrtf(3.0f), 0.001f);
}

- (void)testNativeRendererCompilesAndCreatesMetalSurface {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[
            @{
                @"id": @"screen-test",
                @"left": @0,
                @"top": @0,
                @"width": @640,
                @"height": @480,
            },
        ],
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:session
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    XCTAssertNotNil(view.device);
}

- (void)testStandaloneGeometryTracksViewResizeBeforeRendering {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)
                                           session:nil
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualWidth"] floatValue], 800, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualHeight"] floatValue], 500, 0.001);

    [view setFrameSize:NSMakeSize(1920, 1200)];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:1920 height:1200];

    XCTAssertNotNil(frame);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualWidth"] floatValue], 1920, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualHeight"] floatValue], 1200, 0.001);
}

- (void)testNativeRendererUsesDisplayMaximumFramePacingAndPausesWhenInactive {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                           session:nil
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    NSInteger expected = [MatrixCodeMetalView maximumFramesPerSecondForScreen:NSScreen.mainScreen];
    XCTAssertEqual(view.preferredFramesPerSecond, expected);
    XCTAssertTrue(view.isPaused);

    [view setAnimationActive:YES];
    XCTAssertFalse(view.isPaused);

    [view setAnimationActive:NO];
    XCTAssertTrue(view.isPaused);
}

- (void)testDisplayFramePacingDoesNotStickAtThirtyWhenDisplayReportsHigherRefresh {
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:60
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:120],
                   120);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:0
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:24
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:300
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   240);
}

- (void)testMeasuredFPSUsesFrameIntervalsInsteadOfPreferredRate {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                           session:nil
                                      storedValues:@{}];
    view.preferredFramesPerSecond = 120;

    XCTAssertEqualWithAccuracy([view updateMeasuredFramesPerSecondAtTime:1000.0], 0, 0.001);
    for (NSUInteger frame = 1; frame <= 20; frame++) {
        [view updateMeasuredFramesPerSecondAtTime:1000.0 + frame / 60.0];
    }

    XCTAssertEqualWithAccuracy([[view valueForKey:@"measuredFramesPerSecond"] doubleValue],
                               60,
                               0.5);
}

- (void)testNativeRendererProducesVisibleGreenGlyphPixels {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @480}],
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:session storedValues:@{}];
    [view setDensityScale:1];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:480];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)100);
}

- (void)testBinaryAndDigitModesUseReadableAtlasDigits {
    NSDictionary *binaryControls = @{@"glyphMode": @"binary", @"glyphFont": @"matrix"};
    NSDictionary *digitControls = @{@"glyphMode": @"digits", @"glyphFont": @"rounded"};
    NSDictionary *matrixControls = @{@"glyphMode": @"matrix", @"glyphFont": @"matrix"};

    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasPrimaryFontNameForGlyph:@"0"
                                                                             controls:binaryControls],
                          @"Menlo-Bold");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasPrimaryFontNameForGlyph:@"1"
                                                                             controls:digitControls],
                          @"Menlo-Bold");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasPrimaryFontNameForGlyph:@"A"
                                                                             controls:binaryControls],
                          @"HiraginoSans-W6");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasPrimaryFontNameForGlyph:@"0"
                                                                             controls:matrixControls],
                          @"HiraginoSans-W6");
    XCTAssertTrue([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"0"
                                                                controls:binaryControls]);
    XCTAssertTrue([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"1"
                                                                controls:digitControls]);
    XCTAssertFalse([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"A"
                                                                 controls:binaryControls]);
    XCTAssertFalse([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"0"
                                                                 controls:matrixControls]);
}

- (void)testDigitOnlyModesRemapEveryRainAtlasCell {
    NSDictionary *binaryControls = @{@"glyphMode": @"binary"};
    NSDictionary *digitControls = @{@"glyphMode": @"digits"};
    NSDictionary *matrixControls = @{@"glyphMode": @"matrix"};
    const NSUInteger rainGlyphCount = (NSUInteger)MatrixCodeRainGlyphCount();

    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"ｦ"
                                                                             index:0
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"0");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:57
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"1");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"ｦ"
                                                                             index:64
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:digitControls],
                          @"8");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:57
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:matrixControls],
                          @"M");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:rainGlyphCount
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"M");

    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:78
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                   0);
    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:87
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                   1);
    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:64
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:digitControls],
                   8);
    XCTAssertLessThan([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:rainGlyphCount
                                                                        rainGlyphCount:rainGlyphCount
                                                                              controls:binaryControls],
                      0);
}

- (void)testHighDensityOverlapVisualFrameRemainsPopulatedAfterStreamCaching {
    NSDictionary *session = @{
        @"seed": @24680,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @800, @"height": @500}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
        @"trailLength": @0.255,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)
                                           session:session
                                      storedValues:@{@"mx-controls": MatrixCodeJSONString(controls)}];
    [view setDensityScale:1 rainElapsed:12.5];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:800 height:500];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)1000,
                         @"High-density overlap render should remain visibly populated");
}

- (void)testLowPowerShaderPathRemainsVisibleWithOptionalEffectsDisabled {
    NSDictionary *session = @{
        @"seed": @4242,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @40,
        @"quality": @"low",
        @"glow": @0,
        @"vignette": @0,
        @"scanlines": @NO,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{@"mx-controls": MatrixCodeJSONString(controls)}];
    [view setDensityScale:1 rainElapsed:9.0];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)250,
                         @"Low-power shader branch should keep glyphs visible");
}

- (void)testActiveMessageVisualFrameStillRendersWithOptimizedMessageLookup {
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"HELLO {fps}"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-messages": MatrixCodeJSONString(messages),
    }];
    [view setDensityScale:1 rainElapsed:2.5];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertNotNil([view valueForKey:@"activeMessageTemplate"]);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500,
                         @"Message-enabled render should remain visibly populated");
}

- (void)testImageScheduleActivatesStoredMaskAndFadeState {
    const uint8_t bytes[] = {0, 96, 180, 255};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Signal", @"width": @2, @"height": @2,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @1000,
        @"disappearMs": @1000,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
        @"imageScale": @0.75,
        @"imagePlacementJitter": @1,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:session
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSTimeInterval now = 1700000001.0;
    [view updateImageScheduleAtTime:now globalCols:21 globalRows:20 localCols:21 localRows:20];
    [view updateActiveImageFrameStateAtTime:now + 0.5];

    XCTAssertNotNil([view valueForKey:@"activeImage"]);
    XCTAssertEqual([[view valueForKey:@"activeImageWidth"] integerValue], 2);
    XCTAssertEqual([[view valueForKey:@"activeImageHeight"] integerValue], 2);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageFrameIntensity"] floatValue], 0.5, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageFrameScramble"] floatValue], 0.5, 0.001);
    XCTAssertGreaterThan([[view valueForKey:@"activeImagePlacementX"] floatValue], 0);
    XCTAssertLessThan([[view valueForKey:@"activeImagePlacementX"] floatValue], 1);
    XCTAssertGreaterThan([[view valueForKey:@"activeImagePlacementY"] floatValue], 0);
    XCTAssertLessThan([[view valueForKey:@"activeImagePlacementY"] floatValue], 1);
}

- (void)testRendererDropsStoredImagesWithInvalidDimensions {
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[
            @{@"name": @"Empty", @"width": @"wide", @"height": @"tall", @"data": @""},
        ],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:@{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    }
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSDictionary *sanitizedImages = [view valueForKey:@"images"];
    XCTAssertEqual([sanitizedImages[@"images"] count], (NSUInteger)0);

    [view updateImageScheduleAtTime:1700000100.0
                         globalCols:21
                         globalRows:20
                          localCols:21
                          localRows:20];
    XCTAssertNil([view valueForKey:@"activeImage"]);
}

- (void)testActiveImageVisualFrameStillRendersAsRain {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    uint8_t *bytes = mask.mutableBytes;
    for (NSUInteger row = 0; row < 8; row++) {
        for (NSUInteger column = 0; column < 8; column++) {
            BOOL diagonal = row == column || row + column == 7;
            bytes[row * 8 + column] = diagonal ? 255 : (uint8_t)(row * 24 + column * 6);
        }
    }
    NSDictionary *session = @{
        @"seed": @24680,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"X", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @0.25,
        @"imagePlacementJitter": @0.75,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-images": MatrixCodeJSONString(images),
    }];
    [view setDensityScale:1 rainElapsed:2.5];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertNotNil([view valueForKey:@"activeImage"]);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500,
                         @"Image-enabled render should remain animated rain, not a blank mask");
}

- (void)testZeroMaskImageDoesNotStampInvisibleRectangle {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    NSDictionary *session = @{
        @"seed": @86420,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"rampUpMs": @0,
        @"glyphRate": @5,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Empty", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @1,
        @"imagePlacementJitter": @0,
    };
    MatrixCodeMetalView *baselineView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
    }];
    MatrixCodeMetalView *imageView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-images": MatrixCodeJSONString(images),
    }];

    [baselineView setDensityScale:1 rainElapsed:2.5];
    [imageView setDensityScale:1 rainElapsed:2.5];
    NSData *baseline = [baselineView diagnosticBGRAFrameWithWidth:640 height:360];
    NSData *imageFrame = [imageView diagnosticBGRAFrameWithWidth:640 height:360];

    XCTAssertNotNil(baseline);
    XCTAssertNotNil(imageFrame);
    XCTAssertNotNil([imageView valueForKey:@"activeImage"]);
    XCTAssertEqualObjects(imageFrame, baseline);
}

- (void)testActiveMessageStillClaimsGlyphsWhenImagesAreEnabled {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    memset(mask.mutableBytes, 255, mask.length);
    NSDictionary *session = @{
        @"seed": @97531,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"HELLO"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Full", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @1,
        @"imagePlacementJitter": @0,
    };
    MatrixCodeMetalView *messageOnlyView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-messages": MatrixCodeJSONString(messages),
    }];
    NSUInteger messageOnlyClaimed = 0;
    for (NSUInteger step = 0; step < 32; step++) {
        [messageOnlyView setDensityScale:1 rainElapsed:2.5 + step * 0.2];
        [messageOnlyView diagnosticBGRAFrameWithWidth:640 height:360];
        messageOnlyClaimed = MatrixCodeMessageClaimedCount(messageOnlyView);
    }

    MatrixCodeMetalView *imageView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-messages": MatrixCodeJSONString(messages),
        @"mx-images": MatrixCodeJSONString(images),
    }];

    NSData *frame = nil;
    NSUInteger claimed = 0;
    for (NSUInteger step = 0; step < 32; step++) {
        [imageView setDensityScale:1 rainElapsed:2.5 + step * 0.2];
        frame = [imageView diagnosticBGRAFrameWithWidth:640 height:360];
        claimed = MatrixCodeMessageClaimedCount(imageView);
    }

    XCTAssertNotNil(frame);
    XCTAssertNotNil([imageView valueForKey:@"activeMessageTemplate"]);
    XCTAssertNotNil([imageView valueForKey:@"activeImage"]);
    XCTAssertEqual([[imageView valueForKey:@"messageTargetGlyphCount"] integerValue], 5);
    XCTAssertGreaterThan(messageOnlyClaimed, (NSUInteger)0);
    XCTAssertGreaterThanOrEqual(claimed, messageOnlyClaimed,
                                @"Image reveals must not prevent in-rain messages from claiming their glyph cells");
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500);
}

- (void)testSingleDropMessageMapsCharactersTopToBottomInOneColumn {
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"ABC"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"messageLayout": @"drop",
        @"messageDirection": @"topToBottom",
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:session
                                      storedValues:@{@"mx-messages": MatrixCodeJSONString(messages)}];
    NSTimeInterval now = 1700000001.0;
    [view updateMessageScheduleAtTime:now globalCols:21 globalRows:20 localCols:21 localRows:20];
    [view updateActiveMessageFrameStateAtTime:now framesPerSecond:60];
    NSDictionary *glyphs = [view valueForKey:@"messageGlyphs"];
    XCTAssertEqual([[view valueForKey:@"activeMessageColumn"] integerValue], 10);
    XCTAssertEqual([[view valueForKey:@"activeMessageStartRow"] integerValue], 8);
    XCTAssertEqual([[view valueForKey:@"messageTargetGlyphCount"] integerValue], 3);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 0), [glyphs[@"A"] integerValue]);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 1), [glyphs[@"B"] integerValue]);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 2), [glyphs[@"C"] integerValue]);
}

- (void)testResolvedMessagesTrimWhitespaceBeforeFitAndLayout {
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@" A "],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 60, 120)
                                           session:@{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @60, @"height": @120}],
    }
                                      storedValues:@{@"mx-messages": MatrixCodeJSONString(messages)}];
    NSTimeInterval now = 1700000001.0;
    [view updateMessageScheduleAtTime:now globalCols:1 globalRows:6 localCols:1 localRows:6];
    [view updateActiveMessageFrameStateAtTime:now framesPerSecond:60];

    NSDictionary *glyphs = [view valueForKey:@"messageGlyphs"];
    XCTAssertNotNil([view valueForKey:@"activeMessageTemplate"]);
    XCTAssertEqualObjects([view valueForKey:@"activeMessageDisplay"], @"A");
    XCTAssertEqual([[view valueForKey:@"messageTargetGlyphCount"] integerValue], 1);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 0), [glyphs[@"A"] integerValue]);
}

- (void)testSingleDropMessageCanReadBottomToTop {
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"ABC"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"messageLayout": @"drop",
        @"messageDirection": @"bottomToTop",
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:session
                                      storedValues:@{@"mx-messages": MatrixCodeJSONString(messages)}];
    NSTimeInterval now = 1700000001.0;
    [view updateMessageScheduleAtTime:now globalCols:21 globalRows:20 localCols:21 localRows:20];
    [view updateActiveMessageFrameStateAtTime:now framesPerSecond:60];
    NSDictionary *glyphs = [view valueForKey:@"messageGlyphs"];
    XCTAssertEqual([[view valueForKey:@"activeMessageColumn"] integerValue], 10);
    XCTAssertEqual([[view valueForKey:@"activeMessageStartRow"] integerValue], 8);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 0), [glyphs[@"A"] integerValue]);
    XCTAssertEqual(MatrixCodeMessageTargetAt(view, 2), [glyphs[@"C"] integerValue]);
}

- (void)testTShapedMultiMonitorWarmStartRendersLeftDisplay {
    NSArray *screens = @[
        @{@"id": @"screen-1", @"left": @0, @"top": @1200,
          @"width": @1710, @"height": @1112},
        @{@"id": @"screen-16", @"left": @-1920, @"top": @1200,
          @"width": @1920, @"height": @1200},
        @{@"id": @"screen-17", @"left": @-112, @"top": @0,
          @"width": @1920, @"height": @1200},
        @{@"id": @"screen-18", @"left": @1710, @"top": @1200,
          @"width": @1920, @"height": @1200},
    ];
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-16",
        @"screens": screens,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1920, 1200)
                                           session:session storedValues:@{}];
    [view setDensityScale:1 rainElapsed:0];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:1920 height:1200];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)100,
                         @"The left display must not start as an empty virtual-grid slice");
}

- (void)testGlyphMutationsDoNotAdvanceInGlobalLockstep {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @480}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"glyphRate": @5,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:controls options:0 error:nil];
    NSString *controlsJSON = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:session
                                      storedValues:@{@"mx-controls": controlsJSON}];
    [view setDensityScale:1 rainElapsed:10.0];
    NSArray<NSNumber *> *before = [view diagnosticGlyphStateSnapshotWithWidth:640 height:480];
    [view setDensityScale:1 rainElapsed:10.2];
    NSArray<NSNumber *> *after = [view diagnosticGlyphStateSnapshotWithWidth:640 height:480];

    XCTAssertEqual(before.count, after.count);
    XCTAssertGreaterThan(before.count, (NSUInteger)100);
    NSUInteger changed = 0;
    for (NSUInteger index = 0; index < before.count; index++) {
        if (![before[index] isEqualToNumber:after[index]]) changed++;
    }
    XCTAssertGreaterThan(changed, (NSUInteger)0);
    XCTAssertLessThan(changed, before.count * 3 / 4);
}

@end
