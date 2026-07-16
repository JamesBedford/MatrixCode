#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double MatrixCodeRainRampEase(double progress);
FOUNDATION_EXPORT NSInteger MatrixCodeRainDigitStartIndex(void);
FOUNDATION_EXPORT NSInteger MatrixCodeRainLatinStartIndex(void);
FOUNDATION_EXPORT NSInteger MatrixCodeRainSymbolsStartIndex(void);
FOUNDATION_EXPORT NSInteger MatrixCodeRainGlyphCount(void);
FOUNDATION_EXPORT NSInteger MatrixCodeRainGlyphIndex(uint32_t key, NSString *glyphMode);
FOUNDATION_EXPORT NSInteger MatrixCodeRainDigitValueForGlyphIndex(NSInteger glyphIndex,
                                                                  NSString *glyphMode);
