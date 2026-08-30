#import <XCTest/XCTest.h>

#import "MatrixCodeConstants.h"
#import "MatrixCodeIntroOverlayView.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodeSettingsTheme.h"
#import "MatrixCodeTokenResolver.h"

@interface MatrixCodeMetalView (HolidayTesting)
- (void)refreshHolidayColors;
@end

@interface MatrixCodeHolidayClockMetalView : MatrixCodeMetalView
@property(nonatomic, strong) NSDate *colorDate;
@property(nonatomic) BOOL visibleForColorRefresh;
@property(nonatomic) NSUInteger drawCount;
@end

@implementation MatrixCodeHolidayClockMetalView
- (NSDate *)currentColorDate {
    return self.colorDate ?: [NSDate dateWithTimeIntervalSince1970:0];
}
- (BOOL)isVisibleForHolidayColorRefresh {
    return self.visibleForColorRefresh;
}
- (void)draw {
    self.drawCount++;
    [super draw];
}
@end

@interface MatrixCodeHolidayColorTests : XCTestCase
@end

@implementation MatrixCodeHolidayColorTests

- (NSDate *)dateInYear:(NSInteger)year month:(NSInteger)month day:(NSInteger)day
             timeZone:(NSTimeZone *)timeZone {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone;
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = month;
    components.day = day;
    return [calendar dateFromComponents:components];
}

- (void)tearDown {
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    [theme applyControls:@{ @"preset": @"classic", @"customColor": @"#00FF41" }];
    [theme refreshColorsAtDate:NSDate.date timeZone:NSTimeZone.localTimeZone];
    [super tearDown];
}

- (void)testAnnualHolidaysCoverExactlyTheirLocalDates {
    for (NSString *zoneName in @[@"Europe/London", @"America/New_York", @"Pacific/Kiritimati"]) {
        NSTimeZone *zone = [NSTimeZone timeZoneWithName:zoneName];
        for (NSNumber *year in @[@2024, @2026, @2100]) {
            for (NSDictionary *holiday in @[
                @{ @"month": @2, @"day": @14, @"preset": @"red" },
                @{ @"month": @3, @"day": @17, @"preset": @"classic" },
            ]) {
                NSDate *start = [self dateInYear:year.integerValue
                                         month:[holiday[@"month"] integerValue]
                                           day:[holiday[@"day"] integerValue]
                                      timeZone:zone];
                XCTAssertNil(MatrixCodeHolidayColorPreset([start dateByAddingTimeInterval:-0.001], zone));
                XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(start, zone), holiday[@"preset"]);
                XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(
                    [start dateByAddingTimeInterval:86399.999], zone), holiday[@"preset"]);
                XCTAssertNil(MatrixCodeHolidayColorPreset([start dateByAddingTimeInterval:86400], zone));
            }
        }
    }
}

- (void)testOnlyTheTwoGregorianDatesOverrideColors {
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    NSDate *start = [self dateInYear:2024 month:1 day:1 timeZone:zone];
    for (NSInteger index = 0; index < 366; index++) {
        NSDate *date = [start dateByAddingTimeInterval:index * 86400];
        NSDateComponents *parts = [calendar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
        NSString *expected = parts.month == 2 && parts.day == 14 ? @"red" :
            parts.month == 3 && parts.day == 17 ? @"classic" : nil;
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(date, zone), expected);
    }
}

- (void)testTimeZoneAndBackwardClockChangesImmediatelyRecomputeTheOverride {
    NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSTimeZone *west = [NSTimeZone timeZoneForSecondsFromGMT:-8 * 3600];
    NSTimeZone *east = [NSTimeZone timeZoneForSecondsFromGMT:14 * 3600];
    NSDate *valentines = [self dateInYear:2026 month:2 day:14 timeZone:utc];
    NSDate *patrick = [self dateInYear:2026 month:3 day:17 timeZone:utc];
    MatrixCodeSettingsTheme *theme = [[MatrixCodeSettingsTheme alloc] init];
    theme.presetName = @"blue";
    [theme refreshColorsAtDate:valentines timeZone:utc];
    XCTAssertEqualObjects(theme.effectivePresetName, @"red");
    [theme refreshColorsAtDate:valentines timeZone:west];
    XCTAssertEqualObjects(theme.effectivePresetName, @"blue");
    [theme refreshColorsAtDate:valentines timeZone:east];
    XCTAssertEqualObjects(theme.effectivePresetName, @"red");
    [theme refreshColorsAtDate:patrick timeZone:utc];
    XCTAssertEqualObjects(theme.effectivePresetName, @"classic");
    [theme refreshColorsAtDate:valentines timeZone:utc];
    XCTAssertEqualObjects(theme.effectivePresetName, @"red");
    [theme refreshColorsAtDate:[valentines dateByAddingTimeInterval:-1] timeZone:utc];
    XCTAssertEqualObjects(theme.effectivePresetName, @"blue");
}

