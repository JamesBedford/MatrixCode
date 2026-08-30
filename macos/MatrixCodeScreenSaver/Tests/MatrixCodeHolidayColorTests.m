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
                XCTAssertNotEqualObjects(MatrixCodeHolidayColorPreset(
                    [start dateByAddingTimeInterval:-0.001], zone), holiday[@"preset"]);
                XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(start, zone), holiday[@"preset"]);
                XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(
                    [start dateByAddingTimeInterval:86399.999], zone), holiday[@"preset"]);
                XCTAssertNotEqualObjects(MatrixCodeHolidayColorPreset(
                    [start dateByAddingTimeInterval:86400], zone), holiday[@"preset"]);
            }
        }
    }
}

- (void)testCalendarColorsMatchAllUSNOFullMoonDatesIn2026 {
    NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    // Independent fixtures: https://aa.usno.navy.mil/calculated/moon/phases?year=2026
    NSSet<NSNumber *> *fullMoonDays = [NSSet setWithArray:
        @[@103, @201, @303, @402, @501, @531, @629, @729, @828, @926, @1026, @1124, @1224]];
    NSDate *start = [self dateInYear:2026 month:1 day:1 timeZone:zone];
    for (NSInteger index = 0; index < 365; index++) {
        NSDate *date = [start dateByAddingTimeInterval:index * 86400];
        NSDateComponents *parts = [calendar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
        NSString *expected = parts.month == 2 && parts.day == 14 ? @"red" :
            parts.month == 3 && parts.day == 17 ? @"classic" :
            [fullMoonDays containsObject:@(parts.month * 100 + parts.day)] ? @"white" : nil;
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(date, zone), expected);
    }
}

- (void)testFullMoonColorsCoverItsEntireLocalDateBeforeAndAfterTheInstant {
    for (NSDictionary *fixture in @[
        @{ @"zone": @"America/Los_Angeles", @"day": @27 },
        @{ @"zone": @"Europe/London", @"day": @28 },
        @{ @"zone": @"Asia/Tokyo", @"day": @28 },
    ]) {
        NSTimeZone *zone = [NSTimeZone timeZoneWithName:fixture[@"zone"]];
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = zone;
        NSDate *start = [self dateInYear:2026 month:8 day:[fixture[@"day"] integerValue] timeZone:zone];
        NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:start options:0];
        XCTAssertNil(MatrixCodeHolidayColorPreset([start dateByAddingTimeInterval:-0.001], zone));
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(start, zone), @"white");
        NSDate *phase = [MatrixCodeTokenResolver builtInMomentNamed:@"fullmoon"
            relativeToDate:[start dateByAddingTimeInterval:-0.001]];
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset([phase dateByAddingTimeInterval:-1], zone), @"white");
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset([phase dateByAddingTimeInterval:1], zone), @"white");
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset([end dateByAddingTimeInterval:-0.001], zone), @"white");
        XCTAssertNil(MatrixCodeHolidayColorPreset(end, zone));
        // Revisit an earlier day to invalidate the one-day cache after a backward clock change.
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(start, zone), @"white");
    }
}

- (void)testFullMoonCacheTracksTimeZoneChangesAndTwoFullMoonsInOneMonth {
    NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSTimeZone *west = [NSTimeZone timeZoneWithName:@"America/Los_Angeles"];
    NSTimeZone *east = [NSTimeZone timeZoneWithName:@"Asia/Tokyo"];
    NSDate *now = [[self dateInYear:2026 month:8 day:28 timeZone:utc] dateByAddingTimeInterval:12 * 3600];
    XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(now, east), @"white");
    XCTAssertNil(MatrixCodeHolidayColorPreset(now, west));
    XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(now, east), @"white");
    for (NSNumber *day in @[@1, @31]) {
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(
            [self dateInYear:2026 month:5 day:day.integerValue timeZone:utc], utc), @"white");
    }
    XCTAssertNil(MatrixCodeHolidayColorPreset([self dateInYear:2026 month:5 day:15 timeZone:utc], utc));
}

