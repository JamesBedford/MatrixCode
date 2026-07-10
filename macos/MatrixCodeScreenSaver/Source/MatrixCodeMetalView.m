#import "MatrixCodeMetalView.h"

#import <CoreText/CoreText.h>
#import <CoreVideo/CoreVideo.h>
#import <simd/simd.h>
#import <string.h>

#import "MatrixCodeSession.h"
#import "MatrixCodeRainLifecycle.h"
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
    float digitValue;
} MatrixCodeGlyphInstance;

_Static_assert(sizeof(MatrixCodeGlyphInstance) == 64,
               "MatrixCodeGlyphInstance must match MatrixCodeShaders.msl");

typedef struct {
    uint32_t identity;
    uint32_t randomCounter;
    uint8_t glyphNew;
    uint8_t glyphOld;
    uint8_t wasHead;
    uint8_t initialized;
    float phase;
} MatrixCodeGlyphCellState;

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
    float glowRadius;
    float leadBrightness;
    vector_float3 padding4;
} MatrixCodeUniforms;

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

static float MatrixCodeVanDerCorput(NSUInteger value) {
    float result = 0;
    float denominator = 1;
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

static uint32_t MatrixCodeNextGlyphEventKey(MatrixCodeGlyphCellState *state) {
    state->randomCounter = MatrixCodeHash(state->randomCounter + 0x9e3779b9U);
    return state->randomCounter;
}

static float MatrixCodeNumber(NSDictionary *dictionary, NSString *key, float fallback, float minimum, float maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) return fallback;
    return fminf(maximum, fmaxf(minimum, [value floatValue]));
}

static BOOL MatrixCodeBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        ? [value boolValue] : fallback;
}

static BOOL MatrixCodeMessageUsesDropLayout(NSDictionary *dictionary) {
    id value = dictionary[@"messageLayout"];
    return [value isKindOfClass:NSString.class] && [value isEqualToString:@"drop"];
}

static BOOL MatrixCodeMessageReadsBottomToTop(NSDictionary *dictionary) {
    id value = dictionary[@"messageDirection"];
    return [value isKindOfClass:NSString.class] && [value isEqualToString:@"bottomToTop"];
}

