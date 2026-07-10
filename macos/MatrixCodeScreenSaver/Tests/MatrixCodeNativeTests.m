#import <XCTest/XCTest.h>

#import "MatrixCodePreferences.h"
#import "MatrixCodeSession.h"

@interface MatrixCodeNativeTests : XCTestCase
@end

@implementation MatrixCodeNativeTests

- (void)testStorageWhitelistAcceptsOnlySupportedKeys {
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-controls"]);
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-intro-seen"]);
    XCTAssertFalse([MatrixCodePreferences isAllowedStorageKey:@"unknown"]);
    XCTAssertFalse([MatrixCodePreferences isAllowedStorageKey:@"MatrixCodeNativeSession"]);
}

- (void)testAppKitCoordinatesConvertToTopLeftCoordinates {
    NSRect frame = NSMakeRect(-1440, 900, 1440, 900);
    NSRect converted = [MatrixCodeSession topLeftRectForFrame:frame desktopMaxY:1800];
    XCTAssertEqualWithAccuracy(converted.origin.x, -1440, 0.001);
    XCTAssertEqualWithAccuracy(converted.origin.y, 0, 0.001);
    XCTAssertEqualWithAccuracy(converted.size.width, 1440, 0.001);
    XCTAssertEqualWithAccuracy(converted.size.height, 900, 0.001);
}

- (void)testStackedLowerDisplayStartsBelowUpperDisplay {
    NSRect upper = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(0, 1080, 1920, 1080)
                                              desktopMaxY:2160];
    NSRect lower = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(0, 0, 1920, 1080)
                                              desktopMaxY:2160];
    XCTAssertEqualWithAccuracy(NSMaxY(upper), lower.origin.y, 0.001);
}

@end