- (void)testHolidayColorsPreserveLatestSelectedPresetAndCustomColor {
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *holiday = [self dateInYear:2026 month:2 day:14 timeZone:zone];
    MatrixCodeSettingsTheme *theme = [[MatrixCodeSettingsTheme alloc] init];
    NSMutableDictionary *controls = [@{ @"preset": @"gold", @"customColor": @"#112233" } mutableCopy];
    [theme applyControls:controls];
    [theme refreshColorsAtDate:holiday timeZone:zone];
    XCTAssertEqualObjects(theme.presetName, @"gold");
    XCTAssertEqualObjects(theme.effectivePresetName, @"red");
    XCTAssertEqualObjects(controls, (@{ @"preset": @"gold", @"customColor": @"#112233" }));
    [theme applyControls:@{ @"preset": @"custom", @"customColor": @"#ABCDEF" }];
    XCTAssertEqualObjects(theme.effectivePresetName, @"red");
    XCTAssertEqualObjects(theme.presetName, @"custom");
    XCTAssertEqualObjects(theme.customColorHex, @"#ABCDEF");
    [theme refreshColorsAtDate:[holiday dateByAddingTimeInterval:86400] timeZone:zone];
    XCTAssertEqualObjects(theme.effectivePresetName, @"custom");
    NSColor *accent = [theme.accentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(accent.redComponent, 0xAB / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(accent.greenComponent, 0xCD / 255.0, 0.001);
    XCTAssertEqualWithAccuracy(accent.blueComponent, 0xEF / 255.0, 0.001);
    XCTAssertFalse([theme refreshColorsAtDate:[holiday dateByAddingTimeInterval:86401] timeZone:zone]);
}

- (void)testPlayingIntroRecolorsWithoutChangingItsFrozenTimeline {
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *start = [self dateInYear:2026 month:2 day:13 timeZone:zone];
    MatrixCodeSettingsTheme *theme = MatrixCodeSettingsTheme.sharedTheme;
    [theme refreshColorsAtDate:start timeZone:zone];
    NSDictionary *values = @{ @"mx-controls": @"{\"preset\":\"blue\"}" };
    MatrixCodeTokenResolver *resolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:values runStartDate:start];
    MatrixCodeIntroOverlayView *intro = [[MatrixCodeIntroOverlayView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 480) storedValues:values tokenResolver:resolver completion:^{}];
    [intro startAtDate:start];
    [intro updateAtDate:[start dateByAddingTimeInterval:2] framesPerSecond:60];
    NSString *visibleText = [intro valueForKey:@"visibleText"];
    [theme refreshColorsAtDate:[start dateByAddingTimeInterval:86400] timeZone:zone];
    XCTAssertEqualObjects([intro valueForKey:@"accentColor"], theme.accentColor);
    XCTAssertEqualObjects([intro valueForKey:@"visibleText"], visibleText);
    XCTAssertEqualObjects([intro valueForKey:@"startDate"], start);
    XCTAssertTrue(intro.playing);
    XCTAssertEqualObjects(theme.presetName, @"blue");
}

- (void)testMetalPaletteAndGoldSparkleFollowTheHolidayWithoutChangingControls {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 160, 120) session:nil
        storedValues:@{ @"mx-controls": @"{\"preset\":\"gold\",\"customColor\":\"#112233\"}" }];
    XCTAssertNotNil(view);
    if (!view) return;
    [view setAnimationActive:NO];
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *holiday = [self dateInYear:2026 month:2 day:14 timeZone:zone];
    [view refreshColorsAtDate:[holiday dateByAddingTimeInterval:-1] timeZone:zone];
    XCTAssertGreaterThan(view.diagnosticGoldSparkleStrength, 0);
    NSDictionary *originalControls = [view valueForKey:@"controls"];
    XCTAssertTrue([view refreshColorsAtDate:holiday timeZone:zone]);
    XCTAssertEqual(view.diagnosticGoldSparkleStrength, 0);
    XCTAssertEqualWithAccuracy(view.clearColor.red, 13.0 / 255, 0.0001);
    XCTAssertEqualWithAccuracy(view.clearColor.green, 2.0 / 255, 0.0001);
    XCTAssertEqualWithAccuracy(view.clearColor.blue, 2.0 / 255, 0.0001);
    XCTAssertEqualObjects([view valueForKey:@"controls"], originalControls);
    XCTAssertFalse([view refreshColorsAtDate:[holiday dateByAddingTimeInterval:3600] timeZone:zone]);
    NSDate *patrick = [self dateInYear:2026 month:3 day:17 timeZone:zone];
    XCTAssertTrue([view refreshColorsAtDate:patrick timeZone:zone]);
    XCTAssertEqual(view.diagnosticGoldSparkleStrength, 0);
    XCTAssertEqualWithAccuracy(view.clearColor.blue, 8.0 / 255, 0.0001);
    [view refreshColorsAtDate:[patrick dateByAddingTimeInterval:86400] timeZone:zone];
    XCTAssertGreaterThan(view.diagnosticGoldSparkleStrength, 0);
    XCTAssertEqualObjects([view valueForKey:@"controls"], originalControls);
}

