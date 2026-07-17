#import "MatrixCodeMetalView.h"

#import <CoreText/CoreText.h>
#import <CoreVideo/CoreVideo.h>
#import <float.h>
#import <simd/simd.h>
#import <stddef.h>
#import <string.h>

#import "MatrixCodeConstants.h"
#import "MatrixCodeAdaptiveResolution.h"
#import "MatrixCodeSession.h"
#import "MatrixCodeMessageScheduler.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeRainSimulation.h"
#import "MatrixCodeTokenResolver.h"

typedef struct {
    vector_float2 origin;
    vector_float2 size;
    vector_float2 atlasOrigin;
    vector_float2 atlasSize;
    vector_float2 oldAtlasOrigin;
    float crossfade;
    float brightness;
    float isHead;
    float whiteHead;
} MatrixCodeGlyphInstance;

typedef struct {
    vector_float2 viewport;
    vector_float3 tailColor;
    float padding0;
    vector_float3 bodyColor;
    float padding1;
    vector_float3 brightColor;
    float padding2;
    vector_float3 headColor;
    float padding3;
    float glow;
    float vignette;
    float scanlines;
    float leadBrightness;
    vector_float3 backgroundColor;
} MatrixCodeUniforms;

// MatrixCodeShaders.msl declares these structs a second time and is compiled
// from source at runtime, so a field added or removed on one side only would
// silently reinterpret every subsequent field rather than fail to build. Sizes
// alone do not pin the layout — trailing scalars land in padding that a float3's
// 16-byte alignment already reserves — so each offset is asserted individually.
_Static_assert(sizeof(MatrixCodeGlyphInstance) == 56,
               "MatrixCodeGlyphInstance must match MatrixCodeShaders.msl");
_Static_assert(offsetof(MatrixCodeGlyphInstance, origin) == 0, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, size) == 8, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, atlasOrigin) == 16, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, atlasSize) == 24, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, oldAtlasOrigin) == 32, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, crossfade) == 40, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, brightness) == 44, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, isHead) == 48, "layout drift");
_Static_assert(offsetof(MatrixCodeGlyphInstance, whiteHead) == 52, "layout drift");

_Static_assert(sizeof(MatrixCodeUniforms) == 176,
               "MatrixCodeUniforms must match MatrixCodeShaders.msl");
_Static_assert(offsetof(MatrixCodeUniforms, viewport) == 0, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, tailColor) == 16, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, bodyColor) == 48, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, brightColor) == 80, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, headColor) == 112, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, glow) == 132, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, vignette) == 136, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, scanlines) == 140, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, leadBrightness) == 144, "layout drift");
_Static_assert(offsetof(MatrixCodeUniforms, backgroundColor) == 160, "layout drift");

typedef struct {
    vector_float2 direction;
} MatrixCodeBlurUniforms;

static const float MatrixCodeBloomSpread = 1.8f;
static const size_t MatrixCodeAtlasCellPixels = 64;
static const uint32_t MatrixCodeNormalRainSeed = 0x1a2b3cU;
static const uint32_t MatrixCodeRainLaneSeedMultiplier = 0x9e3779b9U;
static const NSInteger MatrixCodeMaximumRainLanes = 8;
static const double MatrixCodeOverlapOnsetDensity = 20;
static const double MatrixCodeMaximumDensity = 100;
static const NSTimeInterval MatrixCodeRainWarmupSeconds = 2.5;
static const NSTimeInterval MatrixCodeRainFixedStepSeconds = 1.0 / 60.0;
static const NSTimeInterval MatrixCodeMaximumFrameCatchupSeconds = 0.25;
static const NSTimeInterval MatrixCodeMaximumSimulationStepSeconds = 1.0 / 15.0;
static const uint8_t MatrixCodePackedHeadFlag = 0x80;
static const uint8_t MatrixCodePackedWhiteHeadFlag = 0x40;
static const uint8_t MatrixCodePackedPhaseMask = 0x3f;

typedef struct {
    NSInteger index;
    double offset;
    double density;
    double weight;
} MatrixCodeRainLane;

static double MatrixCodeVanDerCorput(NSUInteger value);

static NSInteger MatrixCodeBloomLevelCount(NSString *quality) {
    if ([quality isEqualToString:@"low"]) return 1;
    if ([quality isEqualToString:@"med"]) return 2;
    return 3;
}

static NSInteger MatrixCodeAtlasColumnCount(NSInteger glyphCount) {
    return MAX(1, (NSInteger)ceil(sqrt((double)MAX(1, glyphCount))));
}

static NSInteger MatrixCodeNormalGridDimension(double points, double cellPoints) {
    return MAX(8, (NSInteger)lround(points / fmax(cellPoints, DBL_EPSILON)));
}

static uint32_t MatrixCodeRainSeedForLane(uint32_t baseSeed, NSInteger laneIndex) {
    return baseSeed ^ ((uint32_t)laneIndex * MatrixCodeRainLaneSeedMultiplier);
}

static NSInteger MatrixCodeRainLaneCap(NSString *quality) {
    if ([quality isEqualToString:@"low"]) return 2;
    if ([quality isEqualToString:@"med"]) return 4;
    return MatrixCodeMaximumRainLanes;
}

static NSInteger MatrixCodeComputeRainLanes(double density,
                                            BOOL allowOverlap,
                                            NSInteger laneCap,
                                            MatrixCodeRainLane lanes[8]) {
    lanes[0] = (MatrixCodeRainLane){
        .index = 0,
        .offset = 0,
        .density = density,
        .weight = 1,
    };
    if (!allowOverlap || density <= MatrixCodeOverlapOnsetDensity) return 1;

    lanes[0].density = MatrixCodeOverlapOnsetDensity;
    // Subdivision doublings available before the lane budget is spent: 1 -> 2 -> 4 -> 8.
    const double maximumLevel = log2((double)MatrixCodeMaximumRainLanes);
    double level = fmin(maximumLevel, fmax(0,
        maximumLevel * (density - MatrixCodeOverlapOnsetDensity) /
            (MatrixCodeMaximumDensity - MatrixCodeOverlapOnsetDensity)));
    NSInteger full = 1 << (NSInteger)floor(level);
    double fade = level - floor(level);
    NSInteger count = 1;
    for (NSInteger index = 1; index < full && count < laneCap; index++) {
        lanes[count++] = (MatrixCodeRainLane){
            .index = index,
            .offset = MatrixCodeVanDerCorput((NSUInteger)index),
            .density = MatrixCodeOverlapOnsetDensity,
            .weight = 1,
        };
    }
    if (fade > 1e-6 && full < MatrixCodeMaximumRainLanes) {
        for (NSInteger index = full; index < full * 2 && count < laneCap; index++) {
            lanes[count++] = (MatrixCodeRainLane){
                .index = index,
                .offset = MatrixCodeVanDerCorput((NSUInteger)index),
                .density = MatrixCodeOverlapOnsetDensity,
                .weight = fade,
            };
        }
    }
    return count;
}

static NSDictionary<NSString *, id> *MatrixCodeRainControlsWithDensity(
    NSDictionary<NSString *, id> *controls,
    double density
) {
    id current = controls[@"density"];
    if ([current isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)current) != CFBooleanGetTypeID() &&
        [current doubleValue] == density) {
        return controls;
    }
    NSMutableDictionary<NSString *, id> *laneControls = [controls mutableCopy];
    laneControls[@"density"] = @(density);
    return laneControls;
}

static NSInteger MatrixCodeSimulationStepPlan(NSTimeInterval elapsed,
                                               NSTimeInterval *deltaTime) {
    if (!isfinite(elapsed) || elapsed <= 0) {
        if (deltaTime) *deltaTime = 0;
        return 0;
    }
    NSTimeInterval bounded = MIN(elapsed, MatrixCodeMaximumFrameCatchupSeconds);
    NSInteger steps = (NSInteger)ceil(bounded / MatrixCodeMaximumSimulationStepSeconds);
    if (deltaTime) *deltaTime = bounded / MAX((NSInteger)1, steps);
    return steps;
}

static uint32_t MatrixCodeHash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    return value ^ (value >> 16);
}

static float MatrixCodeUnit(uint32_t value) {
    return (float)(MatrixCodeHash(value) & 0x00ffffffU) / 16777216.0f;
}

static double MatrixCodeVanDerCorput(NSUInteger value) {
    double result = 0;
    double denominator = 1;
    while (value > 0) {
        denominator *= 2;
        result += (value % 2) / denominator;
        value /= 2;
    }
    return result;
}

static uint32_t MatrixCodeCellIdentity(uint32_t laneSeed, NSInteger globalColumn, NSInteger globalRow) {
    uint32_t column = (uint32_t)(int32_t)globalColumn;
    uint32_t row = (uint32_t)(int32_t)globalRow;
    return MatrixCodeHash(laneSeed ^ column * 73856093U ^ row * 19349663U);
}

static double MatrixCodeNumber(NSDictionary *dictionary,
                               NSString *key,
                               double fallback,
                               double minimum,
                               double maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) return fallback;
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

static BOOL MatrixCodeBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        ? [value boolValue] : fallback;
}

static NSDictionary<NSString *, id> *MatrixCodeDefaultMessages(void) {
    return @{
        @"messages": @[@"WAKE UP", @"THE MATRIX HAS YOU", @"FOLLOW THE WHITE RABBIT", @"{countup}"],
        @"enabled": @NO,
        @"frequencyMs": @8000,
        @"persistenceMs": @10000,
        @"appearMs": @4000,
        @"disappearMs": @4000,
        @"flickerOut": @YES,
        @"brightnessFade": @NO,
        @"messageLayout": @"row",
        @"messageDirection": @"topToBottom",
        @"verticalPosition": @0.475,
        @"verticalJitter": @0.25,
    };
}

static NSDictionary<NSString *, id> *MatrixCodeStoredMessagesDocument(
    NSDictionary<NSString *, NSString *> *storedValues
) {
    NSString *raw = storedValues[@"mx-messages"];
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id object = data
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (!object) return nil;
    return MatrixCodeSanitizeMessagesDocument(
        [object isKindOfClass:NSDictionary.class] ? object : @{});
}

static NSMutableDictionary *MatrixCodeSanitizedRenderImageItem(id item) {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dictionary = item;
    NSInteger width = (NSInteger)MatrixCodeNumber(dictionary, @"width", 0, 1, 128);
    NSInteger height = (NSInteger)MatrixCodeNumber(dictionary, @"height", 0, 1, 128);
    if (width <= 0 || height <= 0) return nil;
    id rawData = dictionary[@"data"];
    if (![rawData isKindOfClass:NSString.class]) return nil;
    NSString *encoded = rawData;
    if (encoded.length > 49152) return nil;
    NSData *mask = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!mask || mask.length != (NSUInteger)(width * height)) return nil;
    NSString *name = [dictionary[@"name"] isKindOfClass:NSString.class]
        ? dictionary[@"name"] : @"Image";
    return [@{
        @"name": [name substringToIndex:MIN((NSUInteger)80, name.length)],
        @"width": @(width),
        @"height": @(height),
        @"data": encoded,
    } mutableCopy];
}

static NSArray<NSDictionary *> *MatrixCodeSanitizedRenderImages(NSDictionary *dictionary) {
    NSArray *configured = [dictionary[@"images"] isKindOfClass:NSArray.class]
        ? dictionary[@"images"] : @[];
    NSMutableArray<NSDictionary *> *images = [NSMutableArray array];
    for (NSUInteger index = 0; index < configured.count; index++) {
        NSMutableDictionary *image = MatrixCodeSanitizedRenderImageItem(configured[index]);
        if (image) [images addObject:image];
    }
    return images;
}

static float MatrixCodeImageSampleMask(NSData *mask, NSInteger width, NSInteger height, float u, float v) {
    if (!mask || width <= 0 || height <= 0 ||
        mask.length != (NSUInteger)(width * height) ||
        u < 0 || u > 1 || v < 0 || v > 1) {
        return 0;
    }
    const uint8_t *bytes = mask.bytes;
    float x = fminf(width - 1, fmaxf(0, u * (width - 1)));
    float y = fminf(height - 1, fmaxf(0, v * (height - 1)));
    NSInteger x0 = (NSInteger)floorf(x);
    NSInteger y0 = (NSInteger)floorf(y);
    NSInteger x1 = MIN(width - 1, x0 + 1);
    NSInteger y1 = MIN(height - 1, y0 + 1);
    float tx = x - x0;
    float ty = y - y0;
    float a = bytes[y0 * width + x0] / 255.0f;
    float b = bytes[y0 * width + x1] / 255.0f;
    float c = bytes[y1 * width + x0] / 255.0f;
    float d = bytes[y1 * width + x1] / 255.0f;
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
}

static float MatrixCodeSmoothstep(float edge0, float edge1, float value) {
    if (edge0 == edge1) return value < edge0 ? 0 : 1;
    float t = fminf(1, fmaxf(0, (value - edge0) / (edge1 - edge0)));
    return t * t * (3.0f - 2.0f * t);
}

#if DEBUG
static float MatrixCodeStepChanceForReferenceRateChance(float chance,
                                                        float elapsed,
                                                        float referenceRate) {
    float p = fminf(1, fmaxf(0, chance));
    if (p <= 0 || elapsed <= 0 || referenceRate <= 0) return 0;
    if (p >= 1) return 1;
    return 1.0f - expf(logf(1.0f - p) * referenceRate * elapsed);
}
#endif

static float MatrixCodeImageSignalForLuminance(float luminance) {
    float value = fminf(1, fmaxf(0, luminance));
    float nonEmpty = MatrixCodeSmoothstep(0.035f, 0.12f, value);
    float contrastSignal = fabsf(value - 0.5f) * 2.0f * nonEmpty;
    float brightSignal = value * 0.72f;
    return fmaxf(contrastSignal, brightSignal) * nonEmpty;
}

static float MatrixCodeImageEdgeFeather(float u, float v, float featherU, float featherV) {
    float horizontal = fminf(MatrixCodeSmoothstep(0, featherU, u),
                             MatrixCodeSmoothstep(0, featherU, 1.0f - u));
    float vertical = fminf(MatrixCodeSmoothstep(0, featherV, v),
                           MatrixCodeSmoothstep(0, featherV, 1.0f - v));
    return horizontal * vertical;
}

static float MatrixCodeImageFallingGate(NSInteger globalColumn,
                                        NSInteger globalRow,
                                        float rainElapsed,
                                        uint32_t seed) {
    uint32_t columnKey = seed ^ (uint32_t)(int32_t)globalColumn * 0x9e3779b9U ^ 0x748f4a15U;
    float speed = 4.5f + MatrixCodeUnit(columnKey ^ 0x85ebca6bU) * 8.0f;
    float span = 9.0f + MatrixCodeUnit(columnKey ^ 0x27d4eb2dU) * 12.0f;
    float offset = MatrixCodeUnit(columnKey ^ 0xd3a2646cU) * span;
    float phase = fmodf((float)globalRow - rainElapsed * speed + offset, span);
    if (phase < 0) phase += span;
    float head = expf(-phase * 0.55f);
    float afterglow = phase < span * 0.42f ? powf(1.0f - phase / (span * 0.42f), 2.0f) : 0;
    return fminf(1, fmaxf(head, afterglow * 0.65f));
}

