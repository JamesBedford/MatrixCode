#import <XCTest/XCTest.h>

#import "../AppSource/MatrixCodeAppDelegate.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainHostView.h"
#import "MatrixCodeSession.h"

@interface MatrixCodeAppDelegate (Testing)
- (void)setFPSOverlayVisible:(BOOL)visible
                forHostViews:(NSArray<MatrixCodeRainHostView *> *)hostViews;
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