static NSMutableDictionary *MatrixCodeSanitizedRenderImageItem(id item) {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dictionary = item;
    NSInteger width = (NSInteger)MatrixCodeNumber(dictionary, @"width", 0, 1, 128);
    NSInteger height = (NSInteger)MatrixCodeNumber(dictionary, @"height", 0, 1, 128);
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

static NSDictionary<NSString *, NSString *> *MatrixCodeGlyphFontNames(void) {
    return @{
        @"matrix": @"HiraginoSans-W6",
        @"gothic": @"YuGothic-Bold",
        @"mono": @"Menlo-Bold",
        @"terminal": @"Courier-Bold",
        @"rounded": @"ArialRoundedMTBold",
        @"mincho": @"HiraginoMinchoProN-W6",
    };
}

static NSString *MatrixCodePrimaryGlyphFontName(NSDictionary *dictionary) {
    NSString *font = MatrixCodeGlyphFont(dictionary);
    NSDictionary<NSString *, NSString *> *names = MatrixCodeGlyphFontNames();
    return names[font] ?: names[@"matrix"];
}

static CTFontRef MatrixCodeCreateFontWithFallbacks(NSArray<NSString *> *fallbacks, CGFloat size) {
    for (NSString *name in fallbacks) {
        CTFontRef candidate = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
        if (candidate) return candidate;
    }
    return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
}

static CTFontRef MatrixCodeCreateGlyphFont(NSDictionary *dictionary, CGFloat size) {
    NSString *primary = MatrixCodePrimaryGlyphFontName(dictionary);
    return MatrixCodeCreateFontWithFallbacks(@[primary, @"HiraginoSans-W6", @"Menlo-Bold"], size);
}

static CTFontRef MatrixCodeCreateReadableDigitFont(NSDictionary *dictionary, CGFloat size) {
    NSString *primary = MatrixCodePrimaryGlyphFontName(dictionary);
    return MatrixCodeCreateFontWithFallbacks(@[@"Menlo-Bold", @"Courier-Bold", primary,
                                               @"HiraginoSans-W6"], size);
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

static float MatrixCodeProceduralDigitValueForRainGlyph(NSInteger glyph,
                                                        NSInteger rainGlyphCount,
                                                        NSDictionary *controls) {
    if (glyph < 0 || glyph >= rainGlyphCount) return -1;
    NSInteger digit = MatrixCodeRainDigitValueForGlyphIndex(glyph, MatrixCodeGlyphMode(controls));
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
    if (MatrixCodeShouldDrawReadableDigitGlyph(glyph, controls)) {
        return @"Menlo-Bold";
    }
    return MatrixCodePrimaryGlyphFontName(controls);
}
#endif

static float MatrixCodeVignette(NSDictionary *dictionary) {
    id value = dictionary[@"vignette"];
    if ([value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return [value boolValue] ? 0.42f : 0;
    }
    return MatrixCodeNumber(dictionary, @"vignette", 0, 0, 1);
}

static vector_float3 MatrixCodeRGB(uint32_t rgb) {
    return (vector_float3){
        ((rgb >> 16) & 0xff) / 255.0f,
        ((rgb >> 8) & 0xff) / 255.0f,
        (rgb & 0xff) / 255.0f,
    };
}

static float MatrixCodeEffectiveTrailLength(float trailLength, float rows, float speedControl) {
    const float controlMin = 0.01f;
    const float controlMax = 0.5f;
    const float maxTrailViewports = 3.0f;
    float percent = fminf(1, fmaxf(0, (trailLength - controlMin) / (controlMax - controlMin)));

    float averageSpeed = (3.5f + 8.0f * 0.5f) * fmaxf(speedControl, 0.1f);
    float viewportRows = fmaxf(1, rows);
    float previousMaxRows = averageSpeed * 1.2f * logf(0.004f) / logf(controlMax);
    float minRows = viewportRows;
    float maxRows = fmaxf(fmaxf(viewportRows * maxTrailViewports, previousMaxRows), minRows + 1);
    float targetRows = minRows * powf(maxRows / minRows, percent);

    return expf(logf(0.004f) * 1.2f * averageSpeed / fmaxf(1, targetRows));
}

static void MatrixCodeConsiderRefreshRate(double refreshRate, double *best) {
    if (!isfinite(refreshRate) || refreshRate < 24) return;
    *best = fmax(*best, refreshRate);
}

static NSInteger MatrixCodeFramesPerSecondFromCandidates(NSInteger screenMaximum,
                                                         double displayModeRefreshRate,
                                                         double displayLinkRefreshRate) {
    double best = 0;
    MatrixCodeConsiderRefreshRate(screenMaximum, &best);
    MatrixCodeConsiderRefreshRate(displayModeRefreshRate, &best);
    MatrixCodeConsiderRefreshRate(displayLinkRefreshRate, &best);
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

@interface MatrixCodeMetalView () <MTKViewDelegate>
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLTexture> atlas;
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
@property(nonatomic) BOOL animationActive;
@property(nonatomic) NSInteger atlasColumns;
@property(nonatomic) NSInteger atlasRows;
@property(nonatomic) NSInteger glyphCount;
@property(nonatomic) NSInteger rainGlyphCount;
@property(nonatomic) NSInteger messageGlyphStart;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *messageGlyphs;
@property(nonatomic) float screenLeft;
@property(nonatomic) float screenTop;
@property(nonatomic) float virtualLeft;
@property(nonatomic) float virtualTop;
@property(nonatomic) float virtualWidth;
@property(nonatomic) float virtualHeight;
@property(nonatomic) float densityScale;
@property(nonatomic) NSTimeInterval rainElapsed;
@property(nonatomic) BOOL usesExternalRainTimeline;
@property(nonatomic, copy) NSDictionary<NSString *, id> *messages;
@property(nonatomic, strong) MatrixCodeTokenResolver *tokenResolver;
@property(nonatomic) NSTimeInterval nextMessageFire;
@property(nonatomic) NSTimeInterval activeMessageStart;
@property(nonatomic) NSTimeInterval activeMessageEnd;
@property(nonatomic, copy, nullable) NSString *activeMessageTemplate;
@property(nonatomic, copy, nullable) NSString *activeMessageDisplay;
@property(nonatomic) NSInteger activeMessageRow;
@property(nonatomic) NSInteger activeMessageStartColumn;
@property(nonatomic) NSInteger activeMessagePlacementColumns;
@property(nonatomic) NSInteger activeMessageColumn;
@property(nonatomic) NSInteger activeMessageStartRow;
@property(nonatomic) NSInteger activeMessagePlacementRows;
@property(nonatomic, strong) NSMutableData *messageClaimedData;
@property(nonatomic, strong) NSMutableData *messageTargetGlyphData;
@property(nonatomic) NSInteger messageTargetGlyphCount;
@property(nonatomic) float activeMessageFrameIntensity;
@property(nonatomic) float activeMessageFrameScramble;
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
@property(nonatomic, strong) NSMutableData *glyphStateData;
@property(nonatomic) NSInteger glyphStateColumns;
@property(nonatomic) NSInteger glyphStateRows;
@property(nonatomic) NSInteger glyphStateLaneCount;
@property(nonatomic) NSTimeInterval lastGlyphStateTime;
@property(nonatomic) BOOL hasGlyphStateTime;
@property(nonatomic, strong) NSMutableData *columnBrightnessData;
@property(nonatomic, strong) NSMutableData *columnHeadData;
@property(nonatomic, strong) NSMutableData *columnWhiteHeadData;
@property(nonatomic) NSTimeInterval currentFrameTimeSeconds;
@property(nonatomic) BOOL hasCurrentFrameTime;
@property(nonatomic) NSTimeInterval frozenFrameTimeSeconds;
@property(nonatomic) BOOL hasFrozenFrameTime;
- (void)resetActiveMessageTargetState;
- (void)ensureActiveMessageTargetCapacityForCount:(NSInteger)count;
- (void)updateActiveMessageFrameStateAtTime:(NSTimeInterval)now
                            framesPerSecond:(double)framesPerSecond;
- (void)updateImageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows;
- (void)updateActiveImageFrameStateAtTime:(NSTimeInterval)now;
@end

@implementation MatrixCodeMetalView

+ (NSInteger)maximumFramesPerSecondForScreen:(NSScreen *)screen {
    return MatrixCodeDisplayFramesPerSecond(screen);
}

#if DEBUG
+ (float)diagnosticEffectiveTrailLength:(float)trailLength
                                  rows:(float)rows
                          speedControl:(float)speedControl {
    return MatrixCodeEffectiveTrailLength(trailLength, rows, speedControl);
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
    return MatrixCodeProceduralDigitValueForRainGlyph(glyph, rainGlyphCount, controls ?: @{});
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
    self.paused = YES;
    self.enableSetNeedsDisplay = NO;
    self.preferredFramesPerSecond = MatrixCodeDisplayFramesPerSecond(NSScreen.mainScreen);
    self.delegate = self;
    self.animationActive = NO;
    self.densityScale = 1;
    self.messageClaimedData = [NSMutableData data];
    self.messageTargetGlyphData = [NSMutableData data];
    self.session = session ?: @{};
    self.seed = [session[@"seed"] respondsToSelector:@selector(unsignedIntValue)]
        ? [session[@"seed"] unsignedIntValue]
        : arc4random();
    self.epochSeconds = [session[@"epoch"] respondsToSelector:@selector(doubleValue)]
        ? [session[@"epoch"] doubleValue] / 1000.0
        : NSDate.date.timeIntervalSince1970;

    self.commandQueue = [device newCommandQueue];
    [self resolveDesktopGeometry];
    [self reloadStoredValues:storedValues];
    if (![self buildPipeline] || ![self buildAtlas]) return nil;
    return self;
}

- (void)configureFramePacingForScreen:(NSScreen *)screen {
    self.preferredFramesPerSecond = MatrixCodeDisplayFramesPerSecond(screen);
}

- (void)setAnimationActive:(BOOL)active {
    _animationActive = active;
    self.hasFrozenFrameTime = NO;
    self.paused = !active;
    if (active) [self draw];
}

- (void)freezeAnimationAtDate:(NSDate *)date {
    NSDate *frameDate = date ?: NSDate.date;
    self.frozenFrameTimeSeconds = frameDate.timeIntervalSince1970;
    self.hasFrozenFrameTime = YES;
    _animationActive = NO;
    self.paused = YES;
    [self draw];
}

- (void)setDensityScale:(float)densityScale {
    _densityScale = fminf(1, fmaxf(0, densityScale));
}

- (void)setDensityScale:(float)densityScale rainElapsed:(NSTimeInterval)rainElapsed {
    [self setDensityScale:densityScale];
    self.rainElapsed = rainElapsed;
    self.usesExternalRainTimeline = YES;
}

- (void)resetGlyphState {
    self.glyphStateData = nil;
    self.glyphStateColumns = 0;
    self.glyphStateRows = 0;
    self.glyphStateLaneCount = 0;
    self.hasGlyphStateTime = NO;
    self.lastGlyphStateTime = 0;
}

- (void)reloadStoredValues:(NSDictionary<NSString *,NSString *> *)storedValues {
    BOOL previousMirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSString *previousGlyphMode = MatrixCodeGlyphMode(self.controls);
    NSString *previousFont = MatrixCodeGlyphFont(self.controls);
    NSDictionary *controls = nil;
    NSString *raw = storedValues[@"mx-controls"];
    if ([raw isKindOfClass:NSString.class]) {
        NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:NSDictionary.class]) controls = object;
    }
    self.controls = controls ?: @{};
    NSDictionary *messages = nil;
    NSString *messagesRaw = storedValues[@"mx-messages"];
    if ([messagesRaw isKindOfClass:NSString.class]) {
        NSData *data = [messagesRaw dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:NSDictionary.class]) messages = object;
    }
    self.messages = messages ?: @{
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
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:[NSDate dateWithTimeIntervalSince1970:self.epochSeconds]];
    self.activeMessageTemplate = nil;
    self.activeMessageDisplay = nil;
    [self resetActiveMessageTargetState];
    self.activeMessageStart = 0;
    self.activeMessageEnd = 0;
    self.activeMessageRow = 0;
    self.activeMessageColumn = 0;
    self.activeMessageStartColumn = 0;
    self.activeMessageStartRow = 0;
    self.activeMessagePlacementColumns = 0;
    self.activeMessagePlacementRows = 0;
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
    float frequency = MatrixCodeNumber(self.messages, @"frequencyMs", 8000, 500, 600000) / 1000.0f;
    float imageFrequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0f;
    NSTimeInterval scheduleBase = self.animationActive
        ? NSDate.date.timeIntervalSince1970 : self.epochSeconds;
    self.nextMessageFire = scheduleBase + frequency *
        (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ 0xa511e9b3U));
    self.nextImageFire = scheduleBase + imageFrequency *
        (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ 0x6d2b79f5U));
    [self updatePalette];
    BOOL nextMirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSString *nextGlyphMode = MatrixCodeGlyphMode(self.controls);
    NSString *nextFont = MatrixCodeGlyphFont(self.controls);
    BOOL glyphModeChanged = ![previousGlyphMode isEqualToString:nextGlyphMode];
    if (glyphModeChanged) {
        [self resetGlyphState];
    }
    if (self.atlas &&
        (previousMirror != nextMirror || ![previousFont isEqualToString:nextFont] ||
         glyphModeChanged)) {
        [self buildAtlas];
    }
}