static NSInteger MatrixCodeImageGlyphForLuminance(float luminance,
                                                  uint32_t key,
                                                  NSString *glyphMode) {
    float value = fminf(1, fmaxf(0, luminance));
    NSInteger level = MIN(6, MAX(0, (NSInteger)floorf(value * 7.0f)));
    if ([glyphMode isEqualToString:@"binary"]) {
        return MatrixCodeRainDigitStartIndex() + (value >= 0.58f ? 0 : 1);
    }
    if ([glyphMode isEqualToString:@"digits"]) {
        static const NSInteger digits[7] = {1, 7, 4, 2, 5, 8, 0};
        return MatrixCodeRainDigitStartIndex() + digits[level];
    }
    if ([glyphMode isEqualToString:@"latin"]) {
        static const NSInteger letters[7] = {8, 11, 19, 0, 13, 12, 22};
        return MatrixCodeRainLatinStartIndex() + letters[level];
    }
    if ([glyphMode isEqualToString:@"symbols"]) {
        static const NSInteger symbols[7] = {1, 6, 4, 5, 2, 3, 0};
        return MatrixCodeRainSymbolsStartIndex() + symbols[level];
    }
    if ([glyphMode isEqualToString:@"katakana"]) {
        return (NSInteger)(MatrixCodeUnit(key ^ (uint32_t)level * 0x45d9f3bU) *
            MatrixCodeRainDigitStartIndex());
    }
    if (value < 0.16f) return MatrixCodeRainSymbolsStartIndex() + 1;
    if (value < 0.32f) return MatrixCodeRainDigitStartIndex() + 1;
    if (value < 0.48f) return MatrixCodeRainLatinStartIndex() + 8;
    if (value < 0.64f) return MatrixCodeRainLatinStartIndex() + 12;
    return (NSInteger)(MatrixCodeUnit(key ^ (uint32_t)level * 0x45d9f3bU) *
        MatrixCodeRainDigitStartIndex());
}

static NSString *MatrixCodeGlyphMode(NSDictionary *dictionary) {
    id value = dictionary[@"glyphMode"];
    NSArray<NSString *> *modes = @[@"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols"];
    return [value isKindOfClass:NSString.class] && [modes containsObject:value] ? value : @"matrix";
}

static NSString *MatrixCodeGlyphFont(NSDictionary *dictionary) {
    id value = dictionary[@"glyphFont"];
    NSArray<NSString *> *fonts = @[@"matrix", @"gothic", @"mono", @"terminal", @"rounded", @"mincho"];
    return [value isKindOfClass:NSString.class] && [fonts containsObject:value] ? value : @"matrix";
}

static NSDictionary<NSString *, NSArray<NSString *> *> *MatrixCodeGlyphFontStacks(void) {
    return @{
        // CoreText PostScript-name equivalents of src/config/glyphFonts.ts,
        // ordered like the browser stacks. Chromium maps CSS weight 500 to
        // Hiragino's W3 face; W6 starts at CSS weight 600.
        @"matrix": @[@"HiraKakuProN-W3", @"HiraKakuPro-W3",
                      @"YuGothic-Medium", @"HiraginoSans-W3", @"Menlo-Regular"],
        @"gothic": @[@"YuGothic-Medium", @"HiraKakuProN-W3",
                      @"HiraginoSans-W3", @"Menlo-Regular"],
        @"mono": @[@"SFMono-Regular", @"Menlo-Regular", @"Consolas",
                    @"LiberationMono", @"HiraginoSans-W3"],
        @"terminal": @[@"CourierNewPSMT", @"Menlo-Regular", @"Monaco",
                        @"HiraginoSans-W3"],
        @"rounded": @[@"HiraMaruProN-W4", @"ArialRoundedMTBold",
                       @"YuGothic-Medium", @"HiraginoSans-W3"],
        @"mincho": @[@"HiraMinProN-W3", @"YuMincho-Regular",
                      @"HiraMinProN-W6", @"TimesNewRomanPSMT"],
    };
}

static CTFontRef MatrixCodeCreateFontWithFallbacks(NSArray<NSString *> *fallbacks, CGFloat size) {
    for (NSString *name in fallbacks) {
        CTFontRef candidate = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
        if (!candidate) continue;
        CFStringRef resolvedName = CTFontCopyPostScriptName(candidate);
        BOOL exactMatch = resolvedName &&
            [(__bridge NSString *)resolvedName caseInsensitiveCompare:name] == NSOrderedSame;
        if (resolvedName) CFRelease(resolvedName);
        if (exactMatch) return candidate;
        // CTFontCreateWithName silently substitutes the system face for an
        // unavailable name. Reject that substitution so the next CSS-stack
        // equivalent is actually considered.
        CFRelease(candidate);
    }
    return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
}

#if DEBUG
static NSString *MatrixCodeResolvedPostScriptName(CTFontRef font) {
    if (!font) return @"";
    CFStringRef name = CTFontCopyPostScriptName(font);
    return name ? CFBridgingRelease(name) : @"";
}
#endif

static NSArray<NSString *> *MatrixCodeReadableDigitFontStack(void) {
    return @[@"SFMono-Regular", @"Menlo-Regular", @"Consolas", @"LiberationMono",
             @"CourierNewPSMT"];
}

static CTFontRef MatrixCodeCreateGlyphFont(NSDictionary *dictionary, CGFloat size) {
    NSString *glyphMode = MatrixCodeGlyphMode(dictionary);
    if ([glyphMode isEqualToString:@"binary"] ||
        [glyphMode isEqualToString:@"digits"]) {
        return MatrixCodeCreateFontWithFallbacks(MatrixCodeReadableDigitFontStack(), size);
    }
    NSString *font = MatrixCodeGlyphFont(dictionary);
    NSArray<NSString *> *stack = MatrixCodeGlyphFontStacks()[font] ?:
        MatrixCodeGlyphFontStacks()[@"matrix"];
    return MatrixCodeCreateFontWithFallbacks(stack, size);
}

static CTFontRef MatrixCodeCreateReadableDigitFont(NSDictionary *dictionary, CGFloat size) {
    (void)dictionary;
    return MatrixCodeCreateFontWithFallbacks(MatrixCodeReadableDigitFontStack(), size);
}

static BOOL MatrixCodeGlyphModeUsesReadableDigits(NSDictionary *dictionary) {
    NSString *glyphMode = MatrixCodeGlyphMode(dictionary);
    return [glyphMode isEqualToString:@"binary"] || [glyphMode isEqualToString:@"digits"];
}

static BOOL MatrixCodeGlyphStringIsDigit(NSString *glyph) {
    if (glyph.length != 1) return NO;
    unichar character = [glyph characterAtIndex:0];
    return character >= '0' && character <= '9';
}

static BOOL MatrixCodeShouldDrawReadableDigitGlyph(NSString *glyph, NSDictionary *controls) {
    return MatrixCodeGlyphModeUsesReadableDigits(controls) && MatrixCodeGlyphStringIsDigit(glyph);
}

static NSString *MatrixCodeAtlasDisplayGlyph(NSString *glyph,
                                             NSUInteger index,
                                             NSUInteger rainGlyphCount,
                                             NSDictionary *controls) {
    if (index >= rainGlyphCount) return glyph;
    NSInteger digit = MatrixCodeRainDigitValueForGlyphIndex((NSInteger)index,
                                                            MatrixCodeGlyphMode(controls));
    if (digit != NSNotFound) {
        unichar character = (unichar)('0' + digit);
        return [NSString stringWithCharacters:&character length:1];
    }
    return glyph;
}

static float MatrixCodeProceduralDigitValueForRainGlyphMode(NSInteger glyph,
                                                            NSInteger rainGlyphCount,
                                                            NSString *glyphMode) {
    if (glyph < 0 || glyph >= rainGlyphCount) return -1;
    NSInteger digit = MatrixCodeRainDigitValueForGlyphIndex(glyph, glyphMode);
    return digit == NSNotFound ? -1 : (float)digit;
}

static BOOL MatrixCodeDigitSegments(unichar digit, BOOL segments[7]) {
    static const BOOL segmentMap[10][7] = {
        {YES, YES, YES, YES, YES, YES, NO},
        {NO, YES, YES, NO, NO, NO, NO},
        {YES, YES, NO, YES, YES, NO, YES},
        {YES, YES, YES, YES, NO, NO, YES},
        {NO, YES, YES, NO, NO, YES, YES},
        {YES, NO, YES, YES, NO, YES, YES},
        {YES, NO, YES, YES, YES, YES, YES},
        {YES, YES, YES, NO, NO, NO, NO},
        {YES, YES, YES, YES, YES, YES, YES},
        {YES, YES, YES, YES, NO, YES, YES},
    };
    if (digit < '0' || digit > '9') return NO;
    memcpy(segments, segmentMap[digit - '0'], sizeof(segmentMap[0]));
    return YES;
}

static void MatrixCodeFillHorizontalSegment(CGContextRef context,
                                             CGFloat left,
                                             CGFloat right,
                                             CGFloat centerY,
                                             CGFloat thickness) {
    CGFloat capInset = thickness * 0.5;
    CGContextFillRect(context, CGRectMake(left + capInset,
                                          centerY - thickness * 0.5,
                                          right - left - capInset * 2,
                                          thickness));
}

static void MatrixCodeFillVerticalSegment(CGContextRef context,
                                           CGFloat centerX,
                                           CGFloat minY,
                                           CGFloat maxY,
                                           CGFloat thickness) {
    CGFloat capInset = thickness * 0.5;
    CGContextFillRect(context, CGRectMake(centerX - thickness * 0.5,
                                          minY + capInset,
                                          thickness,
                                          maxY - minY - capInset * 2));
}

static void MatrixCodeDrawReadableDigitGlyph(CGContextRef context, NSString *glyph, CGRect cellRect) {
    if (!MatrixCodeGlyphStringIsDigit(glyph)) return;
    unichar digit = [glyph characterAtIndex:0];
    BOOL segments[7] = {NO};
    if (!MatrixCodeDigitSegments(digit, segments)) return;

    CGFloat cell = MIN(cellRect.size.width, cellRect.size.height);
    CGFloat margin = cell * 0.2;
    CGFloat thickness = MAX((CGFloat)3.0, cell * 0.12);
    CGFloat left = CGRectGetMinX(cellRect) + margin;
    CGFloat right = CGRectGetMaxX(cellRect) - margin;
    CGFloat bottom = CGRectGetMinY(cellRect) + margin;
    CGFloat top = CGRectGetMaxY(cellRect) - margin;
    CGFloat middle = CGRectGetMidY(cellRect);
    CGContextSetGrayFillColor(context, 1, 1);

    if (digit == '0') {
        CGContextSetGrayStrokeColor(context, 1, 1);
        CGContextSetLineWidth(context, thickness);
        CGContextStrokeEllipseInRect(context, CGRectInset(cellRect,
                                                          margin + thickness * 0.5,
                                                          margin + thickness * 0.5));
        return;
    }

    if (digit == '1') {
        CGFloat centerX = CGRectGetMidX(cellRect);
        CGContextFillRect(context, CGRectMake(centerX - thickness * 0.5,
                                              bottom,
                                              thickness,
                                              top - bottom));
        CGContextFillRect(context, CGRectMake(centerX - thickness * 1.2,
                                              top - thickness,
                                              thickness * 1.7,
                                              thickness));
        CGContextFillRect(context, CGRectMake(centerX - thickness * 1.4,
                                              bottom,
                                              thickness * 2.8,
                                              thickness));
        return;
    }

    if (segments[0]) MatrixCodeFillHorizontalSegment(context, left, right, top, thickness);
    if (segments[1]) MatrixCodeFillVerticalSegment(context, right, middle, top, thickness);
    if (segments[2]) MatrixCodeFillVerticalSegment(context, right, bottom, middle, thickness);
    if (segments[3]) MatrixCodeFillHorizontalSegment(context, left, right, bottom, thickness);
    if (segments[4]) MatrixCodeFillVerticalSegment(context, left, bottom, middle, thickness);
    if (segments[5]) MatrixCodeFillVerticalSegment(context, left, middle, top, thickness);
    if (segments[6]) MatrixCodeFillHorizontalSegment(context, left, right, middle, thickness);
}

#if DEBUG
static NSString *MatrixCodePrimaryAtlasFontNameForGlyph(NSString *glyph, NSDictionary *controls) {
    CTFontRef font = MatrixCodeShouldDrawReadableDigitGlyph(glyph, controls)
        ? MatrixCodeCreateReadableDigitFont(controls, 12)
        : MatrixCodeCreateGlyphFont(controls, 12);
    NSString *resolvedName = MatrixCodeResolvedPostScriptName(font);
    if (font) CFRelease(font);
    return resolvedName;
}
#endif

static double MatrixCodeVignette(NSDictionary *dictionary) {
    id value = dictionary[@"vignette"];
    if ([value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return [value boolValue] ? 0.42f : 0;
    }
    return MatrixCodeNumber(dictionary, @"vignette", 0, 0, 1);
}

static BOOL MatrixCodeMessagesUseLocalCoordinates(NSDictionary *session,
                                                  NSDictionary *controls) {
    NSArray *screens = [session[@"screens"] isKindOfClass:NSArray.class]
        ? session[@"screens"] : @[];
    if (screens.count > 1) {
        id capturedMode = session[@"perDisplayMessages"];
        if ([capturedMode isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)capturedMode) == CFBooleanGetTypeID()) {
            return [capturedMode boolValue];
        }
    }
    return MatrixCodeVignette(controls) > 0;
}

static BOOL MatrixCodeAdaptiveResolutionIsEnabled(NSDictionary *session) {
    id sessionValue = session[@"adaptive"];
    if ([sessionValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)sessionValue) == CFBooleanGetTypeID()) {
        return [sessionValue boolValue];
    }
    if ([NSProcessInfo.processInfo.environment[@"MATRIXCODE_ADAPTIVE"]
            isEqualToString:@"0"]) {
        return NO;
    }
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument isEqualToString:@"adaptive=0"] ||
            [argument isEqualToString:@"?adaptive=0"] ||
            [argument isEqualToString:@"--adaptive=0"]) {
            return NO;
        }
    }
    return YES;
}

static vector_float3 MatrixCodeRGB(uint32_t rgb) {
    return (vector_float3){
        ((rgb >> 16) & 0xff) / 255.0f,
        ((rgb >> 8) & 0xff) / 255.0f,
        (rgb & 0xff) / 255.0f,
    };
}

static void MatrixCodeConsiderRefreshRate(double refreshRate, double *best) {
    if (!isfinite(refreshRate) || refreshRate < 24) return;
    *best = fmax(*best, refreshRate);
}

static NSInteger MatrixCodeFramesPerSecondFromCandidates(NSInteger screenMaximum,
                                                         double displayModeRefreshRate,
                                                         double displayLinkRefreshRate) {
    double best = 0;
    MatrixCodeConsiderRefreshRate(displayModeRefreshRate, &best);
    MatrixCodeConsiderRefreshRate(displayLinkRefreshRate, &best);
    if (best <= 0) MatrixCodeConsiderRefreshRate(screenMaximum, &best);
    if (best <= 0) best = 60;
    return MIN(240, MAX(60, (NSInteger)lround(best)));
}

static CGDirectDisplayID MatrixCodeDisplayIDForScreen(NSScreen *screen) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    return [number respondsToSelector:@selector(unsignedIntValue)] ? number.unsignedIntValue : 0;
}