- (void)testCapturedMetalRainPixelsUseTheEffectiveHolidayPalette {
    NSDictionary *session = @{
        @"seed": @4242, @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{ @"id": @"screen-test", @"left": @0, @"top": @0,
                         @"width": @640, @"height": @360 }],
    };
    MatrixCodeHolidayClockMetalView *view = [[MatrixCodeHolidayClockMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360) session:session
        storedValues:@{ @"mx-controls": @"{\"preset\":\"gold\",\"density\":40,\"quality\":\"low\",\"glow\":0,\"vignette\":0}" }];
    XCTAssertNotNil(view);
    if (!view) return;
    [view setAnimationActive:NO];
    [view setDensityScale:1 rainElapsed:9];
    NSTimeZone *zone = NSTimeZone.localTimeZone;
    for (NSNumber *month in @[@2, @3]) {
        NSDate *holiday = [self dateInYear:2026 month:month.integerValue
                                     day:month.integerValue == 2 ? 14 : 17 timeZone:zone];
        view.colorDate = [holiday dateByAddingTimeInterval:12 * 3600];
        [view refreshColorsAtDate:holiday timeZone:zone];
        [view draw];
        NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
        XCTAssertNotNil(frame);
        const uint8_t *pixels = frame.bytes;
        NSUInteger redPixels = 0, greenPixels = 0;
        for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
            uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
            if (red > 18 && red > green * 2 && red > blue * 2) redPixels++;
            if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
        }
        if (month.integerValue == 2) {
            XCTAssertGreaterThan(redPixels, 20U);
            XCTAssertEqual(greenPixels, 0U);
        } else {
            XCTAssertGreaterThan(greenPixels, 20U);
            XCTAssertEqual(redPixels, 0U);
        }
    }
}

- (void)testStaticHolidayRepaintWaitsForVisibilityAndPreservesFrozenRain {
    MatrixCodeHolidayClockMetalView *view = [[MatrixCodeHolidayClockMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 160, 120) session:nil
        storedValues:@{ @"mx-controls": @"{\"preset\":\"gold\"}" }];
    XCTAssertNotNil(view);
    if (!view) return;
    NSDate *frozenDate = [NSDate dateWithTimeIntervalSince1970:1000];
    [view freezeAnimationAtDate:frozenDate];
    view.drawCount = 0;
    view.colorDate = [[self dateInYear:2026 month:2 day:14 timeZone:NSTimeZone.localTimeZone]
        dateByAddingTimeInterval:3600];
    [view refreshHolidayColors];
    XCTAssertEqual(view.drawCount, 0U);
    XCTAssertTrue([[view valueForKey:@"holidayColorRedrawPending"] boolValue]);
    view.visibleForColorRefresh = YES;
    [view refreshHolidayColors];
    XCTAssertEqual(view.drawCount, 1U);
    XCTAssertEqual(view.diagnosticGoldSparkleStrength, 0);
    XCTAssertTrue([[view valueForKey:@"hasFrozenFrameTime"] boolValue]);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"frozenFrameTimeSeconds"] doubleValue], 1000, 0.001);
    XCTAssertTrue(view.isPaused);
    XCTAssertEqualObjects([[view valueForKey:@"controls"] objectForKey:@"preset"], @"gold");
}

- (void)testCalendarTimerIsOwnedByTheAttachedView {
    MatrixCodeHolidayClockMetalView *view = [[MatrixCodeHolidayClockMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 160, 120) session:nil storedValues:@{}];
    XCTAssertNotNil(view);
    if (!view) return;
    XCTAssertNil([view valueForKey:@"holidayColorTimer"]);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 160, 120)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [window.contentView addSubview:view];
    NSTimer *timer = [view valueForKey:@"holidayColorTimer"];
    XCTAssertTrue(timer.valid);
    [view setAnimationActive:NO];
    XCTAssertTrue(timer.valid);
    [view removeFromSuperview];
    XCTAssertFalse(timer.valid);
    XCTAssertNil([view valueForKey:@"holidayColorTimer"]);
}

@end