- (void)testFullMoonDaysUseCalendarBoundariesAcrossDaylightSavingChanges {
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@"America/New_York"];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    for (NSDictionary *fixture in @[
        @{ @"year": @2017, @"month": @3, @"day": @12, @"hours": @23 },
        @{ @"year": @2033, @"month": @11, @"day": @6, @"hours": @25 },
        @{ @"year": @2060, @"month": @11, @"day": @7, @"hours": @25 },
    ]) {
        NSDate *date = [self dateInYear:[fixture[@"year"] integerValue]
            month:[fixture[@"month"] integerValue] day:[fixture[@"day"] integerValue] timeZone:zone];
        NSDate *end = [calendar startOfDayForDate:
            [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:date options:0]];
        NSDateInterval *interval = [[NSDateInterval alloc] initWithStartDate:date endDate:end];
        XCTAssertEqualWithAccuracy(interval.duration, [fixture[@"hours"] doubleValue] * 3600, 0.001);
        NSDate *phase = [MatrixCodeTokenResolver builtInMomentNamed:@"fullmoon" relativeToDate:interval.startDate];
        if ([fixture[@"year"] integerValue] == 2060) {
            // The full moon falls in the last hour of this 25-hour local day.
            XCTAssertGreaterThan([phase timeIntervalSinceDate:interval.startDate], 86400);
        }
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(interval.startDate, zone), @"white");
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(
            [interval.endDate dateByAddingTimeInterval:-0.001], zone), @"white");
        XCTAssertNil(MatrixCodeHolidayColorPreset(interval.endDate, zone));
    }
}

- (void)testFixedHolidayColorsTakePriorityOverCoincidentFullMoons {
    NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
    for (NSDictionary *holiday in @[
        @{ @"year": @2033, @"month": @2, @"day": @14, @"preset": @"red" },
        @{ @"year": @2041, @"month": @3, @"day": @17, @"preset": @"classic" },
    ]) {
        NSDate *date = [self dateInYear:[holiday[@"year"] integerValue]
            month:[holiday[@"month"] integerValue] day:[holiday[@"day"] integerValue] timeZone:utc];
        NSDate *phase = [MatrixCodeTokenResolver builtInMomentNamed:@"fullmoon" relativeToDate:date];
        XCTAssertGreaterThan([phase timeIntervalSinceDate:date], 0);
        XCTAssertLessThan([phase timeIntervalSinceDate:date], 86400);
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(date, utc), holiday[@"preset"]);
        XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(phase, utc), holiday[@"preset"]);
    }
}