static double MatrixCodeDisplayModeRefreshRate(NSScreen *screen) {
    CGDirectDisplayID displayID = MatrixCodeDisplayIDForScreen(screen);
    if (displayID == 0) return 0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    double refreshRate = mode ? CGDisplayModeGetRefreshRate(mode) : 0;
    if (mode) CGDisplayModeRelease(mode);
    return refreshRate;
}

static double MatrixCodeDisplayLinkRefreshRate(NSScreen *screen) {
    CGDirectDisplayID displayID = MatrixCodeDisplayIDForScreen(screen);
    if (displayID == 0) return 0;
    CVDisplayLinkRef displayLink = NULL;
    CVReturn result = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink);
    if (result != kCVReturnSuccess || !displayLink) return 0;
    CVTime period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink);
    CVDisplayLinkRelease(displayLink);
    if (period.timeValue <= 0 || period.timeScale <= 0) return 0;
    return (double)period.timeScale / (double)period.timeValue;
}

static NSInteger MatrixCodeDisplayFramesPerSecond(NSScreen *screen) {
    NSScreen *resolvedScreen = screen ?: NSScreen.mainScreen;
    NSInteger screenMaximum = resolvedScreen.maximumFramesPerSecond;
    return MatrixCodeFramesPerSecondFromCandidates(screenMaximum,
                                                   MatrixCodeDisplayModeRefreshRate(resolvedScreen),
                                                   MatrixCodeDisplayLinkRefreshRate(resolvedScreen));
}

static NSInteger MatrixCodeSessionPreferredFramesPerSecond(NSDictionary<NSString *, id> *session) {
    NSNumber *value = [session[@"preferredFramesPerSecond"] isKindOfClass:NSNumber.class]
        ? session[@"preferredFramesPerSecond"] : nil;
    if (!value) return 0;
    NSInteger framesPerSecond = value.integerValue;
    return framesPerSecond > 0 ? MIN(240, MAX(1, framesPerSecond)) : 0;
}

static id<MTLRenderPipelineState> MatrixCodeCreateRenderPipeline(
    id<MTLDevice> device,
    id<MTLLibrary> library,
    NSString *vertexName,
    NSString *fragmentName,
    MTLPixelFormat pixelFormat,
    BOOL additive,
    NSError **error
) {
    id<MTLFunction> vertexFunction = [library newFunctionWithName:vertexName];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:fragmentName];
    if (!vertexFunction || !fragmentFunction) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;
    if (additive) {
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    }
    return [device newRenderPipelineStateWithDescriptor:descriptor error:error];
}

static id<MTLTexture> MatrixCodeCreateRenderTarget(id<MTLDevice> device,
                                                   MTLPixelFormat pixelFormat,
                                                   NSUInteger width,
                                                   NSUInteger height) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                           width:MAX((NSUInteger)1, width)
                                                          height:MAX((NSUInteger)1, height)
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [device newTextureWithDescriptor:descriptor];
}

static MTLRenderPassDescriptor *MatrixCodePassDescriptor(id<MTLTexture> target,
                                                         MTLLoadAction loadAction,
                                                         MTLClearColor clearColor) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = loadAction;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = clearColor;
    return pass;
}

@interface MatrixCodeMetalView () <MTKViewDelegate>
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> brightPassPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> blurPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> resamplePipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> additiveCopyPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> compositePipeline;
@property(nonatomic, strong) id<MTLTexture> atlas;
@property(nonatomic, strong) id<MTLTexture> sceneTexture;
@property(nonatomic, copy) NSArray<id<MTLTexture>> *bloomMainTextures;
@property(nonatomic, copy) NSArray<id<MTLTexture>> *bloomTemporaryTextures;
@property(nonatomic) NSUInteger renderTargetWidth;
@property(nonatomic) NSUInteger renderTargetHeight;
@property(nonatomic) NSInteger renderTargetBloomLevelCount;
@property(nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property(nonatomic, copy) NSArray<id<MTLBuffer>> *instanceBuffers;
@property(nonatomic) NSUInteger instanceBufferIndex;
@property(nonatomic) NSUInteger instanceCapacity;
@property(nonatomic) NSUInteger instanceCount;
@property(nonatomic) MatrixCodeUniforms uniforms;
@property(nonatomic, copy) NSDictionary<NSString *, id> *controls;
@property(nonatomic, copy) NSDictionary<NSString *, id> *session;
@property(nonatomic) uint32_t seed;
@property(nonatomic) NSTimeInterval epochSeconds;
@property(nonatomic) NSTimeInterval tokenRunStartSeconds;
@property(nonatomic) BOOL animationActive;
@property(nonatomic) NSInteger atlasColumns;
@property(nonatomic) NSInteger atlasRows;
@property(nonatomic) NSInteger glyphCount;
@property(nonatomic) NSInteger rainGlyphCount;
@property(nonatomic) NSUInteger atlasBlankCellCount;
@property(nonatomic) NSInteger messageGlyphStart;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *messageGlyphs;
@property(nonatomic) CGFloat screenLeft;
@property(nonatomic) CGFloat screenTop;
@property(nonatomic) CGFloat virtualLeft;
@property(nonatomic) CGFloat virtualTop;
@property(nonatomic) CGFloat virtualWidth;
@property(nonatomic) CGFloat virtualHeight;
@property(nonatomic) BOOL hasResolvedDesktopGeometry;
@property(nonatomic) CGSize resolvedDesktopGeometryBoundsSize;
@property(nonatomic) double densityScale;
@property(nonatomic) NSTimeInterval rainElapsed;
@property(nonatomic) BOOL usesExternalRainTimeline;
@property(nonatomic, copy) NSDictionary<NSString *, id> *messages;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic, strong) MatrixCodeMessageScheduler *messageScheduler;
@property(nonatomic, copy, nullable) NSArray<MatrixCodeMessageRegion *> *currentMessageRegions;
@property(nonatomic, strong) MatrixCodeRainSimulation *rainSimulation;
@property(nonatomic, copy) NSArray<MatrixCodeRainSimulation *> *overlapSimulations;
@property(nonatomic, strong) NSMutableIndexSet *activeOverlapLaneIndexes;
@property(nonatomic, strong) NSMutableData *localSimulationStateData;
@property(nonatomic) BOOL simulationUsesSharedDisplayGrid;
@property(nonatomic) NSTimeInterval simulationClockSeconds;
@property(nonatomic) NSTimeInterval lastNormalSimulationTimeSeconds;
@property(nonatomic) BOOL hasLastNormalSimulationTime;
@property(nonatomic) BOOL externalRampFromEmpty;
@property(nonatomic) BOOL needsReducedMotionWarmFrame;
@property(nonatomic) BOOL needsDeterministicRestartFromEmpty;
@property(nonatomic) BOOL deterministicRestartStartsEmpty;
@property(nonatomic) NSTimeInterval schedulerTokenTimeSeconds;
@property(nonatomic) BOOL hasSchedulerTokenTime;
@property(nonatomic) BOOL messageDraftPreviewActive;
@property(nonatomic, copy) NSDictionary<NSString *, id> *images;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *activeImage;
@property(nonatomic, strong) NSData *activeImageMaskData;
@property(nonatomic) NSInteger activeImageWidth;
@property(nonatomic) NSInteger activeImageHeight;
@property(nonatomic) NSTimeInterval nextImageFire;
@property(nonatomic) NSTimeInterval activeImageStart;
@property(nonatomic) NSTimeInterval activeImageEnd;
@property(nonatomic) float activeImageFrameIntensity;
@property(nonatomic) float activeImageFrameScramble;
@property(nonatomic) float activeImagePlacementX;
@property(nonatomic) float activeImagePlacementY;
@property(nonatomic) NSTimeInterval currentFrameTimeSeconds;
@property(nonatomic) BOOL hasCurrentFrameTime;
@property(nonatomic) NSTimeInterval frozenFrameTimeSeconds;
@property(nonatomic) BOOL hasFrozenFrameTime;
@property(nonatomic) NSTimeInterval lastMeasuredFrameTimeSeconds;
@property(nonatomic) double fpsEmaMs;
@property(nonatomic) double measuredFramesPerSecond;
@property(nonatomic, strong) MatrixCodeAdaptiveResolution *adaptiveResolution;
@property(nonatomic) BOOL adaptiveResolutionEnabled;
@property(nonatomic) double renderScale;
- (BOOL)ensureRenderTargetsForWidth:(NSUInteger)width
                              height:(NSUInteger)height;
- (BOOL)encodeFrameToTexture:(id<MTLTexture>)target
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (void)updateImageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows;
- (void)updateActiveImageFrameStateAtTime:(NSTimeInterval)now;
- (void)updateDrawableSizeForCurrentRenderScale;
- (MatrixCodeMessageScheduler *)newMessageScheduler;
- (void)previewMessageDocument:(NSDictionary<NSString *, id> *)document
                         atDate:(NSDate *)date;
@end

@implementation MatrixCodeMetalView

+ (NSInteger)maximumFramesPerSecondForScreen:(NSScreen *)screen {
    return MatrixCodeDisplayFramesPerSecond(screen);
}

#if DEBUG
+ (float)diagnosticEffectiveTrailLength:(float)trailLength
                                  rows:(float)rows
                          speedControl:(float)speedControl {
    return (float)MatrixCodeRainEffectiveTrailLengthForControls(
        @{@"trailLength": @(trailLength), @"speed": @(speedControl)},
        (NSInteger)rows,
        MatrixCodeRainSimulationDefaultConfig());
}

+ (NSInteger)diagnosticFramesPerSecondForScreenMaximum:(NSInteger)screenMaximum
                                displayModeRefreshRate:(double)displayModeRefreshRate
                                displayLinkRefreshRate:(double)displayLinkRefreshRate {
    return MatrixCodeFramesPerSecondFromCandidates(screenMaximum,
                                                   displayModeRefreshRate,
                                                   displayLinkRefreshRate);
}

+ (NSString *)diagnosticAtlasPrimaryFontNameForGlyph:(NSString *)glyph
                                            controls:(NSDictionary<NSString *,id> *)controls {
    return MatrixCodePrimaryAtlasFontNameForGlyph(glyph ?: @"", controls ?: @{});
}

+ (BOOL)diagnosticDrawsReadableDigitGlyph:(NSString *)glyph
                                 controls:(NSDictionary<NSString *,id> *)controls {
    return MatrixCodeShouldDrawReadableDigitGlyph(glyph ?: @"", controls ?: @{});
}

+ (NSString *)diagnosticAtlasDisplayGlyphForGlyph:(NSString *)glyph
                                            index:(NSUInteger)index
                                   rainGlyphCount:(NSUInteger)rainGlyphCount
                                         controls:(NSDictionary<NSString *,id> *)controls {
    return MatrixCodeAtlasDisplayGlyph(glyph ?: @"", index, rainGlyphCount, controls ?: @{});
}

+ (float)diagnosticProceduralDigitValueForGlyphIndex:(NSInteger)glyph
                                      rainGlyphCount:(NSInteger)rainGlyphCount
                                            controls:(NSDictionary<NSString *,id> *)controls {
    return MatrixCodeProceduralDigitValueForRainGlyphMode(glyph,
                                                          rainGlyphCount,
                                                          MatrixCodeGlyphMode(controls ?: @{}));
}

+ (float)diagnosticStepChanceForReferenceRateChance:(float)chance
                                             elapsed:(float)elapsed
                                       referenceRate:(float)referenceRate {
    return MatrixCodeStepChanceForReferenceRateChance(chance, elapsed, referenceRate);
}
#endif

- (instancetype)initWithFrame:(NSRect)frame
                      session:(NSDictionary<NSString *,id> *)session
                 storedValues:(NSDictionary<NSString *,NSString *> *)storedValues {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:device];
    if (!self) return nil;

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.autoResizeDrawable = NO;
    self.paused = YES;
    self.enableSetNeedsDisplay = NO;
    self.preferredFramesPerSecond = MatrixCodeDisplayFramesPerSecond(NSScreen.mainScreen);
    self.delegate = self;
    self.animationActive = NO;
    self.densityScale = 1;
    self.adaptiveResolution = [[MatrixCodeAdaptiveResolution alloc] init];
    self.adaptiveResolutionEnabled = MatrixCodeAdaptiveResolutionIsEnabled(session ?: @{});
    self.renderScale = 1;
    self.activeOverlapLaneIndexes = [NSMutableIndexSet indexSet];
    self.localSimulationStateData = [NSMutableData data];
    self.session = session ?: @{};
    self.seed = [session[@"seed"] respondsToSelector:@selector(unsignedIntValue)]
        ? [session[@"seed"] unsignedIntValue]
        : arc4random();
    self.epochSeconds = [session[@"epoch"] respondsToSelector:@selector(doubleValue)]
        ? [session[@"epoch"] doubleValue] / 1000.0
        : NSDate.date.timeIntervalSince1970;
    self.tokenRunStartSeconds = self.epochSeconds;

    self.commandQueue = [device newCommandQueue];
    [self updateDrawableSizeForCurrentRenderScale];
    [self resolveDesktopGeometry];
    [self reloadStoredValues:storedValues];
    if (![self buildPipeline] || ![self buildAtlas]) return nil;
    return self;
}

- (void)configureFramePacingForScreen:(NSScreen *)screen {
    NSInteger sessionFramesPerSecond = MatrixCodeSessionPreferredFramesPerSecond(self.session);
    self.preferredFramesPerSecond = sessionFramesPerSecond > 0
        ? sessionFramesPerSecond
        : MatrixCodeDisplayFramesPerSecond(screen);
}

- (double)currentRenderScale {
    return self.adaptiveResolutionEnabled &&
        ![self usesSynchronizedMultiMonitorTimeline]
        ? self.renderScale
        : 1;
}

- (CGSize)currentRenderSize {
    return self.drawableSize;
}

- (void)updateDrawableSizeForCurrentRenderScale {
    BOOL multiMonitor = [self usesSynchronizedMultiMonitorTimeline];
    double appliedScale = self.adaptiveResolutionEnabled && !multiMonitor
        ? self.renderScale
        : 1;
    CGFloat backingScale = self.window.backingScaleFactor ?:
        NSScreen.mainScreen.backingScaleFactor ?: 1;
    backingScale = fmin(2, fmax(1, backingScale));
    CGSize target = CGSizeMake(
        MAX(1, round(self.bounds.size.width * backingScale * appliedScale)),
        MAX(1, round(self.bounds.size.height * backingScale * appliedScale)));
    if (fabs(self.drawableSize.width - target.width) >= 0.5 ||
        fabs(self.drawableSize.height - target.height) >= 0.5) {
        self.drawableSize = target;
    }
}

- (BOOL)usesSynchronizedMultiMonitorTimeline {
    NSArray *screens = [self.session[@"screens"] isKindOfClass:NSArray.class]
        ? self.session[@"screens"] : @[];
    return screens.count > 1;
}

- (void)setAnimationActive:(BOOL)active {
    BOOL changed = _animationActive != active;
    _animationActive = active;
    if (changed) {
        NSTimeInterval activationTime = active ? NSDate.date.timeIntervalSince1970 : 0;
        self.hasLastNormalSimulationTime = active;
        self.lastNormalSimulationTimeSeconds = activationTime;
        self.lastMeasuredFrameTimeSeconds = activationTime;
    }
    self.hasFrozenFrameTime = NO;
    self.paused = !active;
}

