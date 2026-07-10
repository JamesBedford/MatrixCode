#import <XCTest/XCTest.h>

#import "MatrixCodeRainLifecycle.h"

@interface MatrixCodeRainLifecycleTests : XCTestCase
@end

@implementation MatrixCodeRainLifecycleTests

- (void)testRampMatchesWebEaseCurve {
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(0), 0, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(0.2), 0.125, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(0.5), 0.5, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(0.8), 0.875, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(1), 1, 0.0001);
}

- (void)testGlyphMixMatchesWebKatakanaWeightedDistribution {
    NSUInteger groups[4] = {0, 0, 0, 0};
    const NSUInteger samples = 100000;
    for (uint32_t key = 0; key < samples; key++) {
        NSInteger glyph = MatrixCodeRainGlyphIndex(key, @"matrix");
        XCTAssertGreaterThanOrEqual(glyph, 0);
        XCTAssertLessThan(glyph, MatrixCodeRainGlyphCount());
        if (glyph < MatrixCodeRainDigitStartIndex()) groups[0]++;
        else if (glyph < MatrixCodeRainLatinStartIndex()) groups[1]++;
        else if (glyph < MatrixCodeRainSymbolsStartIndex()) groups[2]++;
        else groups[3]++;
    }
    const double expected[4] = {0.80, 0.11, 0.05, 0.04};
    for (NSUInteger group = 0; group < 4; group++) {
        XCTAssertEqualWithAccuracy((double)groups[group] / samples, expected[group], 0.005);
    }
}

- (void)testBinaryGlyphModeOnlyPicksZeroAndOne {
    NSMutableSet<NSNumber *> *glyphs = [NSMutableSet set];
    for (uint32_t key = 0; key < 10000; key++) {
        NSInteger glyph = MatrixCodeRainGlyphIndex(key, @"binary");
        XCTAssertGreaterThanOrEqual(glyph, MatrixCodeRainDigitStartIndex());
        XCTAssertLessThanOrEqual(glyph, MatrixCodeRainDigitStartIndex() + 1);
        [glyphs addObject:@(glyph)];
    }
    XCTAssertEqual(glyphs.count, (NSUInteger)2);
}

- (void)testDigitValueMappingUsesSharedGlyphRanges {
    XCTAssertEqual(MatrixCodeRainDigitStartIndex(), 56);
    XCTAssertEqual(MatrixCodeRainLatinStartIndex(), 66);
    XCTAssertEqual(MatrixCodeRainSymbolsStartIndex(), 92);
    XCTAssertEqual(MatrixCodeRainGlyphCount(), 99);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(78, @"binary"), 0);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(87, @"binary"), 1);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(64, @"digits"), 8);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(-1, @"binary"), NSNotFound);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(99, @"binary"), NSNotFound);
    XCTAssertEqual(MatrixCodeRainDigitValueForGlyphIndex(56, @"matrix"), NSNotFound);
}

- (void)testTrailVariationPreservesCurrentDefaultAndCanNormalizeLengths {
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(3.5f, 1, 1), 3.5f, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(11.5f, 1, 1), 11.5f, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(3.5f, 1, 0), 7.5f, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(11.5f, 1, 0), 7.5f, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(11.5f, 1, 0.5f), 9.5f, 0.0001);
    XCTAssertEqualWithAccuracy(MatrixCodeRainEffectiveTrailSpeed(23.0f, 2, 0.5f), 19.0f, 0.0001);
}

- (void)testNewlyAdmittedStreamsEnterAboveVirtualDesktop {
    const float rampDuration = 8;
    for (uint32_t key = 1; key < 5000; key++) {
        MatrixCodeRainStreamSample before = MatrixCodeRainSampleStream(
            key, 0, 1, rampDuration, 150, 1, 1, 1);
        if (before.active) continue;
        for (float time = 0; time <= rampDuration; time += 0.01f) {
            float scale = MatrixCodeRainRampEase(time / rampDuration);
            MatrixCodeRainStreamSample sample = MatrixCodeRainSampleStream(
                key, time, scale, rampDuration, 150, 1, 1, 1);
            if (sample.active) {
                XCTAssertLessThanOrEqual(sample.headRow, 0.12f);
                break;
            }
        }
    }
}

- (void)testStreamNeverReappearsInsideVirtualDesktopAfterRespawn {
    uint32_t key = 42;
    BOOL wasActive = NO;
    for (float time = 0; time < 120; time += 0.01f) {
        MatrixCodeRainStreamSample sample = MatrixCodeRainSampleStream(
            key, time, 1, 8, 120, 1, 1, 1);
        if (sample.active && !wasActive) {
            XCTAssertLessThanOrEqual(sample.headRow, 0.12f);
        }
        wasActive = sample.active;
    }
}

- (void)testWarmStartPopulatesEveryVerticalDisplayRegion {
    NSUInteger regions[3] = {0, 0, 0};
    for (uint32_t key = 1; key <= 3000; key++) {
        MatrixCodeRainStreamSample sample = MatrixCodeRainSampleStream(
            key, 0, 1, 0, 150, 1, 1, 1);
        if (!sample.active || sample.headRow < 0 || sample.headRow >= 150) continue;
        regions[MIN(2, (NSUInteger)(sample.headRow / 50))]++;
    }
    XCTAssertGreaterThan(regions[0], (NSUInteger)100);
    XCTAssertGreaterThan(regions[1], (NSUInteger)100);
    XCTAssertGreaterThan(regions[2], (NSUInteger)100);
}

- (void)testStreamCrossesRealUpperCenterMonitorSeamContinuously {
    // In the real T-shaped layout the upper display ends at virtual y=1200.
    // With 18-point cells that seam cuts through global row 66 at row-space
    // position 66⅔. Use global column 106, shared by both physical displays.
    const float seamRow = 1200.0f / 18.0f;
    const float dt = 1.0f / 1000.0f;
    const uint32_t seed = 0x4d415452U;
    const uint32_t key = seed ^ (uint32_t)(106 * 0x9e3779b9U);
    MatrixCodeRainStreamSample previous = MatrixCodeRainSampleStream(
        key, 0, 1, 0, 129, 1, 1, 1);
    BOOL crossed = NO;

    for (float time = dt; time < 120; time += dt) {
        MatrixCodeRainStreamSample current = MatrixCodeRainSampleStream(
            key, time, 1, 0, 129, 1, 1, 1);
        if (previous.active && current.active &&
            previous.headRow < seamRow && current.headRow >= seamRow) {
            XCTAssertEqualWithAccuracy(current.headRow - previous.headRow,
                                       current.speed * dt, 0.0002);
            XCTAssertEqualWithAccuracy(current.speed, previous.speed, 0.0001);
            crossed = YES;
            break;
        }
        previous = current;
    }
    XCTAssertTrue(crossed, @"The shared stream should pass from the upper display into the centre");
}

@end
