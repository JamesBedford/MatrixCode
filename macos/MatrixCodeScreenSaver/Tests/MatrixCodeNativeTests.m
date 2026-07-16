#import <XCTest/XCTest.h>

#import "../AppSource/MatrixCodeAppDelegate.h"
#import "MatrixCodeConstants.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainHostView.h"
#import "MatrixCodeSession.h"

@interface MatrixCodeAppDelegate (Testing)
- (void)setFPSOverlayVisible:(BOOL)visible
                forHostViews:(NSArray<MatrixCodeRainHostView *> *)hostViews;
- (void)windowWillClose:(NSNotification *)notification;
@end

@interface MatrixCodeClosingProbeWindow : NSWindow
@property(nonatomic) BOOL receivedClose;
@end

@implementation MatrixCodeClosingProbeWindow
- (void)close {
    self.receivedClose = YES;
}
@end

extern NSWindowCollectionBehavior MatrixCodeMultiMonitorWindowCollectionBehavior(void);

@interface MatrixCodeNativeTests : XCTestCase
@end

@implementation MatrixCodeNativeTests

- (void)testStorageWhitelistAcceptsOnlySupportedKeys {
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-controls"]);
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-intro-seen"]);
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-images"]);
    XCTAssertTrue([MatrixCodePreferences isAllowedStorageKey:@"mx-ui-state"]);
    XCTAssertFalse([MatrixCodePreferences isAllowedStorageKey:@"unknown"]);
    XCTAssertFalse([MatrixCodePreferences isAllowedStorageKey:@"MatrixCodeNativeSession"]);
    XCTAssertFalse([MatrixCodePreferences isAllowedStorageKey:@"MatrixCodeAppPresentationMode"]);
}

- (NSUserDefaults *)isolatedDefaultsWithSuiteName:(NSString **)suiteName {
    NSString *name = [@"com.matrixcode.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:name];
    [defaults removePersistentDomainForName:name];
    if (suiteName) *suiteName = name;
    return defaults;
}

- (void)testAppPresentationModeDefaultsToWindowed {
    NSString *suiteName = nil;
    NSUserDefaults *defaults = [self isolatedDefaultsWithSuiteName:&suiteName];

    XCTAssertEqualObjects([MatrixCodePreferences savedAppPresentationModeInDefaults:defaults],
                          MatrixCodeAppPresentationModeWindowed);

    [defaults removePersistentDomainForName:suiteName];
}

- (void)testAppPresentationModePersistsFullscreenAndMultiMonitor {
    NSString *suiteName = nil;
    NSUserDefaults *defaults = [self isolatedDefaultsWithSuiteName:&suiteName];

    [MatrixCodePreferences setSavedAppPresentationMode:MatrixCodeAppPresentationModeFullScreen
                                            inDefaults:defaults];
    XCTAssertEqualObjects([MatrixCodePreferences savedAppPresentationModeInDefaults:defaults],
                          MatrixCodeAppPresentationModeFullScreen);

    [MatrixCodePreferences setSavedAppPresentationMode:MatrixCodeAppPresentationModeMultiMonitor
                                            inDefaults:defaults];
    XCTAssertEqualObjects([MatrixCodePreferences savedAppPresentationModeInDefaults:defaults],
                          MatrixCodeAppPresentationModeMultiMonitor);

    [defaults removePersistentDomainForName:suiteName];
}

- (void)testInvalidAppPresentationModeFallsBackToWindowed {
    NSString *suiteName = nil;
    NSUserDefaults *defaults = [self isolatedDefaultsWithSuiteName:&suiteName];
    [defaults setObject:@"sideways" forKey:@"MatrixCodeAppPresentationMode"];

    XCTAssertEqualObjects([MatrixCodePreferences savedAppPresentationModeInDefaults:defaults],
                          MatrixCodeAppPresentationModeWindowed);

    [MatrixCodePreferences setSavedAppPresentationMode:@"also-sideways" inDefaults:defaults];
    XCTAssertEqualObjects([MatrixCodePreferences savedAppPresentationModeInDefaults:defaults],
                          MatrixCodeAppPresentationModeWindowed);

    [defaults removePersistentDomainForName:suiteName];
}

- (void)testFPSOverlayVisibilityPropagatesAcrossMultiMonitorHosts {
    MatrixCodeAppDelegate *delegate = [[MatrixCodeAppDelegate alloc] init];
    MatrixCodeRainHostView *leftHost =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];
    MatrixCodeRainHostView *rightHost =
        [[MatrixCodeRainHostView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                                 mode:MatrixCodeRainHostModeStandalone
                                              session:nil
                                suppressesIntroOverlay:YES];

    [delegate setFPSOverlayVisible:YES forHostViews:@[leftHost, rightHost]];
    XCTAssertTrue(leftHost.fpsOverlayVisible);
    XCTAssertTrue(rightHost.fpsOverlayVisible);

    [delegate setFPSOverlayVisible:NO forHostViews:@[leftHost, rightHost]];
    XCTAssertFalse(leftHost.fpsOverlayVisible);
    XCTAssertFalse(rightHost.fpsOverlayVisible);
}

- (void)testClosingOneMultiMonitorWindowClosesTheRemainingSessionWindows {
    MatrixCodeAppDelegate *delegate = [[MatrixCodeAppDelegate alloc] init];
    MatrixCodeClosingProbeWindow *first = [[MatrixCodeClosingProbeWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 320, 200)
                 styleMask:NSWindowStyleMaskBorderless
                   backing:NSBackingStoreBuffered
                     defer:NO];
    MatrixCodeClosingProbeWindow *second = [[MatrixCodeClosingProbeWindow alloc]
        initWithContentRect:NSMakeRect(320, 0, 320, 200)
                 styleMask:NSWindowStyleMaskBorderless
                   backing:NSBackingStoreBuffered
                     defer:NO];
    NSMutableArray<NSWindow *> *windows = [delegate valueForKey:@"multiMonitorWindows"];
    [windows addObjectsFromArray:@[first, second]];

    [delegate windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification
                                                             object:first]];

    XCTAssertEqual(windows.count, 0);
    XCTAssertFalse(first.receivedClose);
    XCTAssertTrue(second.receivedClose);
}