- (void)freezeAnimationAtDate:(NSDate *)date {
    NSDate *frameDate = date ?: NSDate.date;
    self.frozenFrameTimeSeconds = frameDate.timeIntervalSince1970;
    self.hasFrozenFrameTime = YES;
    _animationActive = NO;
    self.hasLastNormalSimulationTime = NO;
    self.paused = YES;
    self.lastMeasuredFrameTimeSeconds = 0;
    [self draw];
}

- (void)prepareReducedMotionFrame {
    // Warm on the next size-aware update. Keeping the current simulations
    // preserves their PRNG, stream, and message state exactly like the web
    // reduced-motion transition; active overlap lanes are warmed alongside the
    // base so high-density static rain is fully populated.
    self.densityScale = 1;
    self.rainElapsed = 0;
    self.externalRampFromEmpty = NO;
    self.needsReducedMotionWarmFrame = self.rainSimulation != nil &&
        !self.simulationUsesSharedDisplayGrid;
    self.hasLastNormalSimulationTime = NO;
}

- (void)restartDeterministicRainFromEmpty:(BOOL)startsFromEmpty {
    if ([self usesSynchronizedMultiMonitorTimeline]) return;
    self.rainSimulation = nil;
    self.overlapSimulations = @[];
    [self.activeOverlapLaneIndexes removeAllIndexes];
    self.localSimulationStateData.length = 0;
    self.simulationUsesSharedDisplayGrid = NO;
    self.needsReducedMotionWarmFrame = NO;
    self.needsDeterministicRestartFromEmpty = YES;
    self.deterministicRestartStartsEmpty = startsFromEmpty;
    self.densityScale = startsFromEmpty ? 0 : 1;
    self.rainElapsed = 0;
    self.usesExternalRainTimeline = YES;
    self.externalRampFromEmpty = startsFromEmpty;
    self.hasLastNormalSimulationTime = NO;
    self.lastMeasuredFrameTimeSeconds = self.animationActive
        ? NSDate.date.timeIntervalSince1970
        : 0;
    self.fpsEmaMs = 0;
    self.measuredFramesPerSecond = 0;

    self.messageScheduler = [self newMessageScheduler];
    [self.messageScheduler configureWithDocument:self.messages];
    self.messageDraftPreviewActive = NO;
    self.currentMessageRegions = nil;

    self.activeImage = nil;
    self.activeImageMaskData = nil;
    self.activeImageWidth = 0;
    self.activeImageHeight = 0;
    self.activeImageStart = 0;
    self.activeImageEnd = 0;
    self.activeImageFrameIntensity = 1;
    self.activeImageFrameScramble = 0;
    self.activeImagePlacementX = 0.5;
    self.activeImagePlacementY = 0.5;
    double imageFrequency = MatrixCodeNumber(
        self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0;
    self.nextImageFire = self.epochSeconds + imageFrequency *
        (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ 0x6d2b79f5U));

    [self.adaptiveResolution reset];
    self.renderScale = 1;
    [self updateDrawableSizeForCurrentRenderScale];
}

- (void)setTokenTimelineStartDate:(NSDate *)date {
    if ([self usesSynchronizedMultiMonitorTimeline] || !date) return;
    self.tokenRunStartSeconds = date.timeIntervalSince1970;
    [self.tokenResolver setRunStartDate:date];
}

- (void)shiftTokenTimelineBy:(NSTimeInterval)interval {
    if ([self usesSynchronizedMultiMonitorTimeline] ||
        !isfinite(interval) || interval == 0) {
        return;
    }
    self.tokenRunStartSeconds += interval;
    [self.tokenResolver shiftRunStartBy:interval];
}

- (MatrixCodeMessageScheduler *)newMessageScheduler {
    __weak typeof(self) weakSelf = self;
    return [[MatrixCodeMessageScheduler alloc]
        initWithSeed:MatrixCodeMessageSchedulerSeed
        glyphIndexResolver:nil
        textResolver:^NSString *(NSString *rawText) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf.tokenResolver) return rawText;
            NSTimeInterval time = strongSelf.hasSchedulerTokenTime
                ? strongSelf.schedulerTokenTimeSeconds
                : (strongSelf.hasCurrentFrameTime
                    ? strongSelf.currentFrameTimeSeconds
                    : NSDate.date.timeIntervalSince1970);
            return [strongSelf.tokenResolver
                resolveText:rawText
                     atDate:[NSDate dateWithTimeIntervalSince1970:time]
            framesPerSecond:strongSelf.measuredFramesPerSecond];
        }];
}

- (void)previewMessageDocument:(NSDictionary<NSString *, id> *)document
                         atDate:(NSDate *)date {
    if (!self.rainSimulation) {
        [self updateInstancesForDrawableSize:self.drawableSize];
    }
    if (!self.rainSimulation || !self.messageScheduler) return;
    NSDate *previewDate = date ?: NSDate.date;
    double previewTimeMilliseconds = [self usesSynchronizedMultiMonitorTimeline]
        ? self.simulationClockSeconds * 1000.0
        : previewDate.timeIntervalSince1970 * 1000.0;
    self.schedulerTokenTimeSeconds = previewDate.timeIntervalSince1970;
    self.hasSchedulerTokenTime = YES;
    self.messageDraftPreviewActive = YES;
    [self.messageScheduler
        previewOneAtTimeMilliseconds:previewTimeMilliseconds
                                sink:self.rainSimulation
                            document:document
                             regions:self.currentMessageRegions];
    self.hasSchedulerTokenTime = NO;
    if (self.isPaused) [self draw];
}

- (void)previewMessageAtDate:(NSDate *)date {
    [self previewMessageDocument:self.messages atDate:date];
}

- (void)previewMessageWithStoredValues:(NSDictionary<NSString *,NSString *> *)storedValues
                                atDate:(NSDate *)date {
    NSDictionary<NSString *, id> *draft =
        MatrixCodeStoredMessagesDocument(storedValues) ?: self.messages;
    [self previewMessageDocument:draft atDate:date];
}

- (double)updateMeasuredFramesPerSecondAtTime:(NSTimeInterval)time {
    if (!isfinite(time)) return self.measuredFramesPerSecond;
    if (self.lastMeasuredFrameTimeSeconds > 0 && time > self.lastMeasuredFrameTimeSeconds) {
        double frameMs = fmin(fmax((time - self.lastMeasuredFrameTimeSeconds) * 1000.0, 0), 100);
        self.fpsEmaMs = self.fpsEmaMs <= 0
            ? frameMs
            : self.fpsEmaMs + 0.15 * (frameMs - self.fpsEmaMs);
        self.measuredFramesPerSecond = self.fpsEmaMs > 0 ? 1000.0 / self.fpsEmaMs : 0;
    }
    self.lastMeasuredFrameTimeSeconds = time;
    return self.measuredFramesPerSecond;
}

- (void)setDensityScale:(double)densityScale {
    _densityScale = fmin(1, fmax(0, densityScale));
}

- (void)setDensityScale:(double)densityScale rainElapsed:(NSTimeInterval)rainElapsed {
    [self setDensityScale:densityScale];
    self.rainElapsed = rainElapsed;
    self.usesExternalRainTimeline = YES;
}

- (void)reloadStoredValues:(NSDictionary<NSString *,NSString *> *)storedValues {
    BOOL previousMirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSString *previousGlyphMode = MatrixCodeGlyphMode(self.controls);
    NSString *previousFont = MatrixCodeGlyphFont(self.controls);
    NSDictionary *previousMessages = self.messages;
    NSDictionary *previousImages = self.images;
    NSDictionary *controls = nil;
    NSString *raw = storedValues[@"mx-controls"];
    if ([raw isKindOfClass:NSString.class]) {
        NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:NSDictionary.class]) controls = object;
    }
    self.controls = MatrixCodeSanitizeControlsDocument(controls);
    self.messages = MatrixCodeStoredMessagesDocument(storedValues) ?:
        MatrixCodeDefaultMessages();
    NSDictionary *images = nil;
    NSString *imagesRaw = storedValues[@"mx-images"];
    if ([imagesRaw isKindOfClass:NSString.class]) {
        NSData *data = [imagesRaw dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:NSDictionary.class]) images = object;
    }
    NSDictionary *storedImages = images ?: @{};
    self.images = @{
        @"images": MatrixCodeSanitizedRenderImages(storedImages),
        @"enabled": @(MatrixCodeBool(storedImages, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeNumber(storedImages, @"frequencyMs", 14000, 500, 600000)),
        @"persistenceMs": @(MatrixCodeNumber(storedImages, @"persistenceMs", 12000, 500, 600000)),
        @"appearMs": @(MatrixCodeNumber(storedImages, @"appearMs", 4500, 0, 600000)),
        @"disappearMs": @(MatrixCodeNumber(storedImages, @"disappearMs", 4500, 0, 600000)),
        @"flickerOut": @(MatrixCodeBool(storedImages, @"flickerOut", YES)),
        @"brightnessFade": @(MatrixCodeBool(storedImages, @"brightnessFade", NO)),
        @"imageScale": @(MatrixCodeNumber(storedImages, @"imageScale", 0.72, 0.05, 1)),
        @"imagePlacementJitter": @(MatrixCodeNumber(storedImages, @"imagePlacementJitter", 0.35, 0, 1)),
    };
    NSTimeInterval tokenRunStart = [self usesSynchronizedMultiMonitorTimeline]
        ? self.epochSeconds
        : self.tokenRunStartSeconds;
    self.tokenResolver = [[MatrixCodeTokenResolver alloc]
        initWithStoredValues:storedValues
                runStartDate:[NSDate dateWithTimeIntervalSince1970:tokenRunStart]];
    if (!self.messageScheduler) {
        self.messageScheduler = [self newMessageScheduler];
    }
    NSTimeInterval scheduleBase = [self usesSynchronizedMultiMonitorTimeline]
        ? self.epochSeconds
        : (self.animationActive ? NSDate.date.timeIntervalSince1970 : self.epochSeconds);
    BOOL restoreMessageSchedule = self.messageDraftPreviewActive;
    self.messageDraftPreviewActive = NO;
    if (restoreMessageSchedule ||
        !previousMessages || ![previousMessages isEqual:self.messages]) {
        [self.messageScheduler configureWithDocument:self.messages];
    }
    if (!previousImages || ![previousImages isEqual:self.images]) {
        self.activeImage = nil;
        self.activeImageMaskData = nil;
        self.activeImageWidth = 0;
        self.activeImageHeight = 0;
        self.activeImageStart = 0;
        self.activeImageEnd = 0;
        self.activeImageFrameIntensity = 1;
        self.activeImageFrameScramble = 0;
        self.activeImagePlacementX = 0.5f;
        self.activeImagePlacementY = 0.5f;
        float imageFrequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500,
                                                 600000) / 1000.0f;
        self.nextImageFire = scheduleBase + imageFrequency *
            (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ 0x6d2b79f5U));
    }
    [self updatePalette];
    BOOL nextMirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSString *nextGlyphMode = MatrixCodeGlyphMode(self.controls);
    NSString *nextFont = MatrixCodeGlyphFont(self.controls);
    BOOL glyphModeChanged = ![previousGlyphMode isEqualToString:nextGlyphMode];
    if (glyphModeChanged) {
        self.rainSimulation.glyphMode = nextGlyphMode;
        for (MatrixCodeRainSimulation *simulation in self.overlapSimulations) {
            simulation.glyphMode = nextGlyphMode;
        }
    }
    if (self.atlas &&
        (previousMirror != nextMirror || ![previousFont isEqualToString:nextFont] ||
         glyphModeChanged)) {
        [self buildAtlas];
    }
}

- (void)resolveDesktopGeometry {
    NSArray *screens = [self.session[@"screens"] isKindOfClass:NSArray.class] ? self.session[@"screens"] : @[];
    NSString *currentID = [self.session[@"currentScreenId"] isKindOfClass:NSString.class]
        ? self.session[@"currentScreenId"]
        : nil;
    CGFloat minX = 0, minY = 0;
    CGFloat maxX = self.bounds.size.width, maxY = self.bounds.size.height;
    CGFloat screenLeft = 0, screenTop = 0;
    BOOL foundCurrentScreen = NO;
    BOOL first = YES;
    for (NSDictionary *screen in screens) {
        if (![screen isKindOfClass:NSDictionary.class]) continue;
        CGFloat left = [screen[@"left"] doubleValue];
        CGFloat top = [screen[@"top"] doubleValue];
        CGFloat width = [screen[@"width"] doubleValue];
        CGFloat height = [screen[@"height"] doubleValue];
        if (first) {
            minX = left; minY = top; maxX = left + width; maxY = top + height; first = NO;
        } else {
            minX = fmin(minX, left); minY = fmin(minY, top);
            maxX = fmax(maxX, left + width); maxY = fmax(maxY, top + height);
        }
        if (currentID && [screen[@"id"] isEqual:currentID]) {
            screenLeft = left;
            screenTop = top;
            foundCurrentScreen = YES;
        }
    }
    self.screenLeft = foundCurrentScreen ? screenLeft : 0;
    self.screenTop = foundCurrentScreen ? screenTop : 0;
    self.virtualLeft = minX;
    self.virtualTop = minY;
    self.virtualWidth = maxX - minX;
    self.virtualHeight = maxY - minY;
    self.resolvedDesktopGeometryBoundsSize = self.bounds.size;
    self.hasResolvedDesktopGeometry = YES;
}

- (void)resolveDesktopGeometryIfNeeded {
    CGSize boundsSize = self.bounds.size;
    if (self.hasResolvedDesktopGeometry &&
        fabs(boundsSize.width - self.resolvedDesktopGeometryBoundsSize.width) < 0.5 &&
        fabs(boundsSize.height - self.resolvedDesktopGeometryBoundsSize.height) < 0.5) {
        return;
    }
    [self resolveDesktopGeometry];
}

- (BOOL)buildPipeline {
    NSError *error = nil;
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *shaderURL = [bundle URLForResource:@"MatrixCodeShaders" withExtension:@"msl"];
    NSString *shaderSource = shaderURL
        ? [NSString stringWithContentsOfURL:shaderURL encoding:NSUTF8StringEncoding error:&error]
        : nil;
    id<MTLLibrary> library = shaderSource
        ? [self.device newLibraryWithSource:shaderSource options:nil error:&error]
        : nil;
    if (!library) {
        NSLog(@"MatrixCode: bundled Metal shader could not be compiled: %@", error);
        return NO;
    }
    self.pipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixVertex", @"matrixSceneFragment",
        MTLPixelFormatRGBA16Float, YES, &error);
    self.brightPassPipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixFullscreenVertex", @"matrixBrightPassFragment",
        MTLPixelFormatRG11B10Float, NO, &error);
    self.blurPipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixFullscreenVertex", @"matrixBlurFragment",
        MTLPixelFormatRG11B10Float, NO, &error);
    self.resamplePipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixFullscreenVertex", @"matrixCopyFragment",
        MTLPixelFormatRG11B10Float, NO, &error);
    self.additiveCopyPipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixFullscreenVertex", @"matrixCopyFragment",
        MTLPixelFormatRG11B10Float, YES, &error);
    self.compositePipeline = MatrixCodeCreateRenderPipeline(
        self.device, library, @"matrixFullscreenVertex", @"matrixCompositeFragment",
        self.colorPixelFormat, NO, &error);
    BOOL built = self.pipeline && self.brightPassPipeline && self.blurPipeline &&
        self.resamplePipeline && self.additiveCopyPipeline && self.compositePipeline;
    if (!built) NSLog(@"MatrixCode: Metal pipeline creation failed: %@", error);
    return built;
}

