#import <XCTest/XCTest.h>

#import "MatrixCodeMetalView.h"

@interface MatrixCodeMetalViewTests : XCTestCase
@end

@implementation MatrixCodeMetalViewTests

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

@end
