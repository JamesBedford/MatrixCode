#import "MatrixCodeConstants.h"

#import <math.h>

NSString * const MatrixCodeModuleIdentifier = @"com.matrixcode.screensaver";
NSString * const MatrixCodeSessionDefaultsKey = @"MatrixCodeNativeSession";

static NSDictionary<NSString *, NSArray<NSNumber *> *> *MatrixCodeColorPalettes(void) {
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *palettes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palettes = @{
            @"classic": @[@0x0D0208, @0x003B00, @0x008F11, @0x00FF41, @0xDEFFE4],
            @"amber": @[@0x0A0600, @0x3B1E00, @0xA85B00, @0xFFB000, @0xFFF1C8],
            @"orange": @[@0x0D0400, @0x3B1200, @0xA84400, @0xFF6A00, @0xFFE8D6],
            @"blue": @[@0x02060D, @0x00263B, @0x0066A8, @0x27D6FF, @0xE4FAFF],
            @"gold": @[@0x0C0800, @0x4A3000, @0xB8860B, @0xFFD700, @0xFFF4C2],
            @"red": @[@0x0D0202, @0x3B0000, @0xA80008, @0xFF2A2A, @0xFFE0E0],
            @"pink": @[@0x0D0207, @0x3B0022, @0xA80060, @0xFF3DA0, @0xFFE2F1],
            @"purple": @[@0x08020D, @0x2A003B, @0x6E00A8, @0xB23BFF, @0xF2E2FF],
            @"white": @[@0x060606, @0x2A2A2A, @0x8C8C8C, @0xEDEDED, @0xFFFFFF],
        };
    });
    return palettes;
}

NSArray<NSString *> *MatrixCodeColorPresetNames(void) {
    return @[@"classic", @"amber", @"orange", @"gold", @"red", @"pink", @"purple",
             @"blue", @"white", @"custom"];
}

static NSString *MatrixCodeNormalizedCustomColor(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 7 ||
        ![(NSString *)value hasPrefix:@"#"]) {
        return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:[(NSString *)value substringFromIndex:1]];
    unsigned int hex = 0;
    if (![scanner scanHexInt:&hex] || !scanner.isAtEnd) return nil;
    return [NSString stringWithFormat:@"#%06X", hex];
}

static NSUInteger MatrixCodeScaledColor(NSUInteger color, double factor) {
    NSUInteger red = (NSUInteger)lround(((color >> 16) & 0xff) * factor);
    NSUInteger green = (NSUInteger)lround(((color >> 8) & 0xff) * factor);
    NSUInteger blue = (NSUInteger)lround((color & 0xff) * factor);
    return (red << 16) | (green << 8) | blue;
}

static NSUInteger MatrixCodeLightenedColor(NSUInteger color, double amount) {
    NSUInteger red = (NSUInteger)lround(((color >> 16) & 0xff) * (1 - amount) + 255 * amount);
    NSUInteger green = (NSUInteger)lround(((color >> 8) & 0xff) * (1 - amount) + 255 * amount);
    NSUInteger blue = (NSUInteger)lround((color & 0xff) * (1 - amount) + 255 * amount);
    return (red << 16) | (green << 8) | blue;
}

NSArray<NSNumber *> *MatrixCodeColorPaletteForControls(NSDictionary<NSString *, id> *controls) {
    NSString *preset = [controls[@"preset"] isKindOfClass:NSString.class]
        ? controls[@"preset"] : @"classic";
    NSDictionary<NSString *, NSArray<NSNumber *> *> *palettes = MatrixCodeColorPalettes();
    if (![preset isEqualToString:@"custom"]) return palettes[preset] ?: palettes[@"classic"];

    NSString *customColor = MatrixCodeNormalizedCustomColor(controls[@"customColor"])
        ?: @"#00FF41";
    unsigned int bright = 0;
    [[NSScanner scannerWithString:[customColor substringFromIndex:1]] scanHexInt:&bright];
    return @[
        @(MatrixCodeScaledColor(bright, 0.05)),
        @(MatrixCodeScaledColor(bright, 0.23)),
        @(MatrixCodeScaledColor(bright, 0.66)),
        @(bright),
        @(MatrixCodeLightenedColor(bright, 0.88)),
    ];
}

NSArray<NSNumber *> *MatrixCodeColorPaletteForPreset(NSString *presetName) {
    return MatrixCodeColorPaletteForControls(@{ @"preset": presetName ?: @"classic" });
}

NSArray<NSString *> *MatrixCodeStorageKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"mx-controls",
            @"mx-intro",
            @"mx-messages",
            @"mx-images",
            @"mx-ui-state",
            @"mx-countdown",
            @"mx-user-name",
        ];
    });
    return keys;
}