- (NSArray<NSString *> *)glyphs {
    NSMutableArray<NSString *> *glyphs = [NSMutableArray array];
    for (NSInteger codepoint = 0xff66; codepoint <= 0xff9d; codepoint++) {
        unichar character = (unichar)codepoint;
        [glyphs addObject:[NSString stringWithCharacters:&character length:1]];
    }
    for (unichar c = '0'; c <= '9'; c++) [glyphs addObject:[NSString stringWithCharacters:&c length:1]];
    for (unichar c = 'A'; c <= 'Z'; c++) [glyphs addObject:[NSString stringWithCharacters:&c length:1]];
    [glyphs addObjectsFromArray:@[@"=", @"+", @"-", @"*", @"<", @">", @":"]];
    self.rainGlyphCount = glyphs.count;
    NSCAssert(self.rainGlyphCount == MatrixCodeRainGlyphCount(),
              @"Native glyph atlas order must match MatrixCodeRainLifecycle ranges.");
    self.messageGlyphStart = glyphs.count;
    NSString *messageCharacters = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=+-*<>:.,!?'";
    NSMutableDictionary *messageGlyphs = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < messageCharacters.length; index++) {
        NSString *character = [messageCharacters substringWithRange:NSMakeRange(index, 1)];
        if (!messageGlyphs[character]) messageGlyphs[character] = @(glyphs.count);
        [glyphs addObject:character];
    }
    self.messageGlyphs = messageGlyphs;
    return glyphs;
}

- (BOOL)buildAtlas {
    NSArray<NSString *> *glyphs = [self glyphs];
    self.glyphCount = glyphs.count;
    self.atlasColumns = MatrixCodeAtlasColumnCount(self.glyphCount);
    self.atlasRows = (glyphs.count + self.atlasColumns - 1) / self.atlasColumns;
    const size_t cell = MatrixCodeAtlasCellPixels;
    const size_t width = cell * self.atlasColumns;
    const size_t height = cell * self.atlasRows;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width,
                                                 colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(colorSpace);
    if (!context) return NO;
    CGContextSetGrayFillColor(context, 1, 1);
    CGFloat fontSize = round((CGFloat)cell * 0.78);
    CTFontRef font = MatrixCodeCreateGlyphFont(self.controls, fontSize);
    BOOL readableDigits = MatrixCodeGlyphModeUsesReadableDigits(self.controls);
    CTFontRef digitFont = readableDigits
        ? MatrixCodeCreateReadableDigitFont(self.controls, fontSize) : NULL;
    if (!font || (readableDigits && !digitFont)) {
        if (font) CFRelease(font);
        if (digitFont) CFRelease(digitFont);
        CGContextRelease(context);
        return NO;
    }
    NSDictionary *attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.whiteColor.CGColor,
    };
    NSDictionary *digitAttributes = digitFont ? @{
        (id)kCTFontAttributeName: (__bridge id)digitFont,
        (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.whiteColor.CGColor,
    } : attributes;
    BOOL mirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSUInteger rainGlyphCount = (NSUInteger)MAX((NSInteger)0, self.rainGlyphCount);
    void (^drawGlyphAtIndex)(NSString *, NSUInteger) =
        ^(NSString *sourceGlyph, NSUInteger targetIndex) {
        NSString *displayGlyph = MatrixCodeAtlasDisplayGlyph(
            sourceGlyph, targetIndex, self.rainGlyphCount, self.controls);
        NSInteger column = targetIndex % self.atlasColumns;
        NSInteger row = targetIndex / self.atlasColumns;
        CGFloat cellY = height - (row + 1) * cell;
        CGRect digitRect = CGRectMake(column * cell, cellY, cell, cell);
        NSDictionary *glyphAttributes =
            readableDigits && MatrixCodeGlyphStringIsDigit(displayGlyph)
                ? digitAttributes
                : attributes;
        NSAttributedString *string = [[NSAttributedString alloc]
            initWithString:displayGlyph
                attributes:glyphAttributes];
        CTLineRef line =
            CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGFloat ascent = 0;
        CGFloat descent = 0;
        double advance = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
        CGFloat x =
            column * cell + ((CGFloat)cell - (CGFloat)advance) * 0.5;
        CGFloat y = cellY + (CGFloat)cell * 0.5 - (ascent - descent) * 0.5;
        CGContextSaveGState(context);
        if (mirror && targetIndex < rainGlyphCount) {
            CGContextTranslateCTM(context, column * cell + cell, 0);
            CGContextScaleCTM(context, -1, 1);
            x = ((CGFloat)cell - (CGFloat)advance) * 0.5;
            digitRect = CGRectMake(0, cellY, cell, cell);
        }
        if (targetIndex < rainGlyphCount &&
            MatrixCodeShouldDrawReadableDigitGlyph(displayGlyph, self.controls)) {
            MatrixCodeDrawReadableDigitGlyph(context, displayGlyph, digitRect);
        } else {
            CGContextSetTextPosition(context, x, y);
            CTLineDraw(line, context);
        }
        CGContextRestoreGState(context);
        CFRelease(line);
    };
    [glyphs enumerateObjectsUsingBlock:
        ^(NSString *glyph, NSUInteger index, BOOL *stop) {
        (void)stop;
        drawGlyphAtIndex(glyph, index);
    }];

    // Match glyphAtlas.ts coverage verification. CoreText fallback can still
    // produce an empty outline for a code point; retain atlas indices and draw
    // the middle known-good source glyph into any blank target cell.
    CGContextFlush(context);
    const uint8_t *coverage = pixels.bytes;
    BOOL (^cellIsInked)(NSUInteger) = ^BOOL(NSUInteger index) {
        NSUInteger column = index % (NSUInteger)self.atlasColumns;
        NSUInteger row = index / (NSUInteger)self.atlasColumns;
        NSUInteger x0 = column * cell;
        NSUInteger y0 = height - (row + 1) * cell;
        for (NSUInteger y = y0; y < y0 + cell; y += 2) {
            NSUInteger pixel = y * width + x0;
            for (NSUInteger x = 0; x < cell; x += 2, pixel += 2) {
                if (coverage[pixel] > 24) return YES;
            }
        }
        return NO;
    };
    NSMutableArray<NSNumber *> *inkedIndexes = [NSMutableArray array];
    for (NSUInteger index = 0; index < glyphs.count; index++) {
        if (cellIsInked(index)) [inkedIndexes addObject:@(index)];
    }
    NSUInteger fallbackIndex = NSNotFound;
    if (inkedIndexes.count > 0) {
        fallbackIndex = inkedIndexes[inkedIndexes.count / 2].unsignedIntegerValue;
        for (NSUInteger index = 0; index < glyphs.count; index++) {
            if (cellIsInked(index)) continue;
            NSUInteger column = index % (NSUInteger)self.atlasColumns;
            NSUInteger row = index / (NSUInteger)self.atlasColumns;
            CGRect cellRect = CGRectMake(column * cell,
                                         height - (row + 1) * cell,
                                         cell,
                                         cell);
            CGContextClearRect(context, cellRect);
            drawGlyphAtIndex(glyphs[fallbackIndex], index);
        }
        CGContextFlush(context);
    }
    NSMutableArray<NSNumber *> *remainingBlankIndexes = [NSMutableArray array];
    for (NSUInteger index = 0; index < glyphs.count; index++) {
        if (!cellIsInked(index)) [remainingBlankIndexes addObject:@(index)];
    }
    if (fallbackIndex != NSNotFound && remainingBlankIndexes.count > 0) {
        // CoreText can decline a second outline draw into a flushed bitmap.
        // Reuse that same fallback glyph's rendered coverage, changing only
        // the horizontal orientation when the target crosses the mirror cutoff.
        NSUInteger sourceColumn = fallbackIndex % (NSUInteger)self.atlasColumns;
        NSUInteger sourceRow = fallbackIndex / (NSUInteger)self.atlasColumns;
        NSUInteger sourceY = height - (sourceRow + 1) * cell;
        NSMutableData *sourceCell = [NSMutableData dataWithLength:cell * cell];
        uint8_t *sourceBytes = sourceCell.mutableBytes;
        uint8_t *mutableCoverage = pixels.mutableBytes;
        for (NSUInteger row = 0; row < cell; row++) {
            memcpy(sourceBytes + row * cell,
                   mutableCoverage + (sourceY + row) * width + sourceColumn * cell,
                   cell);
        }
        BOOL sourceMirrored = mirror && fallbackIndex < rainGlyphCount;
        for (NSNumber *number in remainingBlankIndexes) {
            NSUInteger targetIndex = number.unsignedIntegerValue;
            NSUInteger targetColumn = targetIndex % (NSUInteger)self.atlasColumns;
            NSUInteger targetRow = targetIndex / (NSUInteger)self.atlasColumns;
            NSUInteger targetY = height - (targetRow + 1) * cell;
            BOOL targetMirrored = mirror && targetIndex < rainGlyphCount;
            for (NSUInteger row = 0; row < cell; row++) {
                uint8_t *target = mutableCoverage +
                    (targetY + row) * width + targetColumn * cell;
                const uint8_t *source = sourceBytes + row * cell;
                if (sourceMirrored == targetMirrored) {
                    memcpy(target, source, cell);
                } else {
                    for (NSUInteger x = 0; x < cell; x++) {
                        target[x] = source[cell - x - 1];
                    }
                }
            }
        }
    }
    NSUInteger blankCellCount = 0;
    for (NSUInteger index = 0; index < glyphs.count; index++) {
        if (!cellIsInked(index)) {
            blankCellCount++;
        }
    }
    self.atlasBlankCellCount = blankCellCount;
    CFRelease(font);
    if (digitFont) CFRelease(digitFont);
    CGContextRelease(context);

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:YES];
    descriptor.usage = MTLTextureUsageShaderRead;
    self.atlas = [self.device newTextureWithDescriptor:descriptor];
    [self.atlas replaceRegion:MTLRegionMake2D(0, 0, width, height)
                  mipmapLevel:0
                    withBytes:pixels.bytes
                  bytesPerRow:width];
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (commandBuffer) {
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit generateMipmapsForTexture:self.atlas];
        [blit endEncoding];
        [commandBuffer commit];
    }
    return self.atlas != nil;
}

- (BOOL)ensureRenderTargetsForWidth:(NSUInteger)width
                              height:(NSUInteger)height {
    NSString *quality = [self.controls[@"quality"] isKindOfClass:NSString.class]
        ? self.controls[@"quality"] : @"high";
    NSInteger bloomLevelCount = MatrixCodeBloomLevelCount(quality);
    width = MAX((NSUInteger)1, width);
    height = MAX((NSUInteger)1, height);
    if (self.sceneTexture && self.renderTargetWidth == width &&
        self.renderTargetHeight == height &&
        self.renderTargetBloomLevelCount == bloomLevelCount &&
        self.bloomMainTextures.count == (NSUInteger)bloomLevelCount &&
        self.bloomTemporaryTextures.count == (NSUInteger)bloomLevelCount) {
        return YES;
    }

    id<MTLTexture> scene = MatrixCodeCreateRenderTarget(
        self.device, MTLPixelFormatRGBA16Float, width, height);
    NSMutableArray<id<MTLTexture>> *mainTextures =
        [NSMutableArray arrayWithCapacity:(NSUInteger)bloomLevelCount];
    NSMutableArray<id<MTLTexture>> *temporaryTextures =
        [NSMutableArray arrayWithCapacity:(NSUInteger)bloomLevelCount];
    for (NSInteger level = 0; level < bloomLevelCount; level++) {
        NSUInteger levelWidth = MAX((NSUInteger)1, width >> (level + 1));
        NSUInteger levelHeight = MAX((NSUInteger)1, height >> (level + 1));
        id<MTLTexture> main = MatrixCodeCreateRenderTarget(
            self.device, MTLPixelFormatRG11B10Float, levelWidth, levelHeight);
        id<MTLTexture> temporary = MatrixCodeCreateRenderTarget(
            self.device, MTLPixelFormatRG11B10Float, levelWidth, levelHeight);
        if (!main || !temporary) return NO;
        [mainTextures addObject:main];
        [temporaryTextures addObject:temporary];
    }
    if (!scene) return NO;

    self.sceneTexture = scene;
    self.bloomMainTextures = mainTextures;
    self.bloomTemporaryTextures = temporaryTextures;
    self.renderTargetWidth = width;
    self.renderTargetHeight = height;
    self.renderTargetBloomLevelCount = bloomLevelCount;
    return YES;
}