- (void)testWebControlStepsAndDensityNudgeAreSharedNativeRules {
    XCTAssertEqualWithAccuracy(MatrixCodeQuantizedControlValue(@"density", 2.123), 2.1, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeQuantizedControlValue(@"rampUpMs", 8126), 8000, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeQuantizedControlValue(@"glyphScale", 1.26), 1.3, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeNudgedDensity(2, 1.2), 2.4, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeNudgedDensity(5.2, 1.2), 6, 0.0001);
}

- (void)testControlsSanitizerMatchesWebDefaultsTypesRangesAndChoices {
    NSDictionary *controls = MatrixCodeSanitizeControlsDocument(@{
        @"speed": @99,
        @"trailLength": @(-4),
        @"trailVariation": @2,
        @"density": @(NAN),
        @"rampUpMs": @YES,
        @"glyphRate": @(-1),
        @"glyphScale": @20,
        @"glow": @"2.4",
        @"leadBrightness": @9,
        @"glyphMode": @"unknown",
        @"glyphFont": @"unknown",
        @"preset": @"unknown",
        @"mirror": @0,
        @"scanlines": @1,
        @"vignette": @YES,
        @"allowOverlap": @0,
        @"quality": @"ultra",
    });

    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 3, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"trailLength"] doubleValue], 0.01, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"trailVariation"] doubleValue], 1, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 2, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"rampUpMs"] doubleValue], 8000, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"glyphRate"] doubleValue], 0, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"glyphScale"] doubleValue], 10, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"glow"] doubleValue], 0.9, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"leadBrightness"] doubleValue], 3, 0.0001);
    XCTAssertEqualObjects(controls[@"glyphMode"], @"matrix");
    XCTAssertEqualObjects(controls[@"glyphFont"], @"matrix");
    XCTAssertEqualObjects(controls[@"preset"], @"classic");
    XCTAssertEqualObjects(controls[@"mirror"], @YES);
    XCTAssertEqualObjects(controls[@"scanlines"], @NO);
    XCTAssertEqualWithAccuracy([controls[@"vignette"] doubleValue], 0.42, 0.0001);
    XCTAssertEqualObjects(controls[@"allowOverlap"], @YES);
    XCTAssertEqualObjects(controls[@"quality"], @"high");

    NSDictionary *validControls = MatrixCodeSanitizeControlsDocument(@{
        @"glyphMode": @"katakana",
        @"glyphFont": @"mincho",
        @"preset": @"blue",
        @"mirror": @NO,
        @"scanlines": @YES,
        @"vignette": @NO,
        @"allowOverlap": @NO,
        @"quality": @"med",
    });
    XCTAssertEqualObjects(validControls[@"glyphMode"], @"katakana");
    XCTAssertEqualObjects(validControls[@"glyphFont"], @"mincho");
    XCTAssertEqualObjects(validControls[@"preset"], @"blue");
    XCTAssertEqualObjects(validControls[@"mirror"], @NO);
    XCTAssertEqualObjects(validControls[@"scanlines"], @YES);
    XCTAssertEqualWithAccuracy([validControls[@"vignette"] doubleValue], 0, 0.0001);
    XCTAssertEqualObjects(validControls[@"allowOverlap"], @NO);
    XCTAssertEqualObjects(validControls[@"quality"], @"med");
}