- (MatrixCodeGlyphCellState *)glyphStatesForColumns:(NSInteger)columns
                                               rows:(NSInteger)rows
                                          laneCount:(NSInteger)laneCount {
    NSUInteger cellCount = (NSUInteger)MAX(1, columns) * (NSUInteger)MAX(1, rows) *
        (NSUInteger)MAX(1, laneCount);
    NSUInteger length = cellCount * sizeof(MatrixCodeGlyphCellState);
    if (!self.glyphStateData ||
        self.glyphStateColumns != columns ||
        self.glyphStateRows != rows ||
        self.glyphStateLaneCount != laneCount ||
        self.glyphStateData.length != length) {
        self.glyphStateData = [NSMutableData dataWithLength:length];
        self.glyphStateColumns = columns;
        self.glyphStateRows = rows;
        self.glyphStateLaneCount = laneCount;
    }
    return (MatrixCodeGlyphCellState *)self.glyphStateData.mutableBytes;
}

- (float)advanceGlyphStateClockToTime:(NSTimeInterval)time {
    if (!isfinite(time)) time = 0;
    if (!self.hasGlyphStateTime) {
        self.lastGlyphStateTime = time;
        self.hasGlyphStateTime = YES;
        return 1.0f / 60.0f;
    }
    if (time < self.lastGlyphStateTime) {
        [self resetGlyphState];
        self.lastGlyphStateTime = time;
        self.hasGlyphStateTime = YES;
        return 1.0f / 60.0f;
    }
    float dt = (float)(time - self.lastGlyphStateTime);
    self.lastGlyphStateTime = time;
    return fminf(fmaxf(dt, 0), 1.0f / 15.0f);
}

- (void)resolveDesktopGeometry {
    NSArray *screens = [self.session[@"screens"] isKindOfClass:NSArray.class] ? self.session[@"screens"] : @[];
    NSString *currentID = [self.session[@"currentScreenId"] isKindOfClass:NSString.class]
        ? self.session[@"currentScreenId"]
        : nil;
    float minX = 0, minY = 0, maxX = self.bounds.size.width, maxY = self.bounds.size.height;
    BOOL first = YES;
    for (NSDictionary *screen in screens) {
        if (![screen isKindOfClass:NSDictionary.class]) continue;
        float left = [screen[@"left"] floatValue];
        float top = [screen[@"top"] floatValue];
        float width = [screen[@"width"] floatValue];
        float height = [screen[@"height"] floatValue];
        if (first) {
            minX = left; minY = top; maxX = left + width; maxY = top + height; first = NO;
        } else {
            minX = fminf(minX, left); minY = fminf(minY, top);
            maxX = fmaxf(maxX, left + width); maxY = fmaxf(maxY, top + height);
        }
        if (currentID && [screen[@"id"] isEqual:currentID]) {
            self.screenLeft = left;
            self.screenTop = top;
        }
    }
    self.virtualLeft = minX;
    self.virtualTop = minY;
    self.virtualWidth = maxX - minX;
    self.virtualHeight = maxY - minY;
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
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"matrixVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"matrixFragment"];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    self.pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.pipeline) NSLog(@"MatrixCode: Metal pipeline creation failed: %@", error);
    return self.pipeline != nil;
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
    self.atlasColumns = 16;
    self.atlasRows = (glyphs.count + self.atlasColumns - 1) / self.atlasColumns;
    const size_t cell = 48;
    const size_t width = cell * self.atlasColumns;
    const size_t height = cell * self.atlasRows;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width,
                                                 colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(colorSpace);
    if (!context) return NO;
    CGContextSetGrayFillColor(context, 1, 1);
    CTFontRef font = MatrixCodeCreateGlyphFont(self.controls, 31);
    BOOL readableDigits = MatrixCodeGlyphModeUsesReadableDigits(self.controls);
    CTFontRef digitFont = readableDigits ? MatrixCodeCreateReadableDigitFont(self.controls, 31) : NULL;
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
    [glyphs enumerateObjectsUsingBlock:^(NSString *glyph, NSUInteger index, BOOL *stop) {
        NSString *displayGlyph = MatrixCodeAtlasDisplayGlyph(glyph, index, self.rainGlyphCount,
                                                             self.controls);
        NSInteger column = index % self.atlasColumns;
        NSInteger row = index / self.atlasColumns;
        CGFloat cellY = height - (row + 1) * cell;
        CGRect digitRect = CGRectMake(column * cell, cellY, cell, cell);
        NSDictionary *glyphAttributes =
            readableDigits && MatrixCodeGlyphStringIsDigit(displayGlyph) ? digitAttributes : attributes;
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:displayGlyph
                                                                     attributes:glyphAttributes];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
        CGFloat x = column * cell + (cell - bounds.size.width) * 0.5 - bounds.origin.x;
        CGFloat y = height - (row + 1) * cell + (cell - bounds.size.height) * 0.5 - bounds.origin.y;
        CGContextSaveGState(context);
        if (mirror && index < self.rainGlyphCount) {
            CGContextTranslateCTM(context, column * cell + cell, 0);
            CGContextScaleCTM(context, -1, 1);
            x = (cell - bounds.size.width) * 0.5 - bounds.origin.x;
            digitRect = CGRectMake(0, cellY, cell, cell);
        }
        if (index < self.rainGlyphCount &&
            MatrixCodeShouldDrawReadableDigitGlyph(displayGlyph, self.controls)) {
            MatrixCodeDrawReadableDigitGlyph(context, displayGlyph, digitRect);
            CGContextRestoreGState(context);
            CFRelease(line);
            return;
        }
        CGContextSetTextPosition(context, x, y);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CFRelease(line);
    }];
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