- (BOOL)encodeFrameToTexture:(id<MTLTexture>)target
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!target || !commandBuffer ||
        ![self ensureRenderTargetsForWidth:target.width height:target.height]) {
        return NO;
    }

    MTLClearColor transparentBlack = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:
        MatrixCodePassDescriptor(self.sceneTexture, MTLLoadActionClear, transparentBlack)];
    if (!encoder) return NO;
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
    [encoder setFragmentBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
    [encoder setFragmentTexture:self.atlas atIndex:0];
    if (self.instanceCount > 0) {
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                   vertexStart:0
                   vertexCount:6
                 instanceCount:self.instanceCount];
    }
    [encoder endEncoding];

    id<MTLTexture> firstBloom = self.bloomMainTextures.firstObject;
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:
        MatrixCodePassDescriptor(firstBloom, MTLLoadActionDontCare, transparentBlack)];
    if (!encoder) return NO;
    [encoder setRenderPipelineState:self.brightPassPipeline];
    [encoder setFragmentTexture:self.sceneTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    for (NSInteger level = 0; level < self.renderTargetBloomLevelCount; level++) {
        id<MTLTexture> main = self.bloomMainTextures[(NSUInteger)level];
        id<MTLTexture> temporary = self.bloomTemporaryTextures[(NSUInteger)level];
        MatrixCodeBlurUniforms blurUniforms = {
            .direction = {(float)(MatrixCodeBloomSpread / MAX((NSUInteger)1, main.width)), 0},
        };
        encoder = [commandBuffer renderCommandEncoderWithDescriptor:
            MatrixCodePassDescriptor(temporary, MTLLoadActionDontCare, transparentBlack)];
        if (!encoder) return NO;
        [encoder setRenderPipelineState:self.blurPipeline];
        [encoder setFragmentBytes:&blurUniforms length:sizeof(blurUniforms) atIndex:0];
        [encoder setFragmentTexture:main atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        blurUniforms.direction = (vector_float2){
            0, (float)(MatrixCodeBloomSpread / MAX((NSUInteger)1, main.height)),
        };
        encoder = [commandBuffer renderCommandEncoderWithDescriptor:
            MatrixCodePassDescriptor(main, MTLLoadActionDontCare, transparentBlack)];
        if (!encoder) return NO;
        [encoder setRenderPipelineState:self.blurPipeline];
        [encoder setFragmentBytes:&blurUniforms length:sizeof(blurUniforms) atIndex:0];
        [encoder setFragmentTexture:temporary atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        if (level + 1 < self.renderTargetBloomLevelCount) {
            id<MTLTexture> next = self.bloomMainTextures[(NSUInteger)(level + 1)];
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:
                MatrixCodePassDescriptor(next, MTLLoadActionDontCare, transparentBlack)];
            if (!encoder) return NO;
            [encoder setRenderPipelineState:self.resamplePipeline];
            [encoder setFragmentTexture:main atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
        }
    }

    for (NSInteger level = self.renderTargetBloomLevelCount - 1; level >= 1; level--) {
        id<MTLTexture> source = self.bloomMainTextures[(NSUInteger)level];
        id<MTLTexture> destination = self.bloomMainTextures[(NSUInteger)(level - 1)];
        encoder = [commandBuffer renderCommandEncoderWithDescriptor:
            MatrixCodePassDescriptor(destination, MTLLoadActionLoad, transparentBlack)];
        if (!encoder) return NO;
        [encoder setRenderPipelineState:self.additiveCopyPipeline];
        [encoder setFragmentTexture:source atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }

    encoder = [commandBuffer renderCommandEncoderWithDescriptor:
        MatrixCodePassDescriptor(target, MTLLoadActionDontCare, self.clearColor)];
    if (!encoder) return NO;
    [encoder setRenderPipelineState:self.compositePipeline];
    [encoder setFragmentBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
    [encoder setFragmentTexture:self.sceneTexture atIndex:0];
    [encoder setFragmentTexture:self.bloomMainTextures.firstObject atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}

- (void)resetActiveImageState {
    self.activeImage = nil;
    self.activeImageMaskData = nil;
    self.activeImageWidth = 0;
    self.activeImageHeight = 0;
    self.activeImageStart = 0;
    self.activeImageEnd = 0;
    self.activeImageFrameIntensity = 1;
    self.activeImageFrameScramble = 0;
    self.activeImagePlacementX = 0.5f;
    self.activeImagePlacementY = 0.5f;
}

- (void)updateImageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows {
    (void)globalCols;
    (void)globalRows;
    (void)localCols;
    (void)localRows;
    BOOL enabled = MatrixCodeBool(self.images, @"enabled", NO);
    NSArray<NSDictionary *> *configured = [self.images[@"images"] isKindOfClass:NSArray.class]
        ? self.images[@"images"] : @[];
    if (!enabled || !configured.count) {
        [self resetActiveImageState];
        return;
    }
    if (self.activeImage && now >= self.activeImageEnd) {
        BOOL synchronizedTimeline = [self usesSynchronizedMultiMonitorTimeline];
        NSTimeInterval endedAt = self.activeImageEnd;
        [self resetActiveImageState];
        float frequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0f;
        NSTimeInterval scheduleAnchor = synchronizedTimeline ? endedAt : now;
        uint32_t cycle = (uint32_t)floor(scheduleAnchor - self.epochSeconds);
        self.nextImageFire = scheduleAnchor + frequency *
            (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ cycle ^ 0x6d2b79f5U));
    }
    if (!self.activeImage && now >= self.nextImageFire) {
        BOOL synchronizedTimeline = [self usesSynchronizedMultiMonitorTimeline];
        NSTimeInterval fireTime = self.nextImageFire;
        NSTimeInterval activationTime = synchronizedTimeline ? fireTime : now;
        uint32_t activation = (uint32_t)floor((activationTime - self.epochSeconds) * 10);
        NSUInteger selected = MatrixCodeHash(self.seed ^ activation ^ 0x3f4d1c23U) % configured.count;
        NSDictionary *image = configured[selected];
        NSData *mask = [[NSData alloc] initWithBase64EncodedString:image[@"data"] options:0];
        NSInteger width = [image[@"width"] integerValue];
        NSInteger height = [image[@"height"] integerValue];
        if (!mask || mask.length != (NSUInteger)(width * height)) {
            float frequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0f;
            NSTimeInterval scheduleAnchor = synchronizedTimeline ? fireTime : now;
            self.nextImageFire = scheduleAnchor + frequency *
                (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ activation ^ 0x6d2b79f5U));
            return;
        }
        self.activeImage = image;
        self.activeImageMaskData = mask;
        self.activeImageWidth = width;
        self.activeImageHeight = height;
        self.activeImageStart = activationTime;
        self.activeImagePlacementX = MatrixCodeUnit(self.seed ^ activation ^ 0x731f4a7dU);
        self.activeImagePlacementY = MatrixCodeUnit(self.seed ^ activation ^ 0x4c2d65bfU);
        float appear = MatrixCodeNumber(self.images, @"appearMs", 4500, 0, 600000) / 1000.0f;
        float hold = MatrixCodeNumber(self.images, @"persistenceMs", 12000, 500, 600000) / 1000.0f;
        float disappear = MatrixCodeNumber(self.images, @"disappearMs", 4500, 0, 600000) / 1000.0f;
        self.activeImageEnd = activationTime + appear + hold + disappear;
    }
}

- (void)updateActiveImageFrameStateAtTime:(NSTimeInterval)now {
    if (!self.activeImage || !self.activeImageMaskData) {
        self.activeImageFrameIntensity = 1;
        self.activeImageFrameScramble = 0;
        return;
    }
    float appear = MatrixCodeNumber(self.images, @"appearMs", 4500, 0, 600000) / 1000.0f;
    float disappear = MatrixCodeNumber(self.images, @"disappearMs", 4500, 0, 600000) / 1000.0f;
    float elapsed = (float)(now - self.activeImageStart);
    float remaining = (float)(self.activeImageEnd - now);
    float fade = 1;
    float flicker = 0;
    if (appear > 0 && elapsed < appear) {
        fade = fmaxf(0, elapsed / appear);
        flicker = 1 - fade;
    } else if (disappear > 0 && remaining < disappear) {
        fade = fmaxf(0, remaining / disappear);
        flicker = 1 - fade;
    }
    self.activeImageFrameIntensity = MatrixCodeBool(self.images, @"brightnessFade", NO) ? fade : 1;
    self.activeImageFrameScramble = MatrixCodeBool(self.images, @"flickerOut", YES) ? flicker : 0;
}

- (void)updatePalette {
    NSString *preset = [self.controls[@"preset"] isKindOfClass:NSString.class] ? self.controls[@"preset"] : @"classic";
    NSDictionary *palettes = @{
        @"classic": @[@0x0D0208, @0x003B00, @0x008F11, @0x00FF41, @0xDEFFE4],
        @"amber": @[@0x0A0600, @0x3B1E00, @0xA85B00, @0xFFB000, @0xFFF1C8],
        @"blue": @[@0x02060D, @0x00263B, @0x0066A8, @0x27D6FF, @0xE4FAFF],
        @"gold": @[@0x0D0B00, @0x3B3300, @0xA89000, @0xFFE21F, @0xFFFBD6],
        @"red": @[@0x0D0202, @0x3B0000, @0xA80008, @0xFF2A2A, @0xFFE0E0],
        @"pink": @[@0x0D0207, @0x3B0022, @0xA80060, @0xFF3DA0, @0xFFE2F1],
        @"purple": @[@0x08020D, @0x2A003B, @0x6E00A8, @0xB23BFF, @0xF2E2FF],
        @"white": @[@0x060606, @0x2A2A2A, @0x8C8C8C, @0xEDEDED, @0xFFFFFF],
    };
    NSArray<NSNumber *> *palette = palettes[preset] ?: palettes[@"classic"];
    MTLClearColor background = {
        ((palette[0].unsignedIntValue >> 16) & 0xff) / 255.0,
        ((palette[0].unsignedIntValue >> 8) & 0xff) / 255.0,
        (palette[0].unsignedIntValue & 0xff) / 255.0,
        1,
    };
    self.clearColor = background;
    MatrixCodeUniforms uniforms = self.uniforms;
    uniforms.backgroundColor = MatrixCodeRGB(palette[0].unsignedIntValue);
    uniforms.tailColor = MatrixCodeRGB(palette[1].unsignedIntValue);
    uniforms.bodyColor = MatrixCodeRGB(palette[2].unsignedIntValue);
    uniforms.brightColor = MatrixCodeRGB(palette[3].unsignedIntValue);
    uniforms.headColor = MatrixCodeRGB(palette[4].unsignedIntValue);
    uniforms.glow = MatrixCodeNumber(self.controls, @"glow", 0.9, 0, 2.5);
    uniforms.vignette = MatrixCodeVignette(self.controls);
    uniforms.scanlines = MatrixCodeBool(self.controls, @"scanlines", NO) ? 1 : 0;
    uniforms.leadBrightness = MatrixCodeNumber(self.controls, @"leadBrightness", 1.6, 0, 3);
    self.uniforms = uniforms;
}

- (void)resetRainSimulationsFromEmpty {
    [self.rainSimulation reset];
    for (MatrixCodeRainSimulation *simulation in self.overlapSimulations) {
        [simulation reset];
    }
    [self.activeOverlapLaneIndexes removeAllIndexes];
}

- (void)ensureRainSimulationsForSharedDisplayGrid:(BOOL)sharedDisplayGrid
                                      localColumns:(NSInteger)localColumns
                                           localRows:(NSInteger)localRows
                                      virtualColumns:(NSInteger)virtualColumns
                                           virtualRows:(NSInteger)virtualRows
                                                 lanes:(const MatrixCodeRainLane *)lanes
                                             laneCount:(NSInteger)laneCount {
    NSString *glyphMode = MatrixCodeGlyphMode(self.controls);
    if (sharedDisplayGrid) {
        BOOL reconstruct = !self.rainSimulation || !self.simulationUsesSharedDisplayGrid ||
            self.rainSimulation.columns != virtualColumns ||
            self.rainSimulation.rows != virtualRows;
        if (reconstruct) {
            self.rainSimulation = [[MatrixCodeRainSimulation alloc]
                initWithColumns:virtualColumns
                           rows:virtualRows
                         config:MatrixCodeRainSimulationDefaultConfig()
                      glyphMode:glyphMode
                           seed:self.seed];
            [self.rainSimulation warmUpDistributedWithControls:self.controls
                                                       seconds:MatrixCodeRainWarmupSeconds
                                                          step:MatrixCodeRainFixedStepSeconds];
            self.simulationClockSeconds = MatrixCodeRainWarmupSeconds;
            self.overlapSimulations = @[];
            [self.activeOverlapLaneIndexes removeAllIndexes];
            self.hasLastNormalSimulationTime = NO;
            self.externalRampFromEmpty = NO;
        } else {
            self.rainSimulation.glyphMode = glyphMode;
        }
        self.simulationUsesSharedDisplayGrid = YES;
        NSUInteger localLength = (NSUInteger)localColumns * (NSUInteger)localRows * 4;
        if (self.localSimulationStateData.length != localLength) {
            self.localSimulationStateData = [NSMutableData dataWithLength:localLength];
        }
        return;
    }

    BOOL construct = !self.rainSimulation || self.simulationUsesSharedDisplayGrid;
    if (construct) {
        self.rainSimulation = [[MatrixCodeRainSimulation alloc]
            initWithColumns:localColumns
                       rows:localRows
                     config:MatrixCodeRainSimulationDefaultConfig()
                  glyphMode:glyphMode
                       seed:MatrixCodeNormalRainSeed];
        self.rainSimulation.spawnRateScale = lanes[0].weight;
        [self.rainSimulation
            warmUpWithControls:MatrixCodeRainControlsWithDensity(self.controls, lanes[0].density)
                         seconds:MatrixCodeRainWarmupSeconds
                            step:MatrixCodeRainFixedStepSeconds];

        NSMutableArray<MatrixCodeRainSimulation *> *overlap =
            [NSMutableArray arrayWithCapacity:MatrixCodeMaximumRainLanes - 1];
        for (NSInteger laneIndex = 1; laneIndex < MatrixCodeMaximumRainLanes; laneIndex++) {
            MatrixCodeRainSimulation *simulation = [[MatrixCodeRainSimulation alloc]
                initWithColumns:localColumns
                           rows:localRows
                         config:MatrixCodeRainSimulationDefaultConfig()
                      glyphMode:glyphMode
                           seed:MatrixCodeRainSeedForLane(MatrixCodeNormalRainSeed, laneIndex)];
            [overlap addObject:simulation];
        }
        self.overlapSimulations = overlap;
        [self.activeOverlapLaneIndexes removeAllIndexes];
        for (NSInteger position = 1; position < laneCount; position++) {
            MatrixCodeRainLane lane = lanes[position];
            MatrixCodeRainSimulation *simulation =
                self.overlapSimulations[(NSUInteger)(lane.index - 1)];
            simulation.spawnRateScale = lane.weight;
            [simulation
                warmUpWithControls:MatrixCodeRainControlsWithDensity(self.controls, lane.density)
                             seconds:MatrixCodeRainWarmupSeconds
                                step:MatrixCodeRainFixedStepSeconds];
            [self.activeOverlapLaneIndexes addIndex:(NSUInteger)lane.index];
        }
        self.hasLastNormalSimulationTime = NO;
        self.externalRampFromEmpty = NO;
    } else {
        [self.rainSimulation resizeToColumns:localColumns rows:localRows];
        self.rainSimulation.glyphMode = glyphMode;
        for (MatrixCodeRainSimulation *simulation in self.overlapSimulations) {
            [simulation resizeToColumns:localColumns rows:localRows];
            simulation.glyphMode = glyphMode;
        }
    }
    self.simulationUsesSharedDisplayGrid = NO;
}

- (NSArray<MatrixCodeMessageRegion *> *)messageRegionsForSharedDisplayGrid:(BOOL)sharedDisplayGrid
                                                               firstColumn:(NSInteger)firstColumn
                                                                  firstRow:(NSInteger)firstRow
                                                                   columns:(NSInteger)columns
                                                                      rows:(NSInteger)rows {
    if (!sharedDisplayGrid ||
        !MatrixCodeMessagesUseLocalCoordinates(self.session, self.controls)) {
        return nil;
    }
    return @[[[MatrixCodeMessageRegion alloc]
        initWithColumnStart:firstColumn
                   rowStart:firstRow
                    columns:columns
                       rows:rows]];
}

- (NSData *)extractSharedSimulationStateAtColumn:(NSInteger)firstColumn
                                              row:(NSInteger)firstRow
                                          columns:(NSInteger)columns
                                             rows:(NSInteger)rows {
    NSUInteger length = (NSUInteger)columns * (NSUInteger)rows * 4;
    if (self.localSimulationStateData.length != length) {
        self.localSimulationStateData = [NSMutableData dataWithLength:length];
    } else {
        memset(self.localSimulationStateData.mutableBytes, 0, length);
    }
    const uint8_t *source = self.rainSimulation.stateData.bytes;
    uint8_t *destination = self.localSimulationStateData.mutableBytes;
    NSInteger virtualColumns = self.rainSimulation.columns;
    NSInteger virtualRows = self.rainSimulation.rows;
    for (NSInteger localRow = 0; localRow < rows; localRow++) {
        NSInteger sourceRow = firstRow + localRow;
        if (sourceRow < 0 || sourceRow >= virtualRows) continue;
        NSInteger sourceColumn = MAX(0, firstColumn);
        NSInteger destinationColumn = MAX(0, -firstColumn);
        NSInteger runColumns = MIN(columns - destinationColumn,
                                   virtualColumns - sourceColumn);
        if (runColumns <= 0) continue;
        memcpy(destination + ((NSUInteger)localRow * (NSUInteger)columns +
                              (NSUInteger)destinationColumn) * 4,
               source + ((NSUInteger)sourceRow * (NSUInteger)virtualColumns +
                         (NSUInteger)sourceColumn) * 4,
               (NSUInteger)runColumns * 4);
    }
    return self.localSimulationStateData;
}

- (void)ensureInstanceCapacity:(NSUInteger)capacity {
    if (capacity <= self.instanceCapacity) return;
    self.instanceCapacity = MAX(capacity, MAX((NSUInteger)4096, self.instanceCapacity * 2));
    NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray arrayWithCapacity:3];
    for (NSUInteger index = 0; index < 3; index++) {
        id<MTLBuffer> buffer =
            [self.device newBufferWithLength:self.instanceCapacity * sizeof(MatrixCodeGlyphInstance)
                                     options:MTLResourceStorageModeShared |
                                             MTLResourceCPUCacheModeWriteCombined];
        if (buffer) [buffers addObject:buffer];
    }
    self.instanceBuffers = buffers;
    self.instanceBufferIndex = 0;
    self.instanceBuffer = buffers.firstObject;
}

- (void)updateInstancesForDrawableSize:(CGSize)drawableSize {
    [self resolveDesktopGeometryIfNeeded];
    NSArray *sessionScreens = [self.session[@"screens"] isKindOfClass:NSArray.class]
        ? self.session[@"screens"] : @[];
    BOOL usesSharedDisplayGrid = sessionScreens.count > 1;
    CGFloat fallbackScale = self.window.backingScaleFactor ?:
        NSScreen.mainScreen.backingScaleFactor ?: 1;
    CGFloat scale = self.bounds.size.width > 0
        ? drawableSize.width / self.bounds.size.width : fallbackScale;
    if (!isfinite(scale) || scale <= 0) scale = fallbackScale;
    double glyphScale = MatrixCodeNumber(self.controls, @"glyphScale", 1, 0.5, 10);
    CGFloat cellPoints = MatrixCodeRainSimulationDefaultConfig().targetCellPx * glyphScale;
    CGFloat cellPixels = cellPoints * scale;
    NSInteger firstGlobalColumn = 0;
    NSInteger firstGlobalRow = 0;
    CGFloat localOriginXPoints = 0;
    CGFloat localOriginYPoints = 0;
    if (usesSharedDisplayGrid) {
        localOriginXPoints = [MatrixCodeSession
            localOriginForVirtualOffset:self.screenLeft - self.virtualLeft
                               cellSize:cellPoints
                              firstCell:&firstGlobalColumn];
        localOriginYPoints = [MatrixCodeSession
            localOriginForVirtualOffset:self.screenTop - self.virtualTop
                               cellSize:cellPoints
                              firstCell:&firstGlobalRow];
    }
    NSInteger columns = usesSharedDisplayGrid
        ? MAX(1, (NSInteger)ceil((self.bounds.size.width - localOriginXPoints) / cellPoints))
        : MatrixCodeNormalGridDimension(self.bounds.size.width, cellPoints);
    NSInteger rows = usesSharedDisplayGrid
        ? MAX(1, (NSInteger)ceil((self.bounds.size.height - localOriginYPoints) / cellPoints))
        : MatrixCodeNormalGridDimension(self.bounds.size.height, cellPoints);
    CGFloat cellWidthPixels = usesSharedDisplayGrid
        ? cellPixels : drawableSize.width / MAX(1, columns);
    CGFloat cellHeightPixels = usesSharedDisplayGrid
        ? cellPixels : drawableSize.height / MAX(1, rows);
    CGFloat localOriginXPixels = localOriginXPoints * scale;
    CGFloat localOriginYPixels = localOriginYPoints * scale;
    NSInteger virtualColumns = usesSharedDisplayGrid
        ? MAX(1, (NSInteger)ceil(self.virtualWidth / cellPoints)) : columns;
    NSInteger virtualRows = usesSharedDisplayGrid
        ? MAX(1, (NSInteger)ceil(self.virtualHeight / cellPoints)) : rows;

    double configuredDensity = MatrixCodeNumber(self.controls, @"density", 2, 0.1, 100);
    NSString *quality = [self.controls[@"quality"] isKindOfClass:NSString.class]
        ? self.controls[@"quality"] : @"high";
    MatrixCodeRainLane lanes[8] = {0};
    NSInteger laneCount = usesSharedDisplayGrid ? 1 : MatrixCodeComputeRainLanes(
        configuredDensity,
        MatrixCodeBool(self.controls, @"allowOverlap", YES),
        MatrixCodeRainLaneCap(quality),
        lanes);
    if (usesSharedDisplayGrid) {
        lanes[0] = (MatrixCodeRainLane){
            .index = 0, .offset = 0, .density = configuredDensity, .weight = 1,
        };
    }
    [self ensureRainSimulationsForSharedDisplayGrid:usesSharedDisplayGrid
                                       localColumns:columns
                                           localRows:rows
                                      virtualColumns:virtualColumns
                                           virtualRows:virtualRows
                                                 lanes:lanes
                                             laneCount:laneCount];

    if (self.needsDeterministicRestartFromEmpty && !usesSharedDisplayGrid) {
        if (self.deterministicRestartStartsEmpty) {
            [self resetRainSimulationsFromEmpty];
        }
        self.needsDeterministicRestartFromEmpty = NO;
        self.externalRampFromEmpty = self.deterministicRestartStartsEmpty;
        self.hasLastNormalSimulationTime = NO;
    }

    if (self.needsReducedMotionWarmFrame && !usesSharedDisplayGrid) {
        NSDictionary<NSString *, id> *baseControls =
            MatrixCodeRainControlsWithDensity(self.controls, lanes[0].density);
        self.rainSimulation.spawnRateScale = lanes[0].weight;
        [self.rainSimulation warmUpWithControls:baseControls
                                        seconds:MatrixCodeRainWarmupSeconds
                                           step:MatrixCodeRainFixedStepSeconds];
        NSIndexSet *previouslyActiveOverlapLanes =
            [self.activeOverlapLaneIndexes copy];
        [self.activeOverlapLaneIndexes removeAllIndexes];
        for (NSInteger position = 1; position < laneCount; position++) {
            MatrixCodeRainLane lane = lanes[position];
            MatrixCodeRainSimulation *simulation =
                self.overlapSimulations[(NSUInteger)(lane.index - 1)];
            if (![previouslyActiveOverlapLanes containsIndex:(NSUInteger)lane.index]) {
                [simulation reset];
            }
            simulation.spawnRateScale = lane.weight;
            [simulation
                warmUpWithControls:MatrixCodeRainControlsWithDensity(self.controls,
                                                                     lane.density)
                             seconds:MatrixCodeRainWarmupSeconds
                                step:MatrixCodeRainFixedStepSeconds];
            [self.activeOverlapLaneIndexes addIndex:(NSUInteger)lane.index];
        }
        self.needsReducedMotionWarmFrame = NO;
        self.hasLastNormalSimulationTime = NO;
    }

    NSInteger wrapColumns = usesSharedDisplayGrid ? 0 : 1;
    [self ensureInstanceCapacity:(NSUInteger)((columns + wrapColumns) * rows * laneCount)];
    if (self.instanceBuffers.count > 0) {
        self.instanceBufferIndex = (self.instanceBufferIndex + 1) % self.instanceBuffers.count;
        self.instanceBuffer = self.instanceBuffers[self.instanceBufferIndex];
    }

    NSString *glyphMode = MatrixCodeGlyphMode(self.controls);
    NSTimeInterval now = self.hasCurrentFrameTime ? self.currentFrameTimeSeconds :
        (self.hasFrozenFrameTime ? self.frozenFrameTimeSeconds :
            (self.animationActive ? NSDate.date.timeIntervalSince1970
                                  : self.epochSeconds + MatrixCodeRainWarmupSeconds));
    float imageRainElapsed = usesSharedDisplayGrid
        ? (float)(now - self.epochSeconds)
        : (self.usesExternalRainTimeline
            ? (float)self.rainElapsed : (float)(now - self.epochSeconds));

    NSArray<MatrixCodeMessageRegion *> *messageRegions =
        [self messageRegionsForSharedDisplayGrid:usesSharedDisplayGrid
                                     firstColumn:firstGlobalColumn
                                        firstRow:firstGlobalRow
                                         columns:columns
                                            rows:rows];
    self.currentMessageRegions = messageRegions;
    if (usesSharedDisplayGrid) {
        self.rainSimulation.spawnRateScale = 1;
        if (self.hasCurrentFrameTime) {
            NSTimeInterval target = MatrixCodeRainWarmupSeconds +
                MAX(0, now - self.epochSeconds);
            NSTimeInterval behind = target - self.simulationClockSeconds;
            NSInteger steps = behind > 0
                ? MIN((NSInteger)floor(behind / MatrixCodeRainFixedStepSeconds), (NSInteger)15)
                : 0;
            for (NSInteger step = 0; step < steps; step++) {
                self.schedulerTokenTimeSeconds = self.epochSeconds +
                    (self.simulationClockSeconds - MatrixCodeRainWarmupSeconds);
                self.hasSchedulerTokenTime = YES;
                [self.messageScheduler
                    updateAtTimeMilliseconds:self.simulationClockSeconds * 1000.0
                                        sink:self.rainSimulation
                                     regions:messageRegions];
                [self.rainSimulation updateWithDeltaTime:MatrixCodeRainFixedStepSeconds
                                                controls:self.controls];
                self.simulationClockSeconds += MatrixCodeRainFixedStepSeconds;
            }
            self.hasSchedulerTokenTime = NO;
        }
    } else {
        BOOL pendingRain = self.usesExternalRainTimeline && self.rainElapsed < 0;
        BOOL rampingFromEmpty = self.usesExternalRainTimeline && self.densityScale < 1;
        if (rampingFromEmpty && !self.externalRampFromEmpty) {
            [self resetRainSimulationsFromEmpty];
            self.externalRampFromEmpty = YES;
        } else if (!rampingFromEmpty) {
            self.externalRampFromEmpty = NO;
        }

        NSMutableIndexSet *nextActiveOverlapLanes = [NSMutableIndexSet indexSet];
        for (NSInteger position = 1; position < laneCount; position++) {
            MatrixCodeRainLane lane = lanes[position];
            MatrixCodeRainSimulation *simulation =
                self.overlapSimulations[(NSUInteger)(lane.index - 1)];
            if (![self.activeOverlapLaneIndexes containsIndex:(NSUInteger)lane.index]) {
                [simulation reset];
            }
            simulation.spawnRateScale = self.densityScale * lane.weight;
            [nextActiveOverlapLanes addIndex:(NSUInteger)lane.index];
        }
        self.rainSimulation.spawnRateScale = self.densityScale * lanes[0].weight;

        NSTimeInterval frameElapsed = 0;
        if (self.hasCurrentFrameTime) {
            if (self.hasLastNormalSimulationTime &&
                now >= self.lastNormalSimulationTimeSeconds) {
                frameElapsed = now - self.lastNormalSimulationTimeSeconds;
            }
            self.lastNormalSimulationTimeSeconds = now;
            self.hasLastNormalSimulationTime = YES;
        }
        if (!pendingRain && self.hasCurrentFrameTime) {
            self.schedulerTokenTimeSeconds = now;
            self.hasSchedulerTokenTime = YES;
            [self.messageScheduler updateAtTimeMilliseconds:now * 1000.0
                                                       sink:self.rainSimulation];
            self.hasSchedulerTokenTime = NO;

            NSTimeInterval stepDelta = 0;
            NSInteger steps = MatrixCodeSimulationStepPlan(frameElapsed, &stepDelta);
            NSDictionary<NSString *, id> *baseControls =
                MatrixCodeRainControlsWithDensity(self.controls, lanes[0].density);
            for (NSInteger step = 0; step < steps; step++) {
                [self.rainSimulation updateWithDeltaTime:stepDelta controls:baseControls];
                for (NSInteger position = 1; position < laneCount; position++) {
                    MatrixCodeRainLane lane = lanes[position];
                    MatrixCodeRainSimulation *simulation =
                        self.overlapSimulations[(NSUInteger)(lane.index - 1)];
                    [simulation
                        updateWithDeltaTime:stepDelta
                                  controls:MatrixCodeRainControlsWithDensity(self.controls,
                                                                            lane.density)];
                }
            }
            self.activeOverlapLaneIndexes = nextActiveOverlapLanes;
        } else if (pendingRain) {
            [self.activeOverlapLaneIndexes removeAllIndexes];
        }
    }

    [self updateImageScheduleAtTime:now
                          globalCols:virtualColumns
                          globalRows:virtualRows
                           localCols:columns
                           localRows:rows];
    [self updateActiveImageFrameStateAtTime:now];
    MatrixCodeGlyphInstance *instances = self.instanceBuffer.contents;
    NSUInteger count = 0;
    BOOL imageActive =
        self.activeImage &&
        self.activeImageMaskData &&
        self.activeImageWidth > 0 &&
        self.activeImageHeight > 0 &&
        self.activeImageMaskData.length == (NSUInteger)(self.activeImageWidth * self.activeImageHeight);
    float imageColumns = 0;
    float imageRows = 0;
    float imageOriginColumn = 0;
    float imageOriginRow = 0;
    float imageFeatherU = 0;
    float imageFeatherV = 0;
    if (imageActive) {
        float scale = MatrixCodeNumber(self.images, @"imageScale", 0.72, 0.05, 1);
        float targetColumns = fmaxf(1, virtualColumns * scale);
        float imageAspect = (float)self.activeImageWidth / fmaxf(1, (float)self.activeImageHeight);
        imageColumns = fminf(virtualColumns, targetColumns);
        imageRows = imageColumns / fmaxf(0.001f, imageAspect);
        if (imageRows > virtualRows) {
            imageRows = virtualRows;
            imageColumns = fminf(virtualColumns, imageRows * imageAspect);
        }
        float remainingColumns = fmaxf(0, virtualColumns - imageColumns);
        float remainingRows = fmaxf(0, virtualRows - imageRows);
        float jitter = scale >= 0.999f ? 0 :
            MatrixCodeNumber(self.images, @"imagePlacementJitter", 0.35, 0, 1);
        float placementX = 0.5f + (self.activeImagePlacementX - 0.5f) * jitter;
        float placementY = 0.5f + (self.activeImagePlacementY - 0.5f) * jitter;
        imageOriginColumn = remainingColumns * fminf(1, fmaxf(0, placementX));
        imageOriginRow = remainingRows * fminf(1, fmaxf(0, placementY));
        float featherColumns = fminf(4.0f, fmaxf(1.0f, imageColumns * 0.04f));
        float featherRows = fminf(4.0f, fmaxf(1.0f, imageRows * 0.04f));
        imageFeatherU = featherColumns / fmaxf(1.0f, imageColumns);
        imageFeatherV = featherRows / fmaxf(1.0f, imageRows);
    }
    float imageIntensity = self.activeImageFrameIntensity;
    float imageScramble = self.activeImageFrameScramble;
    NSInteger atlasColumns = self.atlasColumns;
    NSInteger atlasRows = self.atlasRows;
    NSInteger rainGlyphCount = self.rainGlyphCount;
    NSData *sharedLocalState = usesSharedDisplayGrid
        ? [self extractSharedSimulationStateAtColumn:firstGlobalColumn
                                                  row:firstGlobalRow
                                              columns:columns
                                                 rows:rows]
        : nil;

    for (NSInteger position = 0; position < laneCount; position++) {
        MatrixCodeRainLane lane = lanes[position];
        MatrixCodeRainSimulation *simulation = position == 0
            ? self.rainSimulation
            : self.overlapSimulations[(NSUInteger)(lane.index - 1)];
        NSData *stateData = sharedLocalState ?: simulation.stateData;
        NSUInteger requiredStateLength = (NSUInteger)columns * (NSUInteger)rows * 4;
        if (stateData.length < requiredStateLength) continue;
        const uint8_t *state = stateData.bytes;
        uint32_t laneSeed = usesSharedDisplayGrid
            ? self.seed
            : MatrixCodeRainSeedForLane(MatrixCodeNormalRainSeed, lane.index);

        for (NSInteger column = 0; column < columns; column++) {
            NSInteger globalColumn = firstGlobalColumn + column;
            for (NSInteger row = 0; row < rows; row++) {
                NSInteger globalRow = firstGlobalRow + row;
                NSUInteger stateOffset =
                    ((NSUInteger)row * (NSUInteger)columns + (NSUInteger)column) * 4;
                NSInteger glyph = state[stateOffset];
                uint8_t packedBrightnessByte = state[stateOffset + 1];
                float brightness = packedBrightnessByte / 255.0f;
                uint8_t packedPhaseAndFlags = state[stateOffset + 2];
                BOOL head = (packedPhaseAndFlags & MatrixCodePackedHeadFlag) != 0;
                BOOL whiteHead = (packedPhaseAndFlags & MatrixCodePackedWhiteHeadFlag) != 0;
                float crossfade =
                    (packedPhaseAndFlags & MatrixCodePackedPhaseMask) /
                    (float)MatrixCodePackedPhaseMask;
                NSInteger oldGlyph = state[stateOffset + 3];

                // Image overlays are a native-only, default-off extension. They
                // post-process the canonical packed RainSim cell without
                // perturbing rain/message PRNG state or the stored cell bytes.
                if (imageActive && position == 0 && imageColumns > 0 && imageRows > 0) {
                    float u = ((float)globalColumn + 0.5f - imageOriginColumn) / imageColumns;
                    float v = ((float)globalRow + 0.5f - imageOriginRow) / imageRows;
                    if (u >= 0 && u <= 1 && v >= 0 && v <= 1) {
                        float imageLuminance = MatrixCodeImageSampleMask(
                            self.activeImageMaskData,
                            self.activeImageWidth,
                            self.activeImageHeight,
                            u,
                            v);
                        float signal = MatrixCodeImageSignalForLuminance(imageLuminance);
                        if (signal > 0.001f) {
                            signal *= MatrixCodeImageEdgeFeather(
                                u, v, imageFeatherU, imageFeatherV);
                        }
                        if (signal > 0.001f) {
                            uint32_t identity =
                                MatrixCodeCellIdentity(laneSeed, globalColumn, globalRow);
                            float packedBrightness = brightness;
                            float trailGate =
                                fminf(1, fmaxf(0, (brightness - 0.028f) / 0.42f));
                            float fallingGate = MatrixCodeImageFallingGate(
                                globalColumn,
                                globalRow,
                                imageRainElapsed,
                                laneSeed);
                            float revealGate = fmaxf(trailGate, fallingGate * 0.48f);
                            float dissolve = 1;
                            uint32_t animationBucket = (uint32_t)floorf(
                                (float)(now - self.epochSeconds) * 18.0f);
                            if (imageScramble > 0) {
                                float roll = MatrixCodeUnit(
                                    identity ^ animationBucket * 0x9e3779b9U ^ 0xb4b82e39U);
                                dissolve = roll >= imageScramble ? 1 : 0;
                            }
                            float influence = fminf(
                                1, signal * revealGate * imageIntensity * dissolve);
                            if (influence > 0.001f) {
                                uint32_t imageKey =
                                    identity ^
                                    (uint32_t)floorf(imageLuminance * 255.0f) * 0x85ebca6bU;
                                NSInteger imageGlyph = MatrixCodeImageGlyphForLuminance(
                                    imageLuminance, imageKey, glyphMode);
                                float bright = fmaxf(
                                    0, (imageLuminance - 0.38f) / 0.62f);
                                float dark = fmaxf(
                                    0, (0.58f - imageLuminance) / 0.58f);
                                brightness *= 1.0f - 0.46f * dark * influence;
                                brightness = fmaxf(
                                    brightness,
                                    bright * influence * (0.12f + 0.48f * fallingGate));
                                brightness = fminf(
                                    1.45f,
                                    brightness +
                                        bright * influence *
                                        fmaxf(packedBrightness, 0.08f) * 0.58f);

                                float glyphRoll = MatrixCodeUnit(
                                    identity ^ animationBucket * 0x27d4eb2dU ^ 0x68e31da4U);
                                if (glyph < rainGlyphCount &&
                                    glyphRoll < fminf(0.96f, 0.18f + influence * 0.78f)) {
                                    NSInteger replacement = imageGlyph;
                                    float scrambleRoll = MatrixCodeUnit(
                                        identity ^ animationBucket * 0x85ebca6bU ^ 0xd3a2646cU);
                                    if (imageScramble > 0 &&
                                        scrambleRoll < imageScramble * 0.75f) {
                                        replacement = MatrixCodeRainGlyphIndex(
                                            identity ^ animationBucket ^ 0x3c6ef372U,
                                            glyphMode);
                                    }
                                    oldGlyph = glyph;
                                    glyph = replacement;
                                    crossfade = 1;
                                }
                            }
                        }
                    }
                }

                if (packedBrightnessByte == 0 && brightness <= 0) continue;
                if (glyph < 0 || glyph >= self.glyphCount) glyph = 0;
                if (oldGlyph < 0 || oldGlyph >= self.glyphCount) oldGlyph = glyph;
                NSInteger atlasColumn = glyph % atlasColumns;
                NSInteger atlasRow = glyph / atlasColumns;
                NSInteger oldAtlasColumn = oldGlyph % atlasColumns;
                NSInteger oldAtlasRow = oldGlyph / atlasColumns;
                MatrixCodeGlyphInstance instance = (MatrixCodeGlyphInstance){
                    .origin = {
                        localOriginXPixels + (column + lane.offset) * cellWidthPixels,
                        localOriginYPixels + row * cellHeightPixels,
                    },
                    .size = {cellWidthPixels, cellHeightPixels},
                    .atlasOrigin = {
                        (float)atlasColumn / atlasColumns,
                        (float)(atlasRows - atlasRow) / atlasRows,
                    },
                    .atlasSize = {1.0f / atlasColumns, -1.0f / atlasRows},
                    .oldAtlasOrigin = {
                        (float)oldAtlasColumn / atlasColumns,
                        (float)(atlasRows - oldAtlasRow) / atlasRows,
                    },
                    .crossfade = crossfade,
                    .brightness = brightness,
                    .isHead = head ? 1 : 0,
                    .whiteHead = whiteHead ? 1 : 0,
                };
                instances[count++] = instance;

                // Match overlapLanes.ts wrapping: a fractionally shifted
                // last-column cell also appears in the clipped strip at left.
                if (!usesSharedDisplayGrid && lane.index > 0 &&
                    column == columns - 1) {
                    instance.origin.x = localOriginXPixels +
                        (-1 + lane.offset) * cellWidthPixels;
                    if (instance.origin.x + instance.size.x > 0) {
                        instances[count++] = instance;
                    }
                }
            }
        }
    }
    self.instanceCount = count;
    MatrixCodeUniforms uniforms = self.uniforms;
    uniforms.viewport = (vector_float2){drawableSize.width, drawableSize.height};
    self.uniforms = uniforms;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.commandQueue || !self.pipeline) return;
    [self updateDrawableSizeForCurrentRenderScale];
    NSDate *frameDate = self.animationActive ? NSDate.date : nil;
    self.hasCurrentFrameTime = frameDate != nil;
    if (frameDate) {
        self.currentFrameTimeSeconds = frameDate.timeIntervalSince1970;
        double previousFrameTime = self.lastMeasuredFrameTimeSeconds;
        double framesPerSecond = [self updateMeasuredFramesPerSecondAtTime:self.currentFrameTimeSeconds];
        if (![self usesSynchronizedMultiMonitorTimeline] &&
            previousFrameTime > 0 &&
            self.currentFrameTimeSeconds > previousFrameTime) {
            double frameMilliseconds = fmin(
                100, (self.currentFrameTimeSeconds - previousFrameTime) * 1000.0);
            double nextScale = [self.adaptiveResolution
                updateWithFrameMilliseconds:frameMilliseconds];
            if (self.adaptiveResolutionEnabled && fabs(nextScale - self.renderScale) > 0.000001) {
                self.renderScale = nextScale;
                [self updateDrawableSizeForCurrentRenderScale];
            }
        }
        if (self.frameHandler) {
            self.frameHandler(self, frameDate, framesPerSecond);
        }
    }
    [self updateInstancesForDrawableSize:view.drawableSize];
    self.hasCurrentFrameTime = NO;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (![self encodeFrameToTexture:drawable.texture commandBuffer:commandBuffer]) return;
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

#if DEBUG
+ (NSInteger)diagnosticBloomLevelCountForQuality:(NSString *)quality {
    return MatrixCodeBloomLevelCount(quality ?: @"high");
}

+ (NSInteger)diagnosticAtlasColumnCountForGlyphCount:(NSInteger)glyphCount {
    return MatrixCodeAtlasColumnCount(glyphCount);
}

+ (NSInteger)diagnosticAtlasCellPixels {
    return (NSInteger)MatrixCodeAtlasCellPixels;
}

+ (NSInteger)diagnosticNormalGridDimensionForPoints:(float)points
                                           glyphScale:(float)glyphScale {
    return MatrixCodeNormalGridDimension(
        points, (float)MatrixCodeRainSimulationDefaultConfig().targetCellPx * glyphScale);
}

+ (BOOL)diagnosticMessagesUseLocalCoordinatesForSession:(NSDictionary *)session
                                                controls:(NSDictionary *)controls {
    return MatrixCodeMessagesUseLocalCoordinates(session ?: @{}, controls ?: @{});
}

+ (uint32_t)diagnosticNormalRainSeed {
    return MatrixCodeNormalRainSeed;
}

+ (uint32_t)diagnosticRainSeedForLane:(NSInteger)laneIndex {
    return MatrixCodeRainSeedForLane(MatrixCodeNormalRainSeed, laneIndex);
}

- (NSData *)diagnosticPackedStateWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0) return [NSData data];
    [self updateInstancesForDrawableSize:CGSizeMake(width, height)];
    NSData *state = self.simulationUsesSharedDisplayGrid
        ? self.localSimulationStateData
        : self.rainSimulation.stateData;
    return [state copy];
}

