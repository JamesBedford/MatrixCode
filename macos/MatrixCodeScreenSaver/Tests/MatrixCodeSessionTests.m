#import <XCTest/XCTest.h>
#import "MatrixCodeSession.h"

@interface MatrixCodeSessionTests : XCTestCase
@end

@implementation MatrixCodeSessionTests

- (NSArray<NSValue *> *)fourDisplayFrames {
    return @[
        [NSValue valueWithRect:NSMakeRect(0, 0, 1710, 1112)],
        [NSValue valueWithRect:NSMakeRect(-112, 1112, 1920, 1200)],
        [NSValue valueWithRect:NSMakeRect(-1920, -88, 1920, 1200)],
        [NSValue valueWithRect:NSMakeRect(1710, -88, 1920, 1200)],
    ];
}

- (void)testAppKitFullDisplayHostsResolveEveryDisplay {
    NSArray<NSValue *> *frames = [self fourDisplayFrames];
    for (NSUInteger index = 0; index < frames.count; index++) {
        XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:frames[index].rectValue screenFrames:frames], index);
    }
}

- (void)testLegacyFullDisplayHostsResolveEveryDisplay {
    NSArray<NSValue *> *frames = [self fourDisplayFrames];
    NSArray<NSValue *> *hosts = @[
        [NSValue valueWithRect:NSMakeRect(0, 0, 1710, 1112)],
        [NSValue valueWithRect:NSMakeRect(-112, -1200, 1920, 1200)],
        [NSValue valueWithRect:NSMakeRect(-1920, 0, 1920, 1200)],
        [NSValue valueWithRect:NSMakeRect(1710, 0, 1920, 1200)],
    ];
    for (NSUInteger index = 0; index < hosts.count; index++) {
        XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:hosts[index].rectValue screenFrames:frames], index);
    }
}

- (void)testPartialHostsChooseGreatestOverlap {
    NSArray<NSValue *> *frames = [self fourDisplayFrames];
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(-500, 200, 800, 500) screenFrames:frames], 2u);
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(1500, 200, 800, 500) screenFrames:frames], 3u);
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(100, 1300, 800, 500) screenFrames:frames], 1u);
}

- (void)testPartialHostDoesNotInferLegacyCoordinates {
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(100, -1000, 800, 500)
                                                      screenFrames:[self fourDisplayFrames]], NSNotFound);
}

- (void)testAmbiguousCoordinateSystemsPreferAppKit {
    NSArray<NSValue *> *frames = @[
        [NSValue valueWithRect:NSMakeRect(0, 0, 1000, 1000)],
        [NSValue valueWithRect:NSMakeRect(0, 1000, 1000, 1000)],
        [NSValue valueWithRect:NSMakeRect(0, -1000, 1000, 1000)],
    ];
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(0, 1000, 1000, 1000) screenFrames:frames], 1u);
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(100, 1200, 500, 500) screenFrames:frames], 1u);
}

- (void)testUnmatchedAndEmptyHostsHaveNoScreen {
    NSArray<NSValue *> *frames = [self fourDisplayFrames];
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(10000, 0, 800, 500) screenFrames:frames], NSNotFound);
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSZeroRect screenFrames:frames], NSNotFound);
    XCTAssertEqual([MatrixCodeSession screenIndexForPlaybackHostRect:NSMakeRect(0, 0, 800, 500) screenFrames:@[]], NSNotFound);
}

@end
