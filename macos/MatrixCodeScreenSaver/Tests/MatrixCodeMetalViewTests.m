#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"

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