- (void)resetActiveMessageTargetState {
    self.messageClaimedData.length = 0;
    self.messageTargetGlyphData.length = 0;
    self.messageTargetGlyphCount = 0;
    self.activeMessageFrameIntensity = 1;
    self.activeMessageFrameScramble = 0;
}

- (void)ensureActiveMessageTargetCapacityForCount:(NSInteger)count {
    NSInteger clampedCount = MAX(0, count);
    BOOL countChanged = self.messageTargetGlyphCount != clampedCount;
    NSUInteger claimLength = (NSUInteger)clampedCount;
    NSUInteger targetLength = (NSUInteger)clampedCount * sizeof(NSInteger);
    if (self.messageClaimedData.length < claimLength) {
        self.messageClaimedData = [NSMutableData dataWithLength:claimLength];
        countChanged = YES;
    }
    if (self.messageTargetGlyphData.length < targetLength) {
        self.messageTargetGlyphData = [NSMutableData dataWithLength:targetLength];
        countChanged = YES;
    }
    self.messageTargetGlyphCount = clampedCount;
    if (countChanged && clampedCount > 0) {
        memset(self.messageClaimedData.mutableBytes, 0, claimLength);
        NSInteger *targets = (NSInteger *)self.messageTargetGlyphData.mutableBytes;
        for (NSInteger index = 0; index < clampedCount; index++) targets[index] = NSNotFound;
    }
}

- (void)updateMessageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows {
    BOOL enabled = MatrixCodeBool(self.messages, @"enabled", NO);
    NSArray *configured = [self.messages[@"messages"] isKindOfClass:NSArray.class]
        ? self.messages[@"messages"]
        : @[];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSUInteger index = 0; index < MIN((NSUInteger)12, configured.count); index++) {
        id item = configured[index];
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *text = item;
        text = [text substringToIndex:MIN((NSUInteger)120, text.length)];
        if ([text stringByTrimmingCharactersInSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            [candidates addObject:text];
        }
    }
    if (!enabled || !candidates.count) {
        self.activeMessageTemplate = nil;
        self.activeMessageDisplay = nil;
        [self resetActiveMessageTargetState];
        return;
    }
    if (self.activeMessageTemplate && now >= self.activeMessageEnd) {
        self.activeMessageTemplate = nil;
        self.activeMessageDisplay = nil;
        [self resetActiveMessageTargetState];
        float frequency = MatrixCodeNumber(self.messages, @"frequencyMs", 8000, 500, 600000) / 1000.0f;
        uint32_t cycle = (uint32_t)floor(now - self.epochSeconds);
        self.nextMessageFire = now + frequency *
            (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ cycle ^ 0xa511e9b3U));
    }
    if (!self.activeMessageTemplate && now >= self.nextMessageFire) {
        uint32_t activation = (uint32_t)floor((now - self.epochSeconds) * 10);
        NSUInteger selected = MatrixCodeHash(self.seed ^ activation ^ 0x63d83595U) % candidates.count;
        float vignette = MatrixCodeVignette(self.controls);
        NSInteger placementRows = vignette > 0 ? localRows : globalRows;
        NSInteger placementCols = vignette > 0 ? localCols : globalCols;
        BOOL dropLayout = MatrixCodeMessageUsesDropLayout(self.messages);
        NSString *template = candidates[selected];
        NSString *display = [self.tokenResolver resolveText:template
                                                    atDate:[NSDate dateWithTimeIntervalSince1970:now]
                                           framesPerSecond:self.preferredFramesPerSecond];
        BOOL renderable = NO;
        for (NSUInteger index = 0; index < display.length; index++) {
            if (self.messageGlyphs[[display substringWithRange:NSMakeRange(index, 1)]] != nil) {
                renderable = YES;
                break;
            }
        }
        NSInteger placementSpan = dropLayout ? placementRows : placementCols;
        if (!renderable || display.length > placementSpan) {
            float frequency = MatrixCodeNumber(self.messages, @"frequencyMs", 8000, 500, 600000) / 1000.0f;
            self.nextMessageFire = now + frequency *
                (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ activation ^ 0xa511e9b3U));
            return;
        }

        self.activeMessageTemplate = template;
        self.activeMessageDisplay = display;
        self.activeMessagePlacementColumns = placementCols;
        self.activeMessagePlacementRows = placementRows;
        [self resetActiveMessageTargetState];
        self.activeMessageStart = now;
        float appear = MatrixCodeNumber(self.messages, @"appearMs", 4000, 0, 600000) / 1000.0f;
        float hold = MatrixCodeNumber(self.messages, @"persistenceMs", 10000, 500, 600000) / 1000.0f;
        float disappear = MatrixCodeNumber(self.messages, @"disappearMs", 4000, 0, 600000) / 1000.0f;
        self.activeMessageEnd = now + appear + hold + disappear;

        float position = MatrixCodeNumber(self.messages, @"verticalPosition", 0.475, 0, 1);
        float jitter = MatrixCodeNumber(self.messages, @"verticalJitter", 0.25, 0, 1);
        NSInteger placementAxis = dropLayout ? placementCols : placementRows;
        NSInteger anchor = lroundf(position * MAX(0, placementAxis - 1));
        NSInteger halfSpan = lroundf(jitter * MAX(0, placementAxis - 1) * 0.5f);
        NSInteger low = MAX(0, anchor - halfSpan);
        NSInteger high = MIN(placementAxis - 1, anchor + halfSpan);
        NSInteger axisIndex = low + (NSInteger)(MatrixCodeHash(self.seed ^ activation ^ 0x9e3779b9U) %
            (uint32_t)MAX(1, high - low + 1));
        if (dropLayout) {
            self.activeMessageColumn = axisIndex;
            self.activeMessageStartRow = MAX(0, (placementRows - (NSInteger)display.length) / 2);
        } else {
            self.activeMessageRow = axisIndex;
            self.activeMessageStartColumn = MAX(0, (placementCols - (NSInteger)display.length) / 2);
        }
    }
}

- (BOOL)messageDisplayHasRenderableGlyph:(NSString *)display {
    for (NSUInteger index = 0; index < display.length; index++) {
        if (self.messageGlyphs[[display substringWithRange:NSMakeRange(index, 1)]] != nil) {
            return YES;
        }
    }
    return NO;
}

- (void)refreshActiveMessageDisplayAtTime:(NSTimeInterval)now
                          framesPerSecond:(double)framesPerSecond {
    if (!self.activeMessageTemplate) return;
    NSString *resolved = [self.tokenResolver resolveText:self.activeMessageTemplate
                                                  atDate:[NSDate dateWithTimeIntervalSince1970:now]
                                         framesPerSecond:framesPerSecond];
    BOOL dropLayout = MatrixCodeMessageUsesDropLayout(self.messages);
    NSInteger placementSpan = dropLayout
        ? self.activeMessagePlacementRows : self.activeMessagePlacementColumns;
    if (![self messageDisplayHasRenderableGlyph:resolved] ||
        resolved.length > placementSpan) {
        return;
    }
    self.activeMessageDisplay = resolved;
    if (dropLayout) {
        self.activeMessageStartRow =
            MAX(0, (self.activeMessagePlacementRows - (NSInteger)resolved.length) / 2);
    } else {
        self.activeMessageStartColumn =
            MAX(0, (self.activeMessagePlacementColumns - (NSInteger)resolved.length) / 2);
    }
}

