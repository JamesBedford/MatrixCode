#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"

@interface MatrixCodeMetalViewTests : XCTestCase
@end

@implementation MatrixCodeMetalViewTests

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
    const uint8_t *pixels = frame.bytes;
    NSUInteger greenPixels = 0;
    for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
        uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
        if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
    }
    XCTAssertGreaterThan(greenPixels, (NSUInteger)100);
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
    const uint8_t *pixels = frame.bytes;
    NSUInteger greenPixels = 0;
    for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
        uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
        if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
    }
    XCTAssertGreaterThan(greenPixels, (NSUInteger)100,
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
