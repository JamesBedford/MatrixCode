#import "MatrixCodeMetalView.h"

#import <CoreText/CoreText.h>
#import <simd/simd.h>

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
} MatrixCodeGlyphInstance;

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

static CTFontRef MatrixCodeCreateGlyphFont(NSDictionary *dictionary, CGFloat size) {
    NSString *font = MatrixCodeGlyphFont(dictionary);
    NSDictionary<NSString *, NSString *> *names = @{
        @"matrix": @"HiraginoSans-W6",
        @"gothic": @"YuGothic-Bold",
        @"mono": @"Menlo-Bold",
        @"terminal": @"Courier-Bold",
        @"rounded": @"ArialRoundedMTBold",
        @"mincho": @"HiraginoMinchoProN-W6",
    };
    NSArray<NSString *> *fallbacks = @[names[font] ?: names[@"matrix"], @"HiraginoSans-W6", @"Menlo-Bold"];
    for (NSString *name in fallbacks) {
        CTFontRef candidate = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
        if (candidate) return candidate;
    }
    return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
}

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

@interface MatrixCodeMetalView () <MTKViewDelegate>
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLTexture> atlas;
@property(nonatomic, strong) id<MTLBuffer> instanceBuffer;
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
@property(nonatomic, strong) NSMutableSet<NSNumber *> *claimedMessageCells;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *messageTargetGlyphs;
@property(nonatomic, strong) NSMutableData *glyphStateData;
@property(nonatomic) NSInteger glyphStateColumns;
@property(nonatomic) NSInteger glyphStateRows;
@property(nonatomic) NSInteger glyphStateLaneCount;
@property(nonatomic) NSTimeInterval lastGlyphStateTime;
@property(nonatomic) BOOL hasGlyphStateTime;
@end

@implementation MatrixCodeMetalView