- (void)testSingleDisplayUsesWebSeedWhileMultiDisplayPreservesRandomSeed {
    XCTAssertEqual([MatrixCodeSession seedForScreenCount:1 randomSeed:0xdeadbeefU], 0x1a2b3cU);
    XCTAssertEqual([MatrixCodeSession seedForScreenCount:2 randomSeed:0xdeadbeefU], 0xdeadbeefU);
    XCTAssertEqual([[[MatrixCodeSession singleDisplaySession] objectForKey:@"seed"] unsignedIntValue],
                   0x1a2b3cU);
}

- (void)testStandaloneMultiMonitorEntriesReceiveFreshIdentities {
    NSDictionary *first = [MatrixCodeSession freshIdentityForScreenCount:3
                                                               randomSeed:0x12345678U
                                                        epochMilliseconds:1000];
    NSDictionary *second = [MatrixCodeSession freshIdentityForScreenCount:3
                                                                randomSeed:0x87654321U
                                                         epochMilliseconds:1001];

    XCTAssertEqualObjects(first[@"seed"], @(0x12345678U));
    XCTAssertEqualObjects(first[@"epoch"], @1000);
    XCTAssertNotEqualObjects(first[@"seed"], second[@"seed"]);
    XCTAssertNotEqualObjects(first[@"epoch"], second[@"epoch"]);
}

- (void)testMultiMonitorWindowsJoinAllSpacesIncludingFullscreenAuxiliarySpaces {
    NSWindowCollectionBehavior behavior = MatrixCodeMultiMonitorWindowCollectionBehavior();

    XCTAssertTrue((behavior & NSWindowCollectionBehaviorCanJoinAllSpaces) != 0);
    XCTAssertTrue((behavior & NSWindowCollectionBehaviorFullScreenAuxiliary) != 0);
    XCTAssertFalse((behavior & NSWindowCollectionBehaviorMoveToActiveSpace) != 0);
    XCTAssertTrue((behavior & NSWindowCollectionBehaviorStationary) != 0);
    XCTAssertTrue((behavior & NSWindowCollectionBehaviorIgnoresCycle) != 0);
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

- (void)testCentermostScreenIdentifierChoosesMiddleDisplay {
    NSArray *screens = @[
        @{@"id": @"left", @"left": @(-1920), @"top": @0, @"width": @1920, @"height": @1080},
        @{@"id": @"center", @"left": @0, @"top": @0, @"width": @1920, @"height": @1080},
        @{@"id": @"right", @"left": @1920, @"top": @0, @"width": @1920, @"height": @1080},
    ];
    XCTAssertEqualObjects([MatrixCodeSession centermostScreenIdentifierForDescriptors:screens], @"center");
}

- (void)testCentermostScreenIdentifierChoosesCenterOfTLayout {
    NSArray *screens = @[
        @{@"id": @"upper", @"left": @(-112), @"top": @0, @"width": @1920, @"height": @1200},
        @{@"id": @"left", @"left": @(-1920), @"top": @1200, @"width": @1920, @"height": @1200},
        @{@"id": @"center", @"left": @0, @"top": @1200, @"width": @1710, @"height": @1112},
        @{@"id": @"right", @"left": @1710, @"top": @1200, @"width": @1920, @"height": @1200},
    ];
    XCTAssertEqualObjects([MatrixCodeSession centermostScreenIdentifierForDescriptors:screens], @"center");
}

- (void)testDisplaySlicePreservesPartialCellAtMonitorBoundary {
    NSInteger firstCell = -1;
    CGFloat origin = [MatrixCodeSession localOriginForVirtualOffset:1920
                                                           cellSize:18
                                                          firstCell:&firstCell];
    XCTAssertEqual(firstCell, 106);
    XCTAssertEqualWithAccuracy(origin, -12, 0.001);

    // The next cells remain on the same global lattice rather than restarting
    // with a full glyph at the second display's left edge.
    XCTAssertEqualWithAccuracy(origin + 18, 6, 0.001);
}

- (void)testAlignedDisplayBoundaryStartsAtZeroOrigin {
    NSInteger firstCell = -1;
    CGFloat origin = [MatrixCodeSession localOriginForVirtualOffset:1800
                                                           cellSize:18
                                                          firstCell:&firstCell];
    XCTAssertEqual(firstCell, 100);
    XCTAssertEqualWithAccuracy(origin, 0, 0.001);
}

- (void)testTShapedFourDisplayLayoutSharesCellsAcrossUpperCenterSeam {
    // Regression geometry from the real arrangement:
    //
    //                upper 1920×1200 @ (-112, 1112)
    //   left 1920×1200   centre 1710×1112   right 1920×1200
    //      @ (-1920,-88)      @ (0,0)          @ (1710,-88)
    //
    // AppKit uses a bottom-left desktop origin. MatrixCode converts it to a
    // top-left virtual canvas before placing cells.
    const CGFloat desktopMaxY = 2312;
    NSRect upper = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(-112, 1112, 1920, 1200)
                                              desktopMaxY:desktopMaxY];
    NSRect center = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(0, 0, 1710, 1112)
                                               desktopMaxY:desktopMaxY];
    NSRect left = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(-1920, -88, 1920, 1200)
                                             desktopMaxY:desktopMaxY];
    NSRect right = [MatrixCodeSession topLeftRectForFrame:NSMakeRect(1710, -88, 1920, 1200)
                                              desktopMaxY:desktopMaxY];

    XCTAssertEqualWithAccuracy(NSMaxY(upper), NSMinY(center), 0.001);
    XCTAssertEqualWithAccuracy(NSMinY(center), NSMinY(left), 0.001);
    XCTAssertEqualWithAccuracy(NSMinY(center), NSMinY(right), 0.001);
    XCTAssertGreaterThan(NSWidth(NSIntersectionRect(
        NSMakeRect(NSMinX(upper), 0, NSWidth(upper), 1),
        NSMakeRect(NSMinX(center), 0, NSWidth(center), 1)
    )), 0);

    const CGFloat virtualMinX = -1920;
    const CGFloat cellSize = 18;
    NSInteger upperFirstRow = -1;
    NSInteger centerFirstRow = -1;
    CGFloat upperOriginY = [MatrixCodeSession localOriginForVirtualOffset:NSMinY(upper)
                                                                 cellSize:cellSize
                                                                firstCell:&upperFirstRow];
    CGFloat centerOriginY = [MatrixCodeSession localOriginForVirtualOffset:NSMinY(center)
                                                                  cellSize:cellSize
                                                                 firstCell:&centerFirstRow];
    XCTAssertEqual(upperFirstRow, 0);
    XCTAssertEqualWithAccuracy(upperOriginY, 0, 0.001);
    XCTAssertEqual(centerFirstRow, 66);
    XCTAssertEqualWithAccuracy(centerOriginY, -12, 0.001);

    // Global row 66 spans virtual y=1188…1206. Its top 12 points are drawn
    // at the bottom of the upper display and its remaining 6 points at the
    // top of the centre display: one cell, clipped into two physical slices.
    XCTAssertEqualWithAccuracy(66 * cellSize, NSMaxY(upper) - 12, 0.001);
    XCTAssertEqualWithAccuracy(centerOriginY + cellSize, 6, 0.001);

    // The shared x=0 desktop seam also resolves to the same global column on
    // both screens even though the upper display begins 112 points left.
    NSInteger upperFirstColumn = -1;
    NSInteger centerFirstColumn = -1;
    CGFloat upperOriginX = [MatrixCodeSession
        localOriginForVirtualOffset:NSMinX(upper) - virtualMinX
                           cellSize:cellSize
                          firstCell:&upperFirstColumn];
    CGFloat centerOriginX = [MatrixCodeSession
        localOriginForVirtualOffset:NSMinX(center) - virtualMinX
                           cellSize:cellSize
                          firstCell:&centerFirstColumn];
    XCTAssertEqual(upperFirstColumn, 100);
    XCTAssertEqual(centerFirstColumn, 106);
    XCTAssertEqualWithAccuracy(upperOriginX + (106 - upperFirstColumn) * cellSize, 100, 0.001);
    XCTAssertEqualWithAccuracy(centerOriginX, -12, 0.001);
}

