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

- (void)testSpacePaddedDayMatchesWebStrftime {
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = 2026; parts.month = 7; parts.day = 5; parts.hour = 9;
    NSDate *date = [NSCalendar.currentCalendar dateFromComponents:parts];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:date];
    XCTAssertEqualObjects([resolver resolveText:@"{time:%e}" atDate:date framesPerSecond:60],
                          @" 5");
}

- (void)testAstronomicalTokensRemainAvailableBeyondStaticTables {
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = 2099; parts.month = 6; parts.day = 1; parts.hour = 12;
    NSDate *date = [NSCalendar.currentCalendar dateFromComponents:parts];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:date];
    NSString *resolved = [resolver resolveText:
        @"{countdown:diwali} {countdown:newmoon} {countdown:fullmoon}"
                                        atDate:date
                               framesPerSecond:60];
    XCTAssertFalse([resolved isEqualToString:@"00:00 00:00 00:00"]);
    for (NSString *value in [resolved componentsSeparatedByString:@" "]) {
        XCTAssertNotEqualObjects(value, @"00:00");
    }
}

- (void)testCountdownMomentSanitizationMatchesWebCapAndNameOrder {
    NSMutableArray *moments = [NSMutableArray array];
    for (NSInteger index = 0; index < 12; index++) {
        [moments addObject:@{@"name": @"", @"targetMs": @1700000065000}];
    }
    [moments addObject:@{@"name": @"late", @"targetMs": @1700000065000}];
    [moments replaceObjectAtIndex:0 withObject:
        @{@"name": @"{ launch }", @"targetMs": @1700000065000}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"targetMs": NSNull.null, @"moments": moments,
    } options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{@"mx-countdown": json}
                                                runStartDate:now];
    XCTAssertEqualObjects([resolver resolveText:@"{countdown:launch}" atDate:now framesPerSecond:60],
                          @"01:05");
    XCTAssertEqualObjects([resolver resolveText:@"{countdown:late}" atDate:now framesPerSecond:60],
                          @"00:00");
}

@end