- (void)updateActiveMessageGlyphTargets {
    NSString *display = self.activeMessageDisplay ?: @"";
    [self ensureActiveMessageTargetCapacityForCount:(NSInteger)display.length];
    if (self.messageTargetGlyphCount <= 0) return;

    uint8_t *claimed = (uint8_t *)self.messageClaimedData.mutableBytes;
    NSInteger *targets = (NSInteger *)self.messageTargetGlyphData.mutableBytes;
    for (NSInteger offset = 0; offset < self.messageTargetGlyphCount; offset++) {
        NSString *character = [display substringWithRange:NSMakeRange((NSUInteger)offset, 1)];
        NSNumber *glyph = self.messageGlyphs[character];
        NSInteger target = glyph != nil ? glyph.integerValue : NSNotFound;
        if (targets[offset] != target) {
            targets[offset] = target;
            claimed[offset] = 0;
        }
    }
}

- (void)updateActiveMessageFrameStateAtTime:(NSTimeInterval)now
                            framesPerSecond:(double)framesPerSecond {
    [self refreshActiveMessageDisplayAtTime:now framesPerSecond:framesPerSecond];
    if (!self.activeMessageTemplate) {
        [self resetActiveMessageTargetState];
        return;
    }

    [self updateActiveMessageGlyphTargets];
    float appear = MatrixCodeNumber(self.messages, @"appearMs", 4000, 0, 600000) / 1000.0f;
    float disappear = MatrixCodeNumber(self.messages, @"disappearMs", 4000, 0, 600000) / 1000.0f;
    float elapsed = (float)(now - self.activeMessageStart);
    float remaining = (float)(self.activeMessageEnd - now);
    float fade = 1;
    float flicker = 0;
    if (appear > 0 && elapsed < appear) {
        fade = fmaxf(0, elapsed / appear);
        flicker = 1 - fade;
    } else if (disappear > 0 && remaining < disappear) {
        fade = fmaxf(0, remaining / disappear);
        flicker = 1 - fade;
    }
    self.activeMessageFrameIntensity = MatrixCodeBool(self.messages, @"brightnessFade", NO) ? fade : 1;
    self.activeMessageFrameScramble = MatrixCodeBool(self.messages, @"flickerOut", YES) ? flicker : 0;
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
        [self resetActiveImageState];
        float frequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0f;
        uint32_t cycle = (uint32_t)floor(now - self.epochSeconds);
        self.nextImageFire = now + frequency *
            (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ cycle ^ 0x6d2b79f5U));
    }
    if (!self.activeImage && now >= self.nextImageFire) {
        uint32_t activation = (uint32_t)floor((now - self.epochSeconds) * 10);
        NSUInteger selected = MatrixCodeHash(self.seed ^ activation ^ 0x3f4d1c23U) % configured.count;
        NSDictionary *image = configured[selected];
        NSData *mask = [[NSData alloc] initWithBase64EncodedString:image[@"data"] options:0];
        NSInteger width = [image[@"width"] integerValue];
        NSInteger height = [image[@"height"] integerValue];
        if (!mask || mask.length != (NSUInteger)(width * height)) {
            float frequency = MatrixCodeNumber(self.images, @"frequencyMs", 14000, 500, 600000) / 1000.0f;
            self.nextImageFire = now + frequency *
                (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ activation ^ 0x6d2b79f5U));
            return;
        }
        self.activeImage = image;
        self.activeImageMaskData = mask;
        self.activeImageWidth = width;
        self.activeImageHeight = height;
        self.activeImageStart = now;
        self.activeImagePlacementX = MatrixCodeUnit(self.seed ^ activation ^ 0x731f4a7dU);
        self.activeImagePlacementY = MatrixCodeUnit(self.seed ^ activation ^ 0x4c2d65bfU);
        float appear = MatrixCodeNumber(self.images, @"appearMs", 4500, 0, 600000) / 1000.0f;
        float hold = MatrixCodeNumber(self.images, @"persistenceMs", 12000, 500, 600000) / 1000.0f;
        float disappear = MatrixCodeNumber(self.images, @"disappearMs", 4500, 0, 600000) / 1000.0f;
        self.activeImageEnd = now + appear + hold + disappear;
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
    uniforms.tailColor = MatrixCodeRGB(palette[1].unsignedIntValue);
    uniforms.bodyColor = MatrixCodeRGB(palette[2].unsignedIntValue);
    uniforms.brightColor = MatrixCodeRGB(palette[3].unsignedIntValue);
    uniforms.headColor = MatrixCodeRGB(palette[4].unsignedIntValue);
    uniforms.glow = MatrixCodeNumber(self.controls, @"glow", 0.9, 0, 2.5);
    uniforms.vignette = MatrixCodeVignette(self.controls);
    uniforms.scanlines = MatrixCodeBool(self.controls, @"scanlines", NO) ? 1 : 0;
    uniforms.leadBrightness = MatrixCodeNumber(self.controls, @"leadBrightness", 1.6, 0, 3);
    NSString *quality = [self.controls[@"quality"] isKindOfClass:NSString.class]
        ? self.controls[@"quality"] : @"high";
    uniforms.glowRadius = [quality isEqualToString:@"low"] ? 1 :
        ([quality isEqualToString:@"med"] ? 2 : 3);
    self.uniforms = uniforms;
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

- (void)ensureColumnScratchCapacityForRows:(NSInteger)rows {
    NSUInteger clampedRows = (NSUInteger)MAX(1, rows);
    NSUInteger brightnessLength = clampedRows * sizeof(float);
    if (self.columnBrightnessData.length < brightnessLength) {
        self.columnBrightnessData = [NSMutableData dataWithLength:brightnessLength];
    }
    if (self.columnHeadData.length < clampedRows) {
        self.columnHeadData = [NSMutableData dataWithLength:clampedRows];
    }
    if (self.columnWhiteHeadData.length < clampedRows) {
        self.columnWhiteHeadData = [NSMutableData dataWithLength:clampedRows];
    }
}

