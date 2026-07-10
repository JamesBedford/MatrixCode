#import <XCTest/XCTest.h>

#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeIntroOverlayViewTests : XCTestCase
@end

@implementation MatrixCodeIntroOverlayViewTests

- (void)testStoredIntroTimingAndCompletion {
    NSDictionary *values = @{
        @"mx-intro": @"{\"lines\":[{\"text\":\"HI\",\"holdMs\":100,\"pauseMs\":0}],\"charMs\":50,\"startDelayMs\":100,\"fadeOutMs\":200,\"rainDuringIntro\":false,\"postIntroDelayMs\":300}",
    };
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values runStartDate:start];
    __block BOOL completed = NO;
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                            storedValues:values
                                           tokenResolver:resolver
                                              completion:^{ completed = YES; }];
    XCTAssertTrue(view.hasIntro);
    XCTAssertFalse(view.rainDuringIntro);
    XCTAssertEqualWithAccuracy(view.postIntroDelay, 0.3, 0.001);
    XCTAssertEqualWithAccuracy(view.totalDuration, 0.5, 0.001);
    [view startAtDate:start];
    [view updateAtDate:[start dateByAddingTimeInterval:0.51] framesPerSecond:60];
    XCTAssertTrue(completed);
    XCTAssertFalse(view.playing);
}

- (void)testSeenFlagSuppressesIntro {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:@{@"mx-intro-seen": @"1"}
                                           tokenResolver:resolver
                                              completion:^{}];
    XCTAssertFalse(view.hasIntro);
}

@end
