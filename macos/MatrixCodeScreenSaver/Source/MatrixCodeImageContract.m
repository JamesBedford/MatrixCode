#import "MatrixCodeImageContract.h"

#import <math.h>
#import <stdlib.h>

#import "MatrixCodeRainLifecycle.h"

NSUInteger const MatrixCodeImageMaskMaximumDimension = 96;
NSUInteger const MatrixCodeImageMaximumCount = 64;
NSUInteger const MatrixCodeImageNameMaximumLength = 80;
NSUInteger const MatrixCodeImageMaskMaximumStoredCharacters = 49152;
NSString * const MatrixCodeImagesPortableBackupDefaultsKey = @"mx-images-portable-backup-v0";

static BOOL MatrixCodeImageBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static double MatrixCodeImageNumber(NSDictionary *dictionary,
                                    NSString *key,
                                    double fallback,
                                    double minimum,
                                    double maximum) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class] || MatrixCodeImageBoolean(value) ||
        !isfinite([value doubleValue])) {
        return fallback;
    }
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

static BOOL MatrixCodeImageBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = dictionary[key];
    return MatrixCodeImageBoolean(value) ? [value boolValue] : fallback;
}

static NSString *MatrixCodeImageText(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    return [text substringToIndex:MIN(maximumLength, text.length)];
}

static NSData *MatrixCodeDecodeStrictBase64(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length % 4 != 0) {
        return nil;
    }
    NSUInteger padding = [value hasSuffix:@"=="] ? 2 : ([value hasSuffix:@"="] ? 1 : 0);
    NSUInteger payloadLength = value.length - padding;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        BOOL payloadCharacter =
            (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') ||
            character == '+' || character == '/';
        if (index < payloadLength ? !payloadCharacter : character != '=') return nil;
    }
    return [[NSData alloc] initWithBase64EncodedString:value options:0];
}

NSDictionary<NSString *, id> *MatrixCodeDefaultImagesDocument(void) {
    return @{
        @"images": @[],
        @"enabled": @NO,
        @"frequencyMs": @14000,
        @"persistenceMs": @12000,
        @"appearMs": @4500,
        @"disappearMs": @4500,
        @"flickerOut": @YES,
        @"brightnessFade": @NO,
        @"imageScale": @0.72,
        @"imagePlacementJitter": @0.35,
    };
}