- (void)updateInstancesForDrawableSize:(CGSize)drawableSize {
    float scale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 1;
    float glyphScale = MatrixCodeNumber(self.controls, @"glyphScale", 1, 0.5, 10);
    float cellPoints = 18.0f * glyphScale;
    float cellPixels = cellPoints * scale;
    NSInteger columns = MAX(1, (NSInteger)ceil(drawableSize.width / cellPixels) + 1);
    NSInteger rows = MAX(1, (NSInteger)ceil(drawableSize.height / cellPixels) + 1);

    float configuredDensity = MatrixCodeNumber(self.controls, @"density", 2, 0.1, 100);
    BOOL allowOverlap = MatrixCodeBool(self.controls, @"allowOverlap", YES);
    NSString *quality = [self.controls[@"quality"] isKindOfClass:NSString.class]
        ? self.controls[@"quality"] : @"high";
    NSInteger laneCap = [quality isEqualToString:@"low"] ? 2 :
        ([quality isEqualToString:@"med"] ? 4 : 8);
    NSInteger laneCount = 1;
    float laneOffsets[8] = {0};
    float laneWeights[8] = {1, 0, 0, 0, 0, 0, 0, 0};
    if (allowOverlap && configuredDensity > 20) {
        float level = fminf(3, fmaxf(0, 3 * (configuredDensity - 20) / 80));
        NSInteger full = 1 << (NSInteger)floorf(level);
        float fade = level - floorf(level);
        laneCount = MIN(laneCap, full + ((fade > 0.000001f && full < 8) ? full : 0));
        for (NSInteger lane = 0; lane < laneCount; lane++) {
            laneOffsets[lane] = MatrixCodeVanDerCorput(lane);
            laneWeights[lane] = lane < full ? 1 : fade;
        }
    }
    [self ensureInstanceCapacity:(NSUInteger)(columns * rows * laneCount)];
    [self ensureColumnScratchCapacityForRows:rows];
    if (self.instanceBuffers.count > 0) {
        self.instanceBufferIndex = (self.instanceBufferIndex + 1) % self.instanceBuffers.count;
        self.instanceBuffer = self.instanceBuffers[self.instanceBufferIndex];
    }

    float speedControl = MatrixCodeNumber(self.controls, @"speed", 1, 0.1, 3);
    float rawTrail = MatrixCodeNumber(self.controls, @"trailLength", 0.255, 0.01, 0.5);
    float trailVariation = MatrixCodeNumber(self.controls, @"trailVariation", 1, 0, 1);
    float trail = MatrixCodeEffectiveTrailLength(rawTrail, (float)rows, speedControl);
    float glyphRate = MatrixCodeNumber(self.controls, @"glyphRate", 1, 0, 5);
    NSString *glyphMode = MatrixCodeGlyphMode(self.controls);
    NSArray *sessionScreens = [self.session[@"screens"] isKindOfClass:NSArray.class]
        ? self.session[@"screens"] : @[];
    float rampDuration = sessionScreens.count > 1 ? 0 :
        MatrixCodeNumber(self.controls, @"rampUpMs", 8000, 0, 60000) / 1000.0f;
    NSTimeInterval now = self.hasCurrentFrameTime ? self.currentFrameTimeSeconds :
        (self.hasFrozenFrameTime ? self.frozenFrameTimeSeconds :
            (self.animationActive ? NSDate.date.timeIntervalSince1970 : self.epochSeconds + 2.5));
    float elapsed = (float)(now - self.epochSeconds);
    float rainElapsed = sessionScreens.count > 1 ? elapsed :
        (self.usesExternalRainTimeline ? (float)self.rainElapsed : elapsed);
    NSInteger firstGlobalColumn = 0;
    NSInteger firstGlobalRow = 0;
    float localOriginXPoints = [MatrixCodeSession
        localOriginForVirtualOffset:self.screenLeft - self.virtualLeft
                           cellSize:cellPoints
                          firstCell:&firstGlobalColumn];
    float localOriginYPoints = [MatrixCodeSession
        localOriginForVirtualOffset:self.screenTop - self.virtualTop
                           cellSize:cellPoints
                          firstCell:&firstGlobalRow];
    float localOriginXPixels = localOriginXPoints * scale;
    float localOriginYPixels = localOriginYPoints * scale;
    float virtualRows = ceilf(self.virtualHeight / cellPoints);
    float virtualColumns = ceilf(self.virtualWidth / cellPoints);
    [self updateMessageScheduleAtTime:now
                          globalCols:(NSInteger)virtualColumns
                          globalRows:(NSInteger)virtualRows
                           localCols:columns
                           localRows:rows];
    [self updateImageScheduleAtTime:now
                          globalCols:(NSInteger)virtualColumns
                          globalRows:(NSInteger)virtualRows
                           localCols:columns
                           localRows:rows];
    [self updateActiveMessageFrameStateAtTime:now
                              framesPerSecond:self.preferredFramesPerSecond];
    [self updateActiveImageFrameStateAtTime:now];
    float glyphDt = [self advanceGlyphStateClockToTime:rainElapsed];
    MatrixCodeGlyphCellState *glyphStates = [self glyphStatesForColumns:columns
                                                                   rows:rows
                                                              laneCount:laneCount];
    float sync = fmaxf(0, 1 + 0.35f * sinf(rainElapsed * 1.7f * 2.0f * (float)M_PI));
    float mutationChance = glyphRate > 0
        ? 1 - expf(-1.6f * glyphRate * sync * glyphDt)
        : 0;
    float crossfadeStep = glyphDt / 0.09f;
    MatrixCodeGlyphInstance *instances = self.instanceBuffer.contents;
    NSUInteger count = 0;
    uint8_t *messageClaimed = (uint8_t *)self.messageClaimedData.mutableBytes;
    const NSInteger *messageTargets = (const NSInteger *)self.messageTargetGlyphData.bytes;
    NSInteger messageTargetCount = self.messageTargetGlyphCount;
    BOOL messageActive =
        self.activeMessageTemplate &&
        messageTargetCount > 0 &&
        (NSUInteger)messageTargetCount <= self.messageClaimedData.length &&
        (NSUInteger)messageTargetCount * sizeof(NSInteger) <= self.messageTargetGlyphData.length;
    BOOL messageUsesLocalCoordinates = messageActive && MatrixCodeVignette(self.controls) > 0;
    BOOL messageDropLayout = messageActive && MatrixCodeMessageUsesDropLayout(self.messages);
    BOOL messageBottomToTop = messageDropLayout && MatrixCodeMessageReadsBottomToTop(self.messages);
    NSInteger messageRow = self.activeMessageRow;
    NSInteger messageStartColumn = self.activeMessageStartColumn;
    NSInteger messageColumn = self.activeMessageColumn;
    NSInteger messageStartRow = self.activeMessageStartRow;
    float messageIntensity = self.activeMessageFrameIntensity;
    float messageScramble = self.activeMessageFrameScramble;
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
    }
    float imageIntensity = self.activeImageFrameIntensity;
    float imageScramble = self.activeImageFrameScramble;
    float *columnBrightness = (float *)self.columnBrightnessData.mutableBytes;
    uint8_t *columnHead = (uint8_t *)self.columnHeadData.mutableBytes;
    uint8_t *columnWhiteHead = (uint8_t *)self.columnWhiteHeadData.mutableBytes;

    for (NSInteger lane = 0; lane < laneCount; lane++) {
        // RainSim applies its 0.5 density scale before rounding the number of
        // streams. Lane weight gates columns independently; it must not also
        // reduce stream count or density gets attenuated twice.
        float laneDensity = (laneCount > 1 ? 20 : configuredDensity) * 0.5f;
        NSInteger streamCount = MAX(1, (NSInteger)lroundf(laneDensity));
        float streamFraction = laneWeights[lane];
        uint32_t laneSeed = self.seed ^ (uint32_t)(lane * 0x9e3779b9U);
        for (NSInteger column = 0; column < columns; column++) {
            int globalColumn = (int)(firstGlobalColumn + column);
            memset(columnBrightness, 0, (size_t)rows * sizeof(float));
            memset(columnHead, 0, (size_t)rows);
            memset(columnWhiteHead, 0, (size_t)rows);
            for (NSInteger stream = 0; stream < streamCount; stream++) {
                uint32_t key = laneSeed ^ (uint32_t)(globalColumn * 0x9e3779b9U) ^
                    (uint32_t)(stream * 0x85ebca6bU);
                MatrixCodeRainStreamSample streamSample = MatrixCodeRainSampleStream(
                    key, rainElapsed, self.densityScale, rampDuration, virtualRows,
                    speedControl, fmaxf(laneDensity, 0.1f), streamFraction);
                if (!streamSample.active) continue;
                float trailSpeed = MatrixCodeRainEffectiveTrailSpeed(
                    streamSample.speed, speedControl, trailVariation);
                float tailRows = trailSpeed * 1.2f * logf(0.004f) / logf(trail);
                NSInteger rowMin = MAX(0, (NSInteger)ceilf(streamSample.headRow - tailRows - firstGlobalRow));
                NSInteger rowMax = MIN(rows - 1, (NSInteger)floorf(streamSample.headRow - firstGlobalRow));
                if (rowMax < rowMin) continue;
                float denominator = fmaxf(trailSpeed * 1.2f, 0.1f);
                float distance = streamSample.headRow - (float)(firstGlobalRow + rowMin);
                float value = powf(trail, distance / denominator);
                float step = powf(trail, -1.0f / denominator);
                for (NSInteger row = rowMin; row <= rowMax; row++) {
                    if (distance < 1.05f) {
                        columnBrightness[row] = 1;
                        columnHead[row] = 1;
                        columnWhiteHead[row] = columnWhiteHead[row] || streamSample.whiteHead;
                    } else if (value >= 0.004f) {
                        columnBrightness[row] = fmaxf(columnBrightness[row], value);
                    }
                    distance -= 1;
                    value *= step;
                }
            }
            for (NSInteger row = 0; row < rows; row++) {
                int globalRow = (int)(firstGlobalRow + row);
                float brightness = columnBrightness[row];
                BOOL head = columnHead[row] != 0;
                BOOL whiteHead = columnWhiteHead[row] != 0;
                NSUInteger stateIndex = ((NSUInteger)lane * (NSUInteger)rows + (NSUInteger)row) *
                    (NSUInteger)columns + (NSUInteger)column;
                MatrixCodeGlyphCellState *glyphState = &glyphStates[stateIndex];
                uint32_t identity = MatrixCodeCellIdentity(laneSeed, globalColumn, globalRow);
                if (!glyphState->initialized || glyphState->identity != identity) {
                    NSInteger initialGlyph = MatrixCodeRainGlyphIndex(identity ^ 0x68e31da4U, glyphMode);
                    glyphState->identity = identity;
                    glyphState->randomCounter = MatrixCodeHash(identity ^ self.seed ^ 0x3c6ef372U);
                    glyphState->glyphNew = (uint8_t)initialGlyph;
                    glyphState->glyphOld = (uint8_t)initialGlyph;
                    glyphState->wasHead = 0;
                    glyphState->initialized = 1;
                    glyphState->phase = 1;
                }
                if (glyphState->phase < 1) {
                    glyphState->phase = fminf(1, glyphState->phase + crossfadeStep);
                }
                float imageInfluence = 0;
                float imageLuminance = 0;
                float imageFallGate = 0;
                NSInteger imageGlyph = NSNotFound;
                if (imageActive && lane == 0 && imageColumns > 0 && imageRows > 0) {
                    float u = ((float)globalColumn + 0.5f - imageOriginColumn) / imageColumns;
                    float v = ((float)globalRow + 0.5f - imageOriginRow) / imageRows;
                    if (u >= 0 && u <= 1 && v >= 0 && v <= 1) {
                        imageLuminance = MatrixCodeImageSampleMask(self.activeImageMaskData,
                                                                   self.activeImageWidth,
                                                                   self.activeImageHeight,
                                                                   u,
                                                                   v);
                        float contrastSignal = fabsf(imageLuminance - 0.5f) * 2.0f;
                        float brightSignal = imageLuminance * 0.72f;
                        float signal = fmaxf(contrastSignal, brightSignal);
                        float trailGate = fminf(1, fmaxf(0, (brightness - 0.028f) / 0.42f));
                        imageFallGate = MatrixCodeImageFallingGate(globalColumn,
                                                                   globalRow,
                                                                   rainElapsed,
                                                                   self.seed);
                        float revealGate = fmaxf(trailGate, imageFallGate * 0.48f);
                        float dissolve = 1;
                        if (imageScramble > 0) {
                            uint32_t bucket = (uint32_t)floorf((float)(now - self.epochSeconds) * 18.0f);
                            float roll = MatrixCodeUnit(identity ^ bucket * 0x9e3779b9U ^ 0xb4b82e39U);
                            dissolve = roll >= imageScramble ? 1 : 0;
                        }
                        imageInfluence = fminf(1, signal * revealGate * imageIntensity * dissolve);
                        if (imageInfluence > 0.001f) {
                            uint32_t imageKey = identity ^ (uint32_t)floorf(imageLuminance * 255.0f) * 0x85ebca6bU;
                            imageGlyph = MatrixCodeImageGlyphForLuminance(imageLuminance,
                                                                           imageKey,
                                                                           glyphMode);
                            float bright = fmaxf(0, (imageLuminance - 0.38f) / 0.62f);
                            float dark = fmaxf(0, (0.58f - imageLuminance) / 0.58f);
                            brightness *= (1.0f - 0.46f * dark * imageInfluence);
                            brightness = fmaxf(brightness,
                                               bright * imageInfluence *
                                               (0.12f + 0.48f * imageFallGate));
                            brightness = fminf(1.45f,
                                               brightness + bright * imageInfluence *
                                               fmaxf(columnBrightness[row], 0.08f) * 0.58f);
                        }
                    }
                }
                NSInteger messageGlyph = NSNotFound;
                NSInteger messageOffset = NSNotFound;
                if (messageActive && lane == 0) {
                    NSInteger messageCellRow = messageUsesLocalCoordinates ? row : globalRow;
                    NSInteger messageCellColumn = messageUsesLocalCoordinates ? column : globalColumn;
                    NSInteger offset = NSNotFound;
                    if (messageDropLayout) {
                        if (messageCellColumn == messageColumn) {
                            offset = messageCellRow - messageStartRow;
                            if (messageBottomToTop && offset >= 0 && offset < messageTargetCount) {
                                offset = messageTargetCount - 1 - offset;
                            }
                        }
                    } else if (messageCellRow == messageRow) {
                        offset = messageCellColumn - messageStartColumn;
                    }
                    if (offset >= 0 && offset < messageTargetCount) {
                        NSInteger target = messageTargets[offset];
                        if (target != NSNotFound) {
                            messageGlyph = target;
                            messageOffset = offset;
                        }
                    }
                }
                BOOL headArrival = head && !glyphState->wasHead;
                if (headArrival) {
                    NSInteger randomGlyph = MatrixCodeRainGlyphIndex(
                        MatrixCodeNextGlyphEventKey(glyphState), glyphMode);
                    glyphState->glyphOld = glyphState->glyphNew;
                    if (messageGlyph != NSNotFound) {
                        if (messageOffset != NSNotFound &&
                            messageOffset >= 0 &&
                            messageOffset < messageTargetCount) {
                            messageClaimed[messageOffset] = 1;
                        }
                        if (messageScramble > 0 &&
                            MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) < messageScramble) {
                            glyphState->glyphNew = (uint8_t)randomGlyph;
                        } else {
                            glyphState->glyphNew = (uint8_t)messageGlyph;
                        }
                    } else if (imageGlyph != NSNotFound &&
                               MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) <
                                   fminf(0.96f, 0.18f + imageInfluence * 0.78f)) {
                        if (imageScramble > 0 &&
                            MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) < imageScramble * 0.75f) {
                            glyphState->glyphNew = (uint8_t)randomGlyph;
                        } else {
                            glyphState->glyphNew = (uint8_t)imageGlyph;
                        }
                    } else {
                        glyphState->glyphNew = (uint8_t)randomGlyph;
                    }
                    glyphState->phase = 1;
                } else if (!head && brightness > 0.05f &&
                           (mutationChance > 0 || imageGlyph != NSNotFound)) {
                    float roll = MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState));
                    float imageMutationChance = imageGlyph != NSNotFound
                        ? fminf(0.72f, 0.08f + imageInfluence * 0.46f)
                        : 0;
                    if (roll < fmaxf(mutationChance, imageMutationChance)) {
                        NSInteger randomGlyph = MatrixCodeRainGlyphIndex(
                            MatrixCodeNextGlyphEventKey(glyphState), glyphMode);
                        if (messageGlyph != NSNotFound) {
                            if (messageOffset != NSNotFound &&
                                messageOffset >= 0 &&
                                messageOffset < messageTargetCount) {
                                messageClaimed[messageOffset] = 1;
                            }
                            NSInteger nextGlyph = randomGlyph;
                            if (messageScramble <= 0 ||
                                MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) >= messageScramble) {
                                nextGlyph = messageGlyph;
                            }
                            if (nextGlyph != glyphState->glyphNew) {
                                glyphState->glyphOld = glyphState->glyphNew;
                                glyphState->glyphNew = (uint8_t)nextGlyph;
                                glyphState->phase = 0;
                            }
                        } else if (imageGlyph != NSNotFound) {
                            NSInteger nextGlyph = randomGlyph;
                            if (imageScramble <= 0 ||
                                MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) >= imageScramble * 0.75f) {
                                nextGlyph = imageGlyph;
                            }
                            if (nextGlyph != glyphState->glyphNew) {
                                glyphState->glyphOld = glyphState->glyphNew;
                                glyphState->glyphNew = (uint8_t)nextGlyph;
                                glyphState->phase = 0;
                            }
                        } else {
                            glyphState->glyphOld = glyphState->glyphNew;
                            glyphState->glyphNew = (uint8_t)randomGlyph;
                            glyphState->phase = 0;
                        }
                    }
                }
                glyphState->wasHead = head ? 1 : 0;
                NSInteger glyph = glyphState->glyphNew;
                NSInteger oldGlyph = glyphState->glyphOld;
                float crossfade = glyphState->phase;
                if (messageGlyph != NSNotFound) {
                    if (messageOffset != NSNotFound &&
                        messageOffset >= 0 &&
                        messageOffset < messageTargetCount &&
                        messageClaimed[messageOffset]) {
                        brightness = fmaxf(brightness, 0.45f) * messageIntensity;
                    }
                }
                if (brightness < 0.004f) continue;
                NSInteger atlasColumn = glyph % self.atlasColumns;
                NSInteger atlasRow = glyph / self.atlasColumns;
                NSInteger oldAtlasColumn = oldGlyph % self.atlasColumns;
                NSInteger oldAtlasRow = oldGlyph / self.atlasColumns;
                float digitValue = MatrixCodeProceduralDigitValueForRainGlyph(
                    glyph, self.rainGlyphCount, self.controls);
                instances[count++] = (MatrixCodeGlyphInstance){
                    .origin = {
                        localOriginXPixels + (column + laneOffsets[lane]) * cellPixels,
                        localOriginYPixels + row * cellPixels,
                    },
                    .size = {cellPixels, cellPixels},
                    .atlasOrigin = {
                        (float)atlasColumn / self.atlasColumns,
                        (float)(self.atlasRows - atlasRow) / self.atlasRows,
                    },
                    // Core Graphics rasterizes from a lower-left origin while
                    // the screen quad grows downward, so atlas V runs negative.
                    .atlasSize = {1.0f / self.atlasColumns, -1.0f / self.atlasRows},
                    .oldAtlasOrigin = {
                        (float)oldAtlasColumn / self.atlasColumns,
                        (float)(self.atlasRows - oldAtlasRow) / self.atlasRows,
                    },
                    .crossfade = crossfade,
                    .brightness = brightness,
                    .isHead = head ? 1 : 0,
                    .whiteHead = whiteHead ? 1 : 0,
                    .digitValue = digitValue,
                };
            }
        }
    }
    self.instanceCount = count;
    MatrixCodeUniforms uniforms = self.uniforms;
    uniforms.viewport = (vector_float2){drawableSize.width, drawableSize.height};
    self.uniforms = uniforms;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.commandQueue || !self.pipeline || !view.currentDrawable) return;
    NSDate *frameDate = self.animationActive ? NSDate.date : nil;
    self.hasCurrentFrameTime = frameDate != nil;
    if (frameDate) {
        self.currentFrameTimeSeconds = frameDate.timeIntervalSince1970;
        if (self.frameHandler) {
            self.frameHandler(self, frameDate, self.preferredFramesPerSecond);
        }
    }
    [self updateInstancesForDrawableSize:view.drawableSize];
    self.hasCurrentFrameTime = NO;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass) return;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
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
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

#if DEBUG
- (NSData *)diagnosticBGRAFrameWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!self.commandQueue || !self.pipeline || width == 0 || height == 0) return nil;
    [self updateInstancesForDrawableSize:CGSizeMake(width, height)];
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:self.colorPixelFormat
                                                           width:width height:height mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    textureDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [self.device newTextureWithDescriptor:textureDescriptor];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = self.clearColor;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
    [encoder setFragmentBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
    [encoder setFragmentTexture:self.atlas atIndex:0];
    if (self.instanceCount > 0) {
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                 instanceCount:self.instanceCount];
    }
    [encoder endEncoding];
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
    NSUInteger cellCount = self.glyphStateData.length / sizeof(MatrixCodeGlyphCellState);
    MatrixCodeGlyphCellState *states = (MatrixCodeGlyphCellState *)self.glyphStateData.bytes;
    NSMutableArray<NSNumber *> *snapshot = [NSMutableArray arrayWithCapacity:cellCount];
    for (NSUInteger index = 0; index < cellCount; index++) {
        [snapshot addObject:@(states[index].glyphNew)];
    }
    return snapshot;
}
#endif

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

@end
