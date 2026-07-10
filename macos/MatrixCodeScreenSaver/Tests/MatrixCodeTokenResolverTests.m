#import <XCTest/XCTest.h>

#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeTokenResolverTests : XCTestCase
@end

@implementation MatrixCodeTokenResolverTests

- (void)testDurationFormattingMatchesWebImplementation {
    XCTAssertEqualObjects([MatrixCodeTokenResolver formatDuration:65], @"01:05");
    XCTAssertEqualObjects([MatrixCodeTokenResolver formatDuration:3665], @"01:01:05");
    XCTAssertEqualObjects([MatrixCodeTokenResolver formatDuration:90061], @"01:01:01:01");
}

- (void)testNameTimeCountdownAndCountupTokensResolve {
    NSDictionary *values = @{
        @"mx-user-name": @"Trinity",
        @"mx-countdown": @"{\"targetMs\":1700000065000,\"moments\":[{\"name\":\"launch\",\"targetMs\":1699999935000}]}",
    };
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values
                                                runStartDate:[now dateByAddingTimeInterval:-5]];
    NSString *resolved = [resolver resolveText:
        @"{name} {countdown} {countup:launch} {uptime} {fps}"
                                        atDate:now
                               framesPerSecond:59.6];
    XCTAssertEqualObjects(resolved, @"Trinity 01:05 01:05 00:05 60 FPS");
}

- (void)testUnknownTokensPassThrough {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:now];
    XCTAssertEqualObjects([resolver resolveText:@"HELLO {unknown}" atDate:now framesPerSecond:0],
                          @"HELLO {unknown}");
}

@end
