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

- (void)testRampEasePreservesJavaScriptNumberPrecision {
    const double progress = 0.200000000123;
    const double expected = 0.125 + (progress - 0.2) * 1.25;
    XCTAssertEqualWithAccuracy(MatrixCodeRainRampEase(progress), expected, 1e-13);
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

@end
