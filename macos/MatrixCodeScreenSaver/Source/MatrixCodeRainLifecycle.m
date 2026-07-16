#import "MatrixCodeRainLifecycle.h"

static uint32_t MatrixCodeRainHash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    return value ^ (value >> 16);
}

static float MatrixCodeRainUnit(uint32_t value) {
    return (float)(MatrixCodeRainHash(value) & 0x00ffffffU) / 16777216.0f;
}

static NSInteger MatrixCodeRainPositiveModulo(NSInteger value, NSInteger modulus) {
    if (modulus <= 0) return 0;
    NSInteger result = value % modulus;
    return result < 0 ? result + modulus : result;
}

NSInteger MatrixCodeRainDigitStartIndex(void) {
    return 0xff9d - 0xff66 + 1;
}

NSInteger MatrixCodeRainLatinStartIndex(void) {
    return MatrixCodeRainDigitStartIndex() + 10;
}

NSInteger MatrixCodeRainSymbolsStartIndex(void) {
    return MatrixCodeRainLatinStartIndex() + 26;
}

NSInteger MatrixCodeRainGlyphCount(void) {
    return MatrixCodeRainSymbolsStartIndex() + 7;
}

NSInteger MatrixCodeRainDigitValueForGlyphIndex(NSInteger glyphIndex, NSString *glyphMode) {
    if (glyphIndex < 0 || glyphIndex >= MatrixCodeRainGlyphCount()) return NSNotFound;
    NSInteger offset = glyphIndex - MatrixCodeRainDigitStartIndex();
    if ([glyphMode isEqualToString:@"binary"]) return MatrixCodeRainPositiveModulo(offset, 2);
    if ([glyphMode isEqualToString:@"digits"]) return MatrixCodeRainPositiveModulo(offset, 10);
    return NSNotFound;
}

double MatrixCodeRainRampEase(double progress) {
    double p = fmin(1, fmax(0, progress));
    const double edge = 0.2;
    const double velocity = 1.0 / (1.0 - edge);
    if (p < edge) return velocity * p * p / (2.0 * edge);
    if (p > 1.0 - edge) {
        double remaining = 1.0 - p;
        return 1.0 - velocity * remaining * remaining / (2.0 * edge);
    }
    return velocity * edge / 2.0 + velocity * (p - edge);
}

NSInteger MatrixCodeRainGlyphIndex(uint32_t key, NSString *glyphMode) {
    float pick = MatrixCodeRainUnit(key ^ 0x68e31da4U);
    if ([glyphMode isEqualToString:@"binary"]) return MatrixCodeRainDigitStartIndex() + (NSInteger)(pick * 2);
    if ([glyphMode isEqualToString:@"katakana"]) return (NSInteger)(pick * MatrixCodeRainDigitStartIndex());
    if ([glyphMode isEqualToString:@"digits"]) return MatrixCodeRainDigitStartIndex() + (NSInteger)(pick * 10);
    if ([glyphMode isEqualToString:@"latin"]) return MatrixCodeRainLatinStartIndex() + (NSInteger)(pick * 26);
    if ([glyphMode isEqualToString:@"symbols"]) return MatrixCodeRainSymbolsStartIndex() + (NSInteger)(pick * 7);
    // Match the web glyph-set group weights: Katakana 80%, digits 11%,
    // Latin 5%, symbols 4%. A second hash chooses inside the selected group.
    float group = MatrixCodeRainUnit(key ^ 0xb5297a4dU);
    NSInteger start = 0;
    NSInteger count = MatrixCodeRainDigitStartIndex();
    if (group >= 0.96f) {
        start = MatrixCodeRainSymbolsStartIndex(); count = 7;
    } else if (group >= 0.91f) {
        start = MatrixCodeRainLatinStartIndex(); count = 26;
    } else if (group >= 0.80f) {
        start = MatrixCodeRainDigitStartIndex(); count = 10;
    }
    return start + (NSInteger)(pick * count);
}