#if DEBUG
+ (float)diagnosticEffectiveTrailLength:(float)trailLength
                                  rows:(float)rows
                          speedControl:(float)speedControl {
    return MatrixCodeEffectiveTrailLength(trailLength, rows, speedControl);
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
    self.preferredFramesPerSecond = 60;
    self.delegate = self;
    self.animationActive = NO;
    self.densityScale = 1;
    self.claimedMessageCells = [NSMutableSet set];
    self.messageTargetGlyphs = [NSMutableDictionary dictionary];
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

- (void)setAnimationActive:(BOOL)active {
    _animationActive = active;
    if (active) [self draw];
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
        @"verticalPosition": @0.475,
        @"verticalJitter": @0.25,
    };
    self.tokenResolver = [[MatrixCodeTokenResolver alloc] initWithStoredValues:storedValues
                                                                  runStartDate:[NSDate dateWithTimeIntervalSince1970:self.epochSeconds]];
    self.activeMessageTemplate = nil;
    self.activeMessageDisplay = nil;
    [self.claimedMessageCells removeAllObjects];
    [self.messageTargetGlyphs removeAllObjects];
    self.activeMessageStart = 0;
    self.activeMessageEnd = 0;
    float frequency = MatrixCodeNumber(self.messages, @"frequencyMs", 8000, 500, 600000) / 1000.0f;
    NSTimeInterval scheduleBase = self.animationActive
        ? NSDate.date.timeIntervalSince1970 : self.epochSeconds;
    self.nextMessageFire = scheduleBase + frequency *
        (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ 0xa511e9b3U));
    [self updatePalette];
    BOOL nextMirror = MatrixCodeBool(self.controls, @"mirror", YES);
    NSString *nextFont = MatrixCodeGlyphFont(self.controls);
    if (self.atlas && (previousMirror != nextMirror || ![previousFont isEqualToString:nextFont])) {
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
    if (!font) {
        CGContextRelease(context);
        return NO;
    }
    NSDictionary *attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.whiteColor.CGColor,
    };
    BOOL mirror = MatrixCodeBool(self.controls, @"mirror", YES);
    [glyphs enumerateObjectsUsingBlock:^(NSString *glyph, NSUInteger index, BOOL *stop) {
        NSInteger column = index % self.atlasColumns;
        NSInteger row = index / self.atlasColumns;
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:glyph attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
        CGFloat x = column * cell + (cell - bounds.size.width) * 0.5 - bounds.origin.x;
        CGFloat y = height - (row + 1) * cell + (cell - bounds.size.height) * 0.5 - bounds.origin.y;
        CGContextSaveGState(context);
        if (mirror && index < self.rainGlyphCount) {
            CGContextTranslateCTM(context, column * cell + cell, 0);
            CGContextScaleCTM(context, -1, 1);
            x = (cell - bounds.size.width) * 0.5 - bounds.origin.x;
        }
        CGContextSetTextPosition(context, x, y);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CFRelease(line);
    }];
    CFRelease(font);
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
        [self.claimedMessageCells removeAllObjects];
        [self.messageTargetGlyphs removeAllObjects];
        return;
    }
    if (self.activeMessageTemplate && now >= self.activeMessageEnd) {
        self.activeMessageTemplate = nil;
        self.activeMessageDisplay = nil;
        [self.claimedMessageCells removeAllObjects];
        [self.messageTargetGlyphs removeAllObjects];
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
        NSString *template = candidates[selected];
        NSString *display = [self.tokenResolver resolveText:template
                                                    atDate:[NSDate dateWithTimeIntervalSince1970:now]
                                           framesPerSecond:self.preferredFramesPerSecond];
        BOOL renderable = NO;
        for (NSUInteger index = 0; index < display.length; index++) {
            if (self.messageGlyphs[[display substringWithRange:NSMakeRange(index, 1)]]) {
                renderable = YES;
                break;
            }
        }
        if (!renderable || display.length > placementCols) {
            float frequency = MatrixCodeNumber(self.messages, @"frequencyMs", 8000, 500, 600000) / 1000.0f;
            self.nextMessageFire = now + frequency *
                (0.75 + 0.5 * MatrixCodeUnit(self.seed ^ activation ^ 0xa511e9b3U));
            return;
        }

        self.activeMessageTemplate = template;
        self.activeMessageDisplay = display;
        self.activeMessagePlacementColumns = placementCols;
        [self.claimedMessageCells removeAllObjects];
        [self.messageTargetGlyphs removeAllObjects];
        self.activeMessageStart = now;
        float appear = MatrixCodeNumber(self.messages, @"appearMs", 4000, 0, 600000) / 1000.0f;
        float hold = MatrixCodeNumber(self.messages, @"persistenceMs", 10000, 500, 600000) / 1000.0f;
        float disappear = MatrixCodeNumber(self.messages, @"disappearMs", 4000, 0, 600000) / 1000.0f;
        self.activeMessageEnd = now + appear + hold + disappear;

        float position = MatrixCodeNumber(self.messages, @"verticalPosition", 0.475, 0, 1);
        float jitter = MatrixCodeNumber(self.messages, @"verticalJitter", 0.25, 0, 1);
        NSInteger anchor = lroundf(position * MAX(0, placementRows - 1));
        NSInteger halfSpan = lroundf(jitter * MAX(0, placementRows - 1) * 0.5f);
        NSInteger low = MAX(0, anchor - halfSpan);
        NSInteger high = MIN(placementRows - 1, anchor + halfSpan);
        self.activeMessageRow = low + (NSInteger)(MatrixCodeHash(self.seed ^ activation ^ 0x9e3779b9U) %
            (uint32_t)MAX(1, high - low + 1));
        self.activeMessageStartColumn = MAX(0, (placementCols - (NSInteger)display.length) / 2);
    }
}