- (BOOL)diagnosticRendererConsumesPackedStateWithWidth:(NSUInteger)width
                                                 height:(NSUInteger)height {
    if (width == 0 || height == 0 || MatrixCodeBool(self.images, @"enabled", NO)) {
        return NO;
    }
    [self updateInstancesForDrawableSize:CGSizeMake(width, height)];
    if (self.simulationUsesSharedDisplayGrid) return NO;
    NSData *stateData = self.rainSimulation.stateData;
    NSInteger columns = self.rainSimulation.columns;
    NSInteger rows = self.rainSimulation.rows;
    if (columns <= 0 || rows <= 0 ||
        stateData.length < (NSUInteger)columns * (NSUInteger)rows * 4) {
        return NO;
    }
    const uint8_t *state = stateData.bytes;
    const MatrixCodeGlyphInstance *instances = self.instanceBuffer.contents;
    NSUInteger renderedIndex = 0;
    for (NSInteger column = 0; column < columns; column++) {
        for (NSInteger row = 0; row < rows; row++) {
            NSUInteger offset =
                ((NSUInteger)row * (NSUInteger)columns + (NSUInteger)column) * 4;
            float brightness = state[offset + 1] / 255.0f;
            if (state[offset + 1] == 0) continue;
            if (renderedIndex >= self.instanceCount) return NO;
            MatrixCodeGlyphInstance instance = instances[renderedIndex++];
            uint8_t phaseAndFlags = state[offset + 2];
            float phase = (phaseAndFlags & MatrixCodePackedPhaseMask) /
                (float)MatrixCodePackedPhaseMask;
            NSInteger glyph = state[offset];
            NSInteger oldGlyph = state[offset + 3];
            NSInteger atlasColumn = glyph % self.atlasColumns;
            NSInteger atlasRow = glyph / self.atlasColumns;
            NSInteger oldAtlasColumn = oldGlyph % self.atlasColumns;
            NSInteger oldAtlasRow = oldGlyph / self.atlasColumns;
            if (fabsf(instance.brightness - brightness) > 0.0001f ||
                fabsf(instance.crossfade - phase) > 0.0001f ||
                (instance.isHead > 0.5f) !=
                    ((phaseAndFlags & MatrixCodePackedHeadFlag) != 0) ||
                (instance.whiteHead > 0.5f) !=
                    ((phaseAndFlags & MatrixCodePackedWhiteHeadFlag) != 0) ||
                fabsf(instance.atlasOrigin.x -
                       (float)atlasColumn / self.atlasColumns) > 0.0001f ||
                fabsf(instance.atlasOrigin.y -
                       (float)(self.atlasRows - atlasRow) / self.atlasRows) > 0.0001f ||
                fabsf(instance.oldAtlasOrigin.x -
                       (float)oldAtlasColumn / self.atlasColumns) > 0.0001f ||
                fabsf(instance.oldAtlasOrigin.y -
                       (float)(self.atlasRows - oldAtlasRow) / self.atlasRows) > 0.0001f) {
                return NO;
            }
        }
    }
    return renderedIndex > 0;
}