NSDictionary<NSString *, id> *MatrixCodeSanitizeImageItem(id rawItem) {
    if (![rawItem isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *item = rawItem;
    NSInteger width = (NSInteger)MatrixCodeImageNumber(
        item, @"width", 0, 1, MatrixCodeImageMaskMaximumDimension);
    NSInteger height = (NSInteger)MatrixCodeImageNumber(
        item, @"height", 0, 1, MatrixCodeImageMaskMaximumDimension);
    NSString *data = MatrixCodeImageText(
        item[@"data"], MatrixCodeImageMaskMaximumStoredCharacters);
    NSData *mask = MatrixCodeDecodeStrictBase64(data);
    if (width <= 0 || height <= 0 || !mask ||
        mask.length != (NSUInteger)(width * height)) {
        return nil;
    }

    NSString *name = MatrixCodeImageText(item[@"name"], MatrixCodeImageNameMaximumLength);
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = @"Image";
    return @{
        @"name": name,
        @"width": @(width),
        @"height": @(height),
        @"data": data,
    };
}

NSDictionary<NSString *, id> *MatrixCodeSanitizeImagesDocument(id rawDocument) {
    NSDictionary *stored = [rawDocument isKindOfClass:NSDictionary.class] ? rawDocument : @{};
    NSMutableArray<NSDictionary<NSString *, id> *> *images = [NSMutableArray array];
    NSArray *configured = [stored[@"images"] isKindOfClass:NSArray.class]
        ? stored[@"images"] : @[];
    for (id candidate in configured) {
        NSDictionary *image = MatrixCodeSanitizeImageItem(candidate);
        if (!image) continue;
        [images addObject:image];
        if (images.count == MatrixCodeImageMaximumCount) break;
    }

    return @{
        @"images": [images copy],
        @"enabled": @(MatrixCodeImageBool(stored, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeImageNumber(stored, @"frequencyMs", 14000, 500, 600000)),
        @"persistenceMs": @(MatrixCodeImageNumber(stored, @"persistenceMs", 12000, 500, 600000)),
        @"appearMs": @(MatrixCodeImageNumber(stored, @"appearMs", 4500, 0, 600000)),
        @"disappearMs": @(MatrixCodeImageNumber(stored, @"disappearMs", 4500, 0, 600000)),
        @"flickerOut": @(MatrixCodeImageBool(stored, @"flickerOut", YES)),
        @"brightnessFade": @(MatrixCodeImageBool(stored, @"brightnessFade", NO)),
        @"imageScale": @(MatrixCodeImageNumber(stored, @"imageScale", 0.72, 0.05, 1)),
        @"imagePlacementJitter": @(
            MatrixCodeImageNumber(stored, @"imagePlacementJitter", 0.35, 0, 1)),
    };
}

static id MatrixCodeImageJSONObject(NSString *rawJSON) {
    if (![rawJSON isKindOfClass:NSString.class]) return nil;
    NSData *data = [rawJSON dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

NSDictionary<NSString *, id> *MatrixCodeSanitizeImagesJSONString(NSString *rawJSON) {
    return MatrixCodeSanitizeImagesDocument(MatrixCodeImageJSONObject(rawJSON));
}

static BOOL MatrixCodeLegacyImageItemWasValid(id rawItem) {
    if (![rawItem isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *item = rawItem;
    NSInteger width = (NSInteger)MatrixCodeImageNumber(item, @"width", 0, 1, 128);
    NSInteger height = (NSInteger)MatrixCodeImageNumber(item, @"height", 0, 1, 128);
    id rawData = item[@"data"];
    if (![rawData isKindOfClass:NSString.class] ||
        [(NSString *)rawData length] > MatrixCodeImageMaskMaximumStoredCharacters) {
        return NO;
    }
    // Match the pre-portable renderer: Foundation performed the Base64 decode directly and
    // dimensions were clamped to the former 128-cell ceiling.
    NSData *mask = [[NSData alloc] initWithBase64EncodedString:rawData options:0];
    return width > 0 && height > 0 && mask &&
        mask.length == (NSUInteger)(width * height);
}

static BOOL MatrixCodePortableImageCanonicalizationChangesRawItem(
    NSDictionary *rawItem,
    NSDictionary<NSString *, id> *portableItem
) {
    id rawName = rawItem[@"name"];
    if ([rawName isKindOfClass:NSString.class] &&
        ![rawName isEqual:portableItem[@"name"]]) {
        return YES;
    }
    id rawWidth = rawItem[@"width"];
    if ([rawWidth isKindOfClass:NSNumber.class] &&
        ![rawWidth isEqual:portableItem[@"width"]]) {
        return YES;
    }
    id rawHeight = rawItem[@"height"];
    if ([rawHeight isKindOfClass:NSNumber.class] &&
        ![rawHeight isEqual:portableItem[@"height"]]) {
        return YES;
    }
    id rawData = rawItem[@"data"];
    return [rawData isKindOfClass:NSString.class] &&
        ![rawData isEqual:portableItem[@"data"]];
}

BOOL MatrixCodeImagesJSONStringRequiresPortableBackup(NSString *rawJSON) {
    id parsed = MatrixCodeImageJSONObject(rawJSON);
    if (![parsed isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *document = parsed;
    NSArray *configured = [document[@"images"] isKindOfClass:NSArray.class]
        ? document[@"images"] : @[];
    NSUInteger validPortableCount = 0;
    for (id candidate in configured) {
        NSDictionary *portable = MatrixCodeSanitizeImageItem(candidate);
        if (portable) {
            if (MatrixCodePortableImageCanonicalizationChangesRawItem(
                    (NSDictionary *)candidate, portable)) {
                return YES;
            }
            validPortableCount++;
            if (validPortableCount > MatrixCodeImageMaximumCount) return YES;
        } else if (MatrixCodeLegacyImageItemWasValid(candidate)) {
            return YES;
        }
    }
    return NO;
}

MatrixCodeImageMaskDimensions MatrixCodeImageMaskDimensionsForSource(NSUInteger sourceWidth,
                                                                      NSUInteger sourceHeight) {
    if (!sourceWidth || !sourceHeight) return (MatrixCodeImageMaskDimensions){0, 0};
    double scale = fmin((double)MatrixCodeImageMaskMaximumDimension / sourceWidth,
                        (double)MatrixCodeImageMaskMaximumDimension / sourceHeight);
    scale = fmin(1, fmax(scale, 1.0 / MAX(sourceWidth, sourceHeight)));
    NSInteger width = MAX(1, (NSInteger)lround(sourceWidth * scale));
    NSInteger height = MAX(1, (NSInteger)lround(sourceHeight * scale));
    return (MatrixCodeImageMaskDimensions){
        MIN((NSInteger)MatrixCodeImageMaskMaximumDimension, width),
        MIN((NSInteger)MatrixCodeImageMaskMaximumDimension, height),
    };
}

NSData *MatrixCodeImageMaskFromPremultipliedRGBA(NSData *rgba,
                                                 NSInteger width,
                                                 NSInteger height) {
    if (width <= 0 || height <= 0 ||
        width > (NSInteger)MatrixCodeImageMaskMaximumDimension ||
        height > (NSInteger)MatrixCodeImageMaskMaximumDimension) {
        return nil;
    }
    NSUInteger count = (NSUInteger)width * (NSUInteger)height;
    if (rgba.length != count * 4) return nil;

    float *luminance = calloc(count, sizeof(float));
    if (!luminance) return nil;
    const uint8_t *pixels = rgba.bytes;
    float minimum = 1;
    float maximum = 0;
    for (NSUInteger index = 0; index < count; index++) {
        float alpha = pixels[index * 4 + 3] / 255.0f;
        // The RGB bytes came from a premultiplied bitmap. Multiplying by alpha again is intentional:
        // changing it would alter the established appearance of translucent imported artwork.
        float red = pixels[index * 4 + 0] / 255.0f;
        float green = pixels[index * 4 + 1] / 255.0f;
        float blue = pixels[index * 4 + 2] / 255.0f;
        float value = (0.2126f * red + 0.7152f * green + 0.0722f * blue) * alpha;
        luminance[index] = value;
        minimum = fminf(minimum, value);
        maximum = fmaxf(maximum, value);
    }

    NSMutableData *mask = [NSMutableData dataWithLength:count];
    uint8_t *bytes = mask.mutableBytes;
    float range = maximum - minimum;
    for (NSUInteger index = 0; index < count; index++) {
        float value = range > 0.035f ? (luminance[index] - minimum) / range : luminance[index];
        value = powf(fminf(1, fmaxf(0, value)), 0.82f);
        bytes[index] = (uint8_t)lroundf(value * 255.0f);
    }
    free(luminance);
    return [mask copy];
}

uint32_t MatrixCodeImageHash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    return value ^ (value >> 16);
}

float MatrixCodeImageUnit(uint32_t value) {
    return (float)(MatrixCodeImageHash(value) & 0x00ffffffU) / 16777216.0f;
}

uint32_t MatrixCodeImageAnimationBucket(NSTimeInterval nowSeconds,
                                        NSTimeInterval epochSeconds) {
    return (uint32_t)floor((nowSeconds - epochSeconds) * 18.0);
}

uint32_t MatrixCodeImageCellIdentity(uint32_t laneSeed,
                                     NSInteger globalColumn,
                                     NSInteger globalRow) {
    uint32_t column = (uint32_t)(int32_t)globalColumn;
    uint32_t row = (uint32_t)(int32_t)globalRow;
    return MatrixCodeImageHash(laneSeed ^ column * 73856093U ^ row * 19349663U);
}

float MatrixCodeImageSampleMask(NSData *mask,
                                NSInteger width,
                                NSInteger height,
                                float u,
                                float v) {
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

static float MatrixCodeImageSmoothstep(float edge0, float edge1, float value) {
    if (edge0 == edge1) return value < edge0 ? 0 : 1;
    float t = fminf(1, fmaxf(0, (value - edge0) / (edge1 - edge0)));
    return t * t * (3.0f - 2.0f * t);
}

float MatrixCodeImageSignalForLuminance(float luminance) {
    float value = fminf(1, fmaxf(0, luminance));
    float nonEmpty = MatrixCodeImageSmoothstep(0.035f, 0.12f, value);
    float contrastSignal = fabsf(value - 0.5f) * 2.0f * nonEmpty;
    float brightSignal = value * 0.72f;
    return fmaxf(contrastSignal, brightSignal) * nonEmpty;
}

float MatrixCodeImageEdgeFeather(float u,
                                 float v,
                                 float featherU,
                                 float featherV) {
    float horizontal = fminf(MatrixCodeImageSmoothstep(0, featherU, u),
                             MatrixCodeImageSmoothstep(0, featherU, 1.0f - u));
    float vertical = fminf(MatrixCodeImageSmoothstep(0, featherV, v),
                           MatrixCodeImageSmoothstep(0, featherV, 1.0f - v));
    return horizontal * vertical;
}

float MatrixCodeImageFallingGate(NSInteger globalColumn,
                                 NSInteger globalRow,
                                 float rainElapsed,
                                 uint32_t seed) {
    uint32_t columnKey = seed ^ (uint32_t)(int32_t)globalColumn * 0x9e3779b9U ^ 0x748f4a15U;
    float speed = 4.5f + MatrixCodeImageUnit(columnKey ^ 0x85ebca6bU) * 8.0f;
    float span = 9.0f + MatrixCodeImageUnit(columnKey ^ 0x27d4eb2dU) * 12.0f;
    float offset = MatrixCodeImageUnit(columnKey ^ 0xd3a2646cU) * span;
    float phase = fmodf((float)globalRow - rainElapsed * speed + offset, span);
    if (phase < 0) phase += span;
    float head = expf(-phase * 0.55f);
    float afterglow = phase < span * 0.42f
        ? powf(1.0f - phase / (span * 0.42f), 2.0f) : 0;
    return fminf(1, fmaxf(head, afterglow * 0.65f));
}

NSInteger MatrixCodeImageGlyphForLuminance(float luminance,
                                           uint32_t key,
                                           NSString *glyphMode) {
    float value = fminf(1, fmaxf(0, luminance));
    NSInteger level = MIN(6, MAX(0, (NSInteger)floorf(value * 7.0f)));
    if ([glyphMode isEqualToString:@"binary"]) {
        // Preserve the established bright->0, dark->1 mapping.
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
        return (NSInteger)(MatrixCodeImageUnit(key ^ (uint32_t)level * 0x45d9f3bU) *
            MatrixCodeRainDigitStartIndex());
    }
    if (value < 0.16f) return MatrixCodeRainSymbolsStartIndex() + 1;
    if (value < 0.32f) return MatrixCodeRainDigitStartIndex() + 1;
    if (value < 0.48f) return MatrixCodeRainLatinStartIndex() + 8;
    if (value < 0.64f) return MatrixCodeRainLatinStartIndex() + 12;
    return (NSInteger)(MatrixCodeImageUnit(key ^ (uint32_t)level * 0x45d9f3bU) *
        MatrixCodeRainDigitStartIndex());
}
