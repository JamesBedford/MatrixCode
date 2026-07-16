#import <XCTest/XCTest.h>

#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeIntroOverlayView (Testing)
- (NSAttributedString *)displayAttributedStringWithAttributes:
    (NSDictionary<NSAttributedStringKey, id> *)attributes
                                                      fontSize:(CGFloat)fontSize;
- (NSRect)layoutRectForAttributedString:(NSAttributedString *)attributedString;
@end

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

- (void)testDefaultIntroWaitsForRainUntilAfterIntro {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:@{}
                                           tokenResolver:resolver
                                              completion:^{}];
    XCTAssertFalse(view.rainDuringIntro);
}

- (void)testIntroLineCapIsAppliedBeforeMalformedEntriesAreFiltered {
    NSMutableArray *rawLines = [NSMutableArray array];
    for (NSUInteger index = 0; index < 12; index++) {
        [rawLines addObject:NSNull.null];
    }
    [rawLines addObject:@{@"text": @"THIRTEENTH LINE"}];
    NSData *introData = [NSJSONSerialization dataWithJSONObject:@{@"lines": rawLines}
                                                       options:0
                                                         error:nil];
    NSString *intro = [[NSString alloc] initWithData:introData encoding:NSUTF8StringEncoding];
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{@"mx-intro": intro}
                                                 runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:@{@"mx-intro": intro}
                                           tokenResolver:resolver
                                              completion:^{}];

    NSArray<NSDictionary *> *lines = [view valueForKey:@"lines"];
    NSArray<NSString *> *texts = [lines valueForKey:@"text"];
    XCTAssertEqual(lines.count, 4u);
    XCTAssertEqualObjects(lines.firstObject[@"text"], @"Wake up, {name}...");
    XCTAssertFalse([texts containsObject:@"THIRTEENTH LINE"]);
}

- (void)testSkipCompletesPlayingIntroImmediately {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:start];
    __block BOOL completed = NO;
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:@{}
                                           tokenResolver:resolver
                                              completion:^{ completed = YES; }];
    [view startAtDate:start];
    XCTAssertTrue(view.playing);
    [view skip];
    XCTAssertTrue(completed);
    XCTAssertFalse(view.playing);
    XCTAssertFalse(view.hasIntro);
}

- (void)testCancelHidesPlayingIntroWithoutCompletingIt {
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:@{} runStartDate:start];
    __block BOOL completed = NO;
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:@{}
                                           tokenResolver:resolver
                                              completion:^{ completed = YES; }];
    [view startAtDate:start];

    [view cancel];

    XCTAssertFalse(completed);
    XCTAssertFalse(view.playing);
    XCTAssertFalse(view.hasIntro);
    XCTAssertTrue(view.hidden);
}