- (NSInteger)messageGlyphAtGlobalColumn:(NSInteger)globalColumn
                              globalRow:(NSInteger)globalRow
                            localColumn:(NSInteger)localColumn
                               localRow:(NSInteger)localRow
                                   time:(NSTimeInterval)now
                              intensity:(float *)intensity
                               scramble:(float *)scramble {
    if (!self.activeMessageTemplate) return NSNotFound;
    NSString *resolved = [self.tokenResolver resolveText:self.activeMessageTemplate
                                                  atDate:[NSDate dateWithTimeIntervalSince1970:now]
                                         framesPerSecond:self.preferredFramesPerSecond];
    BOOL renderable = NO;
    for (NSUInteger index = 0; index < resolved.length; index++) {
        if (self.messageGlyphs[[resolved substringWithRange:NSMakeRange(index, 1)]]) {
            renderable = YES;
            break;
        }
    }
    if (renderable && resolved.length <= self.activeMessagePlacementColumns) {
        self.activeMessageDisplay = resolved;
        self.activeMessageStartColumn =
            MAX(0, (self.activeMessagePlacementColumns - (NSInteger)resolved.length) / 2);
    }
    NSString *display = self.activeMessageDisplay ?: @"";
    float vignette = MatrixCodeVignette(self.controls);
    NSInteger row = vignette > 0 ? localRow : globalRow;
    NSInteger column = vignette > 0 ? localColumn : globalColumn;
    NSInteger offset = column - self.activeMessageStartColumn;
    if (row != self.activeMessageRow || offset < 0 || offset >= (NSInteger)display.length) return NSNotFound;
    NSString *character = [display substringWithRange:NSMakeRange(offset, 1)];
    NSNumber *glyph = self.messageGlyphs[character];
    if (glyph == nil) return NSNotFound;

    float appear = MatrixCodeNumber(self.messages, @"appearMs", 4000, 0, 600000) / 1000.0f;
    float disappear = MatrixCodeNumber(self.messages, @"disappearMs", 4000, 0, 600000) / 1000.0f;
    float elapsed = now - self.activeMessageStart;
    float remaining = self.activeMessageEnd - now;
    float fade = 1;
    float flicker = 0;
    if (appear > 0 && elapsed < appear) {
        fade = fmaxf(0, elapsed / appear);
        flicker = 1 - fade;
    } else if (disappear > 0 && remaining < disappear) {
        fade = fmaxf(0, remaining / disappear);
        flicker = 1 - fade;
    }
    *intensity = MatrixCodeBool(self.messages, @"brightnessFade", NO) ? fade : 1;
    *scramble = MatrixCodeBool(self.messages, @"flickerOut", YES) ? flicker : 0;
    return glyph.integerValue;
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
    self.instanceBuffer = [self.device newBufferWithLength:self.instanceCapacity * sizeof(MatrixCodeGlyphInstance)
                                                   options:MTLResourceStorageModeShared];
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
    NSTimeInterval now = self.animationActive ? NSDate.date.timeIntervalSince1970 : self.epochSeconds + 2.5;
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
    NSMutableSet<NSNumber *> *currentMessageTargets =
        self.activeMessageTemplate ? [NSMutableSet set] : nil;

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
            for (NSInteger row = 0; row < rows; row++) {
                int globalRow = (int)(firstGlobalRow + row);
                float brightness = 0;
                BOOL head = NO;
                BOOL whiteHead = NO;
                for (NSInteger stream = 0; stream < streamCount; stream++) {
                    uint32_t key = laneSeed ^ (uint32_t)(globalColumn * 0x9e3779b9U) ^
                        (uint32_t)(stream * 0x85ebca6bU);
                    MatrixCodeRainStreamSample streamSample = MatrixCodeRainSampleStream(
                        key, rainElapsed, self.densityScale, rampDuration, virtualRows,
                        speedControl, fmaxf(laneDensity, 0.1f), streamFraction);
                    if (!streamSample.active) continue;
                    float distance = streamSample.headRow - globalRow;
                    if (distance < 0) continue;
                    float trailSpeed = MatrixCodeRainEffectiveTrailSpeed(
                        streamSample.speed, speedControl, trailVariation);
                    float age = distance / fmaxf(trailSpeed, 0.1f);
                    float value = powf(trail, age / 1.2f);
                    if (value < 0.004f) continue;
                    if (distance < 1.05f) {
                        value = 1;
                        head = YES;
                        whiteHead = whiteHead || streamSample.whiteHead;
                    }
                    brightness = fmaxf(brightness, value);
                }
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
                float messageIntensity = 1;
                float messageScramble = 0;
                NSInteger messageGlyph = NSNotFound;
                if (lane == 0) {
                    messageGlyph = [self messageGlyphAtGlobalColumn:globalColumn
                                                          globalRow:globalRow
                                                        localColumn:column
                                                           localRow:row
                                                               time:now
                                                          intensity:&messageIntensity
                                                           scramble:&messageScramble];
                    if (messageGlyph != NSNotFound) {
                        uint64_t packedCell = ((uint64_t)(uint32_t)globalRow << 32) |
                            (uint32_t)globalColumn;
                        NSNumber *cellKey = @(packedCell);
                        [currentMessageTargets addObject:cellKey];
                        NSNumber *target = @(messageGlyph);
                        NSNumber *previousTarget = self.messageTargetGlyphs[cellKey];
                        if (previousTarget && ![previousTarget isEqualToNumber:target]) {
                            [self.claimedMessageCells removeObject:cellKey];
                        }
                        self.messageTargetGlyphs[cellKey] = target;
                    }
                }
                BOOL headArrival = head && !glyphState->wasHead;
                if (headArrival) {
                    NSInteger randomGlyph = MatrixCodeRainGlyphIndex(
                        MatrixCodeNextGlyphEventKey(glyphState), glyphMode);
                    glyphState->glyphOld = glyphState->glyphNew;
                    if (messageGlyph != NSNotFound) {
                        uint64_t packedCell = ((uint64_t)(uint32_t)globalRow << 32) |
                            (uint32_t)globalColumn;
                        [self.claimedMessageCells addObject:@(packedCell)];
                        if (messageScramble > 0 &&
                            MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState)) < messageScramble) {
                            glyphState->glyphNew = (uint8_t)randomGlyph;
                        } else {
                            glyphState->glyphNew = (uint8_t)messageGlyph;
                        }
                    } else {
                        glyphState->glyphNew = (uint8_t)randomGlyph;
                    }
                    glyphState->phase = 1;
                } else if (!head && brightness > 0.05f && mutationChance > 0) {
                    float roll = MatrixCodeUnit(MatrixCodeNextGlyphEventKey(glyphState));
                    if (roll < mutationChance) {
                        NSInteger randomGlyph = MatrixCodeRainGlyphIndex(
                            MatrixCodeNextGlyphEventKey(glyphState), glyphMode);
                        if (messageGlyph != NSNotFound) {
                            uint64_t packedCell = ((uint64_t)(uint32_t)globalRow << 32) |
                                (uint32_t)globalColumn;
                            [self.claimedMessageCells addObject:@(packedCell)];
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
                    uint64_t packedCell = ((uint64_t)(uint32_t)globalRow << 32) |
                        (uint32_t)globalColumn;
                    if ([self.claimedMessageCells containsObject:@(packedCell)]) {
                        brightness = fmaxf(brightness, 0.45f) * messageIntensity;
                    }
                }
                if (brightness < 0.004f) continue;
                NSInteger atlasColumn = glyph % self.atlasColumns;
                NSInteger atlasRow = glyph / self.atlasColumns;
                NSInteger oldAtlasColumn = oldGlyph % self.atlasColumns;
                NSInteger oldAtlasRow = oldGlyph / self.atlasColumns;
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
                };
            }
        }
    }
    if (currentMessageTargets) {
        for (NSNumber *cellKey in self.messageTargetGlyphs.allKeys.copy) {
            if (![currentMessageTargets containsObject:cellKey]) {
                [self.messageTargetGlyphs removeObjectForKey:cellKey];
                [self.claimedMessageCells removeObject:cellKey];
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
    [self updateInstancesForDrawableSize:view.drawableSize];
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