static BOOL MatrixCodeControlsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static double MatrixCodeControlsNumber(NSDictionary *controls,
                                       NSString *key,
                                       double fallback,
                                       double minimum,
                                       double maximum) {
    id value = controls[key];
    if (![value isKindOfClass:NSNumber.class] || MatrixCodeControlsBoolean(value) ||
        !isfinite([value doubleValue])) {
        return fallback;
    }
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

NSDictionary<NSString *, id> *MatrixCodeSanitizeControlsDocument(id rawControls) {
    NSDictionary *stored = [rawControls isKindOfClass:NSDictionary.class] ? rawControls : @{};
    NSMutableDictionary<NSString *, id> *controls = [@{
        @"speed": @1,
        @"trailLength": @0.255,
        @"trailVariation": @1,
        @"density": @2,
        @"rampUpMs": @8000,
        @"glyphRate": @1,
        @"glyphScale": @1,
        @"glyphMode": @"matrix",
        @"glyphFont": @"matrix",
        @"glow": @0.9,
        @"leadBrightness": @1.6,
        @"preset": @"classic",
        @"customColor": @"#00FF41",
        @"mirror": @YES,
        @"scanlines": @NO,
        @"vignette": @0,
        @"allowOverlap": @YES,
        @"quality": @"high",
    } mutableCopy];
    NSArray<NSArray *> *numericControls = @[
        @[@"speed", @0.1, @3],
        @[@"trailLength", @0.01, @0.5],
        @[@"trailVariation", @0, @1],
        @[@"density", @0.1, @100],
        @[@"rampUpMs", @0, @60000],
        @[@"glyphRate", @0, @5],
        @[@"glyphScale", @0.5, @10],
        @[@"glow", @0, @2.5],
        @[@"leadBrightness", @0, @3],
    ];
    for (NSArray *specification in numericControls) {
        NSString *key = specification[0];
        controls[key] = @(MatrixCodeControlsNumber(stored,
                                                   key,
                                                   [controls[key] doubleValue],
                                                   [specification[1] doubleValue],
                                                   [specification[2] doubleValue]));
    }

    id storedVignette = stored[@"vignette"];
    if (MatrixCodeControlsBoolean(storedVignette)) {
        controls[@"vignette"] = [storedVignette boolValue] ? @0.42 : @0;
    } else {
        controls[@"vignette"] = @(MatrixCodeControlsNumber(stored,
                                                           @"vignette",
                                                           0,
                                                           0,
                                                           1));
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *choices = @{
        @"glyphMode": @[@"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols"],
        @"glyphFont": @[@"matrix", @"gothic", @"mono", @"terminal", @"rounded", @"mincho"],
        @"preset": MatrixCodeColorPresetNames(),
        @"quality": @[@"low", @"med", @"high"],
    };
    [choices enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                                  NSArray<NSString *> *allowed,
                                                  BOOL *stop) {
        (void)stop;
        id value = stored[key];
        if ([value isKindOfClass:NSString.class] && [allowed containsObject:value]) {
            controls[key] = value;
        }
    }];

    NSString *customColor = MatrixCodeNormalizedCustomColor(stored[@"customColor"]);
    if (customColor) controls[@"customColor"] = customColor;

    for (NSString *key in @[@"mirror", @"scanlines", @"allowOverlap"]) {
        id value = stored[key];
        if (MatrixCodeControlsBoolean(value)) controls[key] = value;
    }
    return [controls copy];
}

double MatrixCodeQuantizedControlValue(NSString *key, double value) {
    if (!isfinite(value)) return value;
    static NSDictionary<NSString *, NSNumber *> *steps;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        steps = @{
            @"density": @0.05,
            @"rampUpMs": @500,
            @"trailLength": @0.01,
            @"trailVariation": @0.01,
            @"speed": @0.05,
            @"glyphScale": @0.1,
            @"glow": @0.05,
            @"leadBrightness": @0.05,
            @"vignette": @0.01,
            @"glyphRate": @0.05,
        };
    });
    double step = steps[key].doubleValue;
    return step > 0 ? round(value / step) * step : value;
}

double MatrixCodeNudgedDensity(double density, double factor) {
    if (!isfinite(density)) density = 2.0;
    if (!isfinite(factor) || factor <= 0) return fmin(100.0, fmax(0.1, density));
    double nextDensity = fmin(100.0, fmax(0.1, density * factor));
    return nextDensity > 5.0 ? round(nextDensity) : nextDensity;
}