- (double)diagnosticUpdateAdaptiveResolutionWithFrameMilliseconds:(double)frameMilliseconds {
    double nextScale = [self.adaptiveResolution
        updateWithFrameMilliseconds:frameMilliseconds];
    if (self.adaptiveResolutionEnabled &&
        ![self usesSynchronizedMultiMonitorTimeline]) {
        self.renderScale = nextScale;
        [self updateDrawableSizeForCurrentRenderScale];
    }
    return self.renderScale;
}

- (NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!self.commandQueue || !self.pipeline || width == 0 || height == 0) return nil;
    [self updateInstancesForDrawableSize:CGSizeMake(width, height)];
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:self.colorPixelFormat
                                                           width:width height:height mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    textureDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [self.device newTextureWithDescriptor:textureDescriptor];
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (![self encodeFrameToTexture:target commandBuffer:commandBuffer]) return nil;
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    [target getBytes:data.mutableBytes bytesPerRow:width * 4
          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    return data;
}

- (NSArray<NSNumber *> *)diagnosticGlyphStateSnapshotWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0) return @[];
    [self updateInstancesForDrawableSize:CGSizeMake(width, height)];
    NSData *stateData = self.simulationUsesSharedDisplayGrid
        ? self.localSimulationStateData
        : self.rainSimulation.stateData;
    NSUInteger cellCount = stateData.length / 4;
    const uint8_t *states = stateData.bytes;
    NSMutableArray<NSNumber *> *snapshot = [NSMutableArray arrayWithCapacity:cellCount];
    for (NSUInteger index = 0; index < cellCount; index++) {
        [snapshot addObject:@(states[index * 4])];
    }
    return snapshot;
}
#endif

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.hasResolvedDesktopGeometry = NO;
    [self updateDrawableSizeForCurrentRenderScale];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateDrawableSizeForCurrentRenderScale];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawableSizeForCurrentRenderScale];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    self.hasResolvedDesktopGeometry = NO;
}

@end
