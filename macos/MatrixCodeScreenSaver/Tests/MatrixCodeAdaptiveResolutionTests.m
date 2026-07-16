#import <XCTest/XCTest.h>

#import "MatrixCodeAdaptiveResolution.h"

@interface MatrixCodeAdaptiveResolutionTests : XCTestCase
@end

@implementation MatrixCodeAdaptiveResolutionTests

static MatrixCodeAdaptiveResolutionConfig MatrixCodeFastAdaptiveConfig(void) {
    return (MatrixCodeAdaptiveResolutionConfig){
        .targetMilliseconds = 16.67,
        .minimumScale = 0.5,
        .step = 0.1,
        .emaAlpha = 0.5,
        .upHeadroom = 0.6,
        .downThreshold = 1.15,
        .cooldownFrames = 1,
        .warmFrames = 1,
    };
}

static void MatrixCodeFeedFrames(MatrixCodeAdaptiveResolution *controller,
                                 double frameMilliseconds,
                                 NSInteger count) {
    for (NSInteger frame = 0; frame < count; frame++) {
        [controller updateWithFrameMilliseconds:frameMilliseconds];
    }
}

- (void)testStartsAtFullScaleAndHoldsInDeadZone {
    MatrixCodeAdaptiveResolution *controller = [[MatrixCodeAdaptiveResolution alloc]
        initWithConfig:MatrixCodeFastAdaptiveConfig()];
    XCTAssertEqualWithAccuracy(controller.value, 1, 0.000001);
    MatrixCodeFeedFrames(controller, 16.67, 100);
    XCTAssertEqualWithAccuracy(controller.value, 1, 0.000001);
}

- (void)testSustainedSlowFramesReachMinimumScale {
    MatrixCodeAdaptiveResolution *controller = [[MatrixCodeAdaptiveResolution alloc]
        initWithConfig:MatrixCodeFastAdaptiveConfig()];
    MatrixCodeFeedFrames(controller, 100, 200);
    XCTAssertEqualWithAccuracy(controller.value, 0.5, 0.000001);
}

- (void)testFastFramesRecoverFromReducedScale {
    MatrixCodeAdaptiveResolution *controller = [[MatrixCodeAdaptiveResolution alloc]
        initWithConfig:MatrixCodeFastAdaptiveConfig()];
    MatrixCodeFeedFrames(controller, 40, 100);
    XCTAssertLessThan(controller.value, 1);
    MatrixCodeFeedFrames(controller, 3, 200);
    XCTAssertEqualWithAccuracy(controller.value, 1, 0.000001);
}

- (void)testSingleSpikeDoesNotCrashBelowOneStepAndRecovers {
    MatrixCodeAdaptiveResolution *controller = [[MatrixCodeAdaptiveResolution alloc]
        initWithConfig:MatrixCodeFastAdaptiveConfig()];
    MatrixCodeFeedFrames(controller, 4, 50);
    [controller updateWithFrameMilliseconds:60];
    MatrixCodeFeedFrames(controller, 4, 50);
    XCTAssertGreaterThanOrEqual(controller.value, 0.9 - 0.000001);
    XCTAssertEqualWithAccuracy(controller.value, 1, 0.000001);
}

@end