- (void)testFullMoonDayHandlesADaylightSavingGapAtMidnight {
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@"America/Santiago"];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    NSDate *date = [self dateInYear:2025 month:9 day:7 timeZone:zone];
    NSDate *start;
    NSTimeInterval duration;
    XCTAssertTrue([calendar rangeOfUnit:NSCalendarUnitDay startDate:&start interval:&duration forDate:date]);
    XCTAssertEqual([calendar component:NSCalendarUnitHour fromDate:start], 1);
    XCTAssertEqualWithAccuracy(duration, 23 * 3600, 0.001);
    NSDate *end = [start dateByAddingTimeInterval:duration];
    XCTAssertEqual([calendar component:NSCalendarUnitDay fromDate:end], 8);
    XCTAssertEqual([calendar component:NSCalendarUnitHour fromDate:end], 0);
    XCTAssertNil(MatrixCodeHolidayColorPreset([start dateByAddingTimeInterval:-0.001], zone));
    XCTAssertEqualObjects(MatrixCodeHolidayColorPreset(start, zone), @"white");
    XCTAssertEqualObjects(MatrixCodeHolidayColorPreset([end dateByAddingTimeInterval:-0.001], zone), @"white");
    XCTAssertNil(MatrixCodeHolidayColorPreset(end, zone));
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
    NSDate *fullMoon = [self dateInYear:2026 month:8 day:28 timeZone:zone];
    [theme refreshColorsAtDate:fullMoon timeZone:zone];
    XCTAssertEqualObjects(theme.effectivePresetName, @"white");
    [theme applyControls:@{ @"preset": @"custom", @"customColor": @"#123456" }];
    XCTAssertEqualObjects(theme.effectivePresetName, @"white");
    [theme refreshColorsAtDate:[fullMoon dateByAddingTimeInterval:86400] timeZone:zone];
    XCTAssertEqualObjects(theme.effectivePresetName, @"custom");
    XCTAssertEqualObjects(theme.customColorHex, @"#123456");
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
    [theme refreshColorsAtDate:[self dateInYear:2026 month:8 day:28 timeZone:zone] timeZone:zone];
    XCTAssertEqualObjects(theme.effectivePresetName, @"white");
    XCTAssertEqualObjects([intro valueForKey:@"accentColor"], theme.accentColor);
    XCTAssertEqualObjects([intro valueForKey:@"visibleText"], visibleText);
    XCTAssertEqualObjects([intro valueForKey:@"startDate"], start);
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
    NSDate *fullMoon = [[self dateInYear:2026 month:8 day:28
        timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]] dateByAddingTimeInterval:4 * 3600 + 18 * 60];
    NSArray<NSDate *> *dates = @[
        [self dateInYear:2026 month:2 day:14 timeZone:zone],
        [self dateInYear:2026 month:3 day:17 timeZone:zone], fullMoon,
    ];
    for (NSUInteger dateIndex = 0; dateIndex < dates.count; dateIndex++) {
        NSDate *holiday = dates[dateIndex];
        view.colorDate = holiday;
        [view refreshColorsAtDate:holiday timeZone:zone];
        [view draw];
        NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
        XCTAssertNotNil(frame);
        const uint8_t *pixels = frame.bytes;
        NSUInteger redPixels = 0, greenPixels = 0, neutralPixels = 0, coloredPixels = 0;
        for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
            uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
            if (red > 18 && red > green * 2 && red > blue * 2) redPixels++;
            if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
            if (MAX(red, MAX(green, blue)) > 18) {
                if (MAX(red, MAX(green, blue)) - MIN(red, MIN(green, blue)) <= 2) neutralPixels++;
                else coloredPixels++;
            }
        }
        if (dateIndex == 0) {
            XCTAssertGreaterThan(redPixels, 20U);
            XCTAssertEqual(greenPixels, 0U);
        } else if (dateIndex == 1) {
            XCTAssertGreaterThan(greenPixels, 20U);
            XCTAssertEqual(redPixels, 0U);
        } else {
            XCTAssertGreaterThan(neutralPixels, 20U);
            XCTAssertEqual(coloredPixels, 0U);
            XCTAssertEqual(view.diagnosticGoldSparkleStrength, 0);
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
    view.colorDate = [[self dateInYear:2026 month:8 day:28
        timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]] dateByAddingTimeInterval:4 * 3600 + 18 * 60];
    [view refreshHolidayColors];
    XCTAssertEqualWithAccuracy(view.clearColor.red, 6.0 / 255, 0.0001);
    XCTAssertEqualWithAccuracy(view.clearColor.green, 6.0 / 255, 0.0001);
    XCTAssertEqualWithAccuracy(view.clearColor.blue, 6.0 / 255, 0.0001);
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.localTimeZone;
    view.colorDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:1
        toDate:[calendar startOfDayForDate:view.colorDate] options:0];
    [view refreshHolidayColors];
    XCTAssertGreaterThan(view.diagnosticGoldSparkleStrength, 0);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"frozenFrameTimeSeconds"] doubleValue], 1000, 0.001);
    XCTAssertTrue(view.isPaused);
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
