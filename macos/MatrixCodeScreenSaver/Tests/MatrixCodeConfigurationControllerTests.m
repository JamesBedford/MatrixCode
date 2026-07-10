#import <XCTest/XCTest.h>

#import "MatrixCodeConfigurationController.h"

@interface MatrixCodeConfigurationControllerTests : XCTestCase
@end

@implementation MatrixCodeConfigurationControllerTests

- (void)testNativeConfigurationSheetBuildsAllFeatureTabs {
    MatrixCodeConfigurationController *controller =
        [[MatrixCodeConfigurationController alloc] initWithCloseHandler:^{}];
    XCTAssertNotNil(controller.window);
    NSTabView *tabs = nil;
    for (NSView *view in controller.window.contentView.subviews) {
        if ([view isKindOfClass:NSTabView.class]) tabs = (NSTabView *)view;
    }
    XCTAssertNotNil(tabs);
    XCTAssertEqual(tabs.numberOfTabViewItems, 4);
    XCTAssertEqualObjects([tabs.tabViewItems valueForKey:@"label"],
                          (@[@"Rain", @"Intro", @"Messages", @"Countdowns"]));
}

@end