- (void)testIntroUsesStoredPresetAndFadesWholeOverlay {
    NSDictionary *values = @{
        @"mx-controls": @"{\"preset\":\"blue\"}",
        @"mx-intro": @"{\"lines\":[{\"text\":\"A\",\"holdMs\":0,\"pauseMs\":0}],\"charMs\":10,\"startDelayMs\":0,\"fadeOutMs\":1000}",
    };
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                            storedValues:values
                                           tokenResolver:resolver
                                              completion:^{}];

    NSColor *accent = [[view valueForKey:@"accentColor"]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(accent.redComponent, 0x27 / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(accent.greenComponent, 0xd6 / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(accent.blueComponent, 1.0, 0.001);

    [view startAtDate:start];
    [view updateAtDate:[start dateByAddingTimeInterval:0.51] framesPerSecond:60];
    XCTAssertEqualWithAccuracy(view.alphaValue, 0.5, 0.02);
}

- (void)testIntroPresetUsesStrictSharedControlsSanitizer {
    NSDictionary *values = @{
        @"mx-controls": @"{\"preset\":\"not-a-preset\"}",
    };
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:values runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:values
                                           tokenResolver:resolver
                                              completion:^{}];
    NSColor *accent = [[view valueForKey:@"accentColor"]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

    XCTAssertEqualWithAccuracy(accent.redComponent, 0, 0.001);
    XCTAssertEqualWithAccuracy(accent.greenComponent, 1, 0.001);
    XCTAssertEqualWithAccuracy(accent.blueComponent, 0x41 / 255.0, 0.001);
}

- (void)testReloadRefreshesActiveIntroTokensWithoutRestartingTimeline {
    NSString *intro = @"{\"lines\":[{\"text\":\"{name}\",\"holdMs\":1000,\"pauseMs\":0}],\"charMs\":10,\"startDelayMs\":0,\"fadeOutMs\":0}";
    NSDictionary *initialValues = @{@"mx-user-name": @"Neo", @"mx-intro": intro};
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:initialValues runStartDate:start];
    MatrixCodeIntroOverlayView *view =
        [[MatrixCodeIntroOverlayView alloc] initWithFrame:NSZeroRect
                                            storedValues:initialValues
                                           tokenResolver:resolver
                                              completion:^{}];
    [view startAtDate:start];
    [view updateAtDate:[start dateByAddingTimeInterval:0.5] framesPerSecond:60];
    XCTAssertEqualObjects([view valueForKey:@"visibleText"], @"Neo");

    NSDictionary *updatedValues = @{@"mx-user-name": @"Trinity", @"mx-intro": intro};
    MatrixCodeTokenResolver *updatedResolver =
        [[MatrixCodeTokenResolver alloc] initWithStoredValues:updatedValues runStartDate:start];
    [view reloadStoredValues:updatedValues tokenResolver:updatedResolver];
    [view updateAtDate:[start dateByAddingTimeInterval:0.5] framesPerSecond:60];

    XCTAssertTrue(view.playing);
    XCTAssertEqualObjects([view valueForKey:@"visibleText"], @"Trinity");
}

- (void)testLongIntroRenderWrapsInsideSixVwPaddingAndKeepsCursorGap {
    NSString *line = @"THIS UNSAVED CUSTOM INTRO LINE IS LONG ENOUGH TO WRAP ACROSS MULTIPLE VISUAL LINES WITHOUT BEING CROPPED AT EITHER EDGE";
    NSDictionary *values = @{
        @"mx-intro": [NSString stringWithFormat:
            @"{\"lines\":[{\"text\":\"%@\",\"holdMs\":5000,\"pauseMs\":0}],\"charMs\":10,\"startDelayMs\":0,\"fadeOutMs\":0}",
            line],
    };
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1700000000];
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values
                runStartDate:start];
    MatrixCodeIntroOverlayView *view = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSMakeRect(0, 0, 500, 300)
         storedValues:values
        tokenResolver:resolver
           completion:^{}];
    [view startAtDate:start];
    [view updateAtDate:[start dateByAddingTimeInterval:2] framesPerSecond:60];

    CGFloat fontSize = 21;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:fontSize
                                                        weight:NSFontWeightMedium],
        NSKernAttributeName: @(fontSize * 0.02),
        NSParagraphStyleAttributeName: paragraph,
    };
    NSAttributedString *display = [view displayAttributedStringWithAttributes:attributes
                                                                      fontSize:fontSize];
    NSRect layoutRect = [view layoutRectForAttributedString:display];

    XCTAssertEqualObjects(display.string, [line stringByAppendingString:@"█"]);
    NSNumber *kernBeforeCursor = [display attribute:NSKernAttributeName
                                            atIndex:line.length - 1
                                     effectiveRange:NULL];
    XCTAssertEqualWithAccuracy(kernBeforeCursor.doubleValue, fontSize * 0.06, 0.001);
    XCTAssertLessThanOrEqual(NSWidth(layoutRect), 440);
    XCTAssertGreaterThanOrEqual(NSMinX(layoutRect), 30);
    XCTAssertLessThanOrEqual(NSMaxX(layoutRect), 470);
    XCTAssertGreaterThan(NSHeight(layoutRect), fontSize * 2);
    XCTAssertNoThrow([view drawRect:view.bounds]);
}

@end