- (void)testNilWindowScreenResolvesToOnlyUnclaimedMatchingDisplay {
    NSArray *descriptors = @[
        @{@"id": @"screen-1", @"width": @1710, @"height": @1112},
        @{@"id": @"screen-16", @"width": @1920, @"height": @1200},
        @{@"id": @"screen-17", @"width": @1920, @"height": @1200},
        @{@"id": @"screen-18", @"width": @1920, @"height": @1200},
    ];
    NSSet *claimed = [NSSet setWithArray:@[@"screen-1", @"screen-16", @"screen-18"]];
    XCTAssertEqualObjects(
        [MatrixCodeSession uniqueUnclaimedScreenIdentifierForSize:NSMakeSize(1920, 1200)
                                                       descriptors:descriptors
                                                           claimed:claimed],
        @"screen-17"
    );
}

- (void)testNilWindowScreenWaitsWhileMatchingDisplayIsAmbiguous {
    NSArray *descriptors = @[
        @{@"id": @"screen-16", @"width": @1920, @"height": @1200},
        @{@"id": @"screen-17", @"width": @1920, @"height": @1200},
        @{@"id": @"screen-18", @"width": @1920, @"height": @1200},
    ];
    XCTAssertNil(
        [MatrixCodeSession uniqueUnclaimedScreenIdentifierForSize:NSMakeSize(1920, 1200)
                                                       descriptors:descriptors
                                                           claimed:[NSSet setWithObject:@"screen-16"]]
    );
}

@end
