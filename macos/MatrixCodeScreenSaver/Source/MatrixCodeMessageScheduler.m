#import "MatrixCodeMessageScheduler.h"

#import <math.h>

// Match JavaScript's separate IEEE-754 operations in optimized native builds.
#pragma STDC FP_CONTRACT OFF

const uint32_t MatrixCodeMessageSchedulerSeed = 0x5eed1eU;

static const double MatrixCodeMessageJitterMinimum = 0.75;
static const double MatrixCodeMessageJitterSpan = 0.5;
static const NSInteger MatrixCodeMessageGlyphStart = 99;

@interface MatrixCodeMessageRegion ()
@property(nonatomic) double columnStart;
@property(nonatomic) double rowStart;
@property(nonatomic) double columns;
@property(nonatomic) double rows;
@end

@implementation MatrixCodeMessageRegion

- (instancetype)initWithColumnStart:(double)columnStart
                           rowStart:(double)rowStart
                            columns:(double)columns
                               rows:(double)rows {
    self = [super init];
    if (!self) return nil;
    _columnStart = columnStart;
    _rowStart = rowStart;
    _columns = columns;
    _rows = rows;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

@interface MatrixCodeNormalizedMessageRegion : NSObject
@property(nonatomic) NSInteger columnStart;
@property(nonatomic) NSInteger rowStart;
@property(nonatomic) NSInteger columns;
@property(nonatomic) NSInteger rows;
@end

@implementation MatrixCodeNormalizedMessageRegion
@end

@interface MatrixCodeMessagePlacement : NSObject
@property(nonatomic, strong) MatrixCodeNormalizedMessageRegion *region;
@property(nonatomic) NSInteger row;
@property(nonatomic) NSInteger column;
@end

@implementation MatrixCodeMessagePlacement
@end

@interface MatrixCodePlacedGlyph : NSObject
@property(nonatomic) NSInteger offset;
@property(nonatomic) NSInteger glyph;
@end

@implementation MatrixCodePlacedGlyph
@end

@interface MatrixCodeMessageLayoutResult : NSObject
@property(nonatomic, copy) NSArray<MatrixCodePlacedGlyph *> *glyphs;
@property(nonatomic) NSInteger width;
@end

@implementation MatrixCodeMessageLayoutResult
@end

@interface MatrixCodeMessageSchedulerState : NSObject
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *configuration;
@property(nonatomic) BOOL hasRenderable;
@property(nonatomic) BOOL hasNextFireAt;
@property(nonatomic) double nextFireAt;
@property(nonatomic) BOOL hasActiveStart;
@property(nonatomic) double activeStart;
@property(nonatomic) BOOL hasActiveUntil;
@property(nonatomic) double activeUntil;
@property(nonatomic) BOOL pendingClear;
@property(nonatomic) NSInteger lastColumns;
@property(nonatomic) NSInteger lastRows;
@property(nonatomic, copy, nullable) NSString *activeRaw;
@property(nonatomic, copy) NSArray<MatrixCodeMessagePlacement *> *activePlacements;
@property(nonatomic, copy) NSString *activeDisplay;
@property(nonatomic, copy) NSString *placementKey;
@end

@implementation MatrixCodeMessageSchedulerState

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lastColumns = -1;
    _lastRows = -1;
    _activePlacements = @[];
    _activeDisplay = @"";
    _placementKey = @"";
    return self;
}

@end

static uint32_t MatrixCodeMessageMultiply32(uint32_t left, uint32_t right) {
    return (uint32_t)((uint64_t)left * (uint64_t)right);
}

/** Exact unsigned-bit equivalent of src/util/rng.ts createRng(). */
static double MatrixCodeMessageNextRandom(uint32_t *state) {
    uint32_t a = *state + 0x6d2b79f5U;
    *state = a;
    uint32_t t = MatrixCodeMessageMultiply32(a ^ (a >> 15), 1U | a);
    t = (t + MatrixCodeMessageMultiply32(t ^ (t >> 7), 61U | t)) ^ t;
    return (double)(t ^ (t >> 14)) / 4294967296.0;
}

static NSArray<NSString *> *MatrixCodeJavaScriptCodePoints(NSString *string) {
    NSMutableArray<NSString *> *characters = [NSMutableArray array];
    NSUInteger index = 0;
    while (index < string.length) {
        unichar first = [string characterAtIndex:index];
        NSUInteger length = 1;
        if (CFStringIsSurrogateHighCharacter(first) &&
            index + 1 < string.length &&
            CFStringIsSurrogateLowCharacter([string characterAtIndex:index + 1])) {
            length = 2;
        }
        [characters addObject:[string substringWithRange:NSMakeRange(index, length)]];
        index += length;
    }
    return characters;
}

static uint32_t MatrixCodeCodePointAtStart(NSString *string,
                                           NSUInteger index,
                                           NSUInteger *length) {
    unichar first = [string characterAtIndex:index];
    if (CFStringIsSurrogateHighCharacter(first) &&
        index + 1 < string.length) {
        unichar second = [string characterAtIndex:index + 1];
        if (CFStringIsSurrogateLowCharacter(second)) {
            if (length) *length = 2;
            return CFStringGetLongCharacterForSurrogatePair(first, second);
        }
    }
    if (length) *length = 1;
    return first;
}

static uint32_t MatrixCodeCodePointBeforeEnd(NSString *string,
                                             NSUInteger end,
                                             NSUInteger *start) {
    NSUInteger index = end - 1;
    unichar last = [string characterAtIndex:index];
    if (CFStringIsSurrogateLowCharacter(last) && index > 0) {
        unichar first = [string characterAtIndex:index - 1];
        if (CFStringIsSurrogateHighCharacter(first)) {
            if (start) *start = index - 1;
            return CFStringGetLongCharacterForSurrogatePair(first, last);
        }
    }
    if (start) *start = index;
    return last;
}

static BOOL MatrixCodeIsJavaScriptTrimCodePoint(uint32_t codePoint) {
    if (codePoint >= 0x0009 && codePoint <= 0x000d) return YES;
    if (codePoint >= 0x2000 && codePoint <= 0x200a) return YES;
    switch (codePoint) {
        case 0x0020:
        case 0x00a0:
        case 0x1680:
        case 0x2028:
        case 0x2029:
        case 0x202f:
        case 0x205f:
        case 0x3000:
        case 0xfeff:
            return YES;
        default:
            return NO;
    }
}

static NSString *MatrixCodeJavaScriptTrim(NSString *string) {
    NSUInteger start = 0;
    NSUInteger end = string.length;
    while (start < end) {
        NSUInteger length = 0;
        uint32_t codePoint = MatrixCodeCodePointAtStart(string, start, &length);
        if (!MatrixCodeIsJavaScriptTrimCodePoint(codePoint)) break;
        start += length;
    }
    while (end > start) {
        NSUInteger previousStart = 0;
        uint32_t codePoint = MatrixCodeCodePointBeforeEnd(string, end, &previousStart);
        if (!MatrixCodeIsJavaScriptTrimCodePoint(codePoint)) break;
        end = previousStart;
    }
    return [string substringWithRange:NSMakeRange(start, end - start)];
}

static BOOL MatrixCodeMessageValueIsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static double MatrixCodeSanitizedMessageNumber(NSDictionary *document,
                                                NSString *key,
                                                double minimum,
                                                double maximum,
                                                double fallback) {
    id value = document[key];
    if (![value isKindOfClass:NSNumber.class] ||
        MatrixCodeMessageValueIsBoolean(value) ||
        !isfinite([value doubleValue])) {
        return fallback;
    }
    return fmin(maximum, fmax(minimum, [value doubleValue]));
}

static BOOL MatrixCodeSanitizedMessageBoolean(NSDictionary *document,
                                              NSString *key,
                                              BOOL fallback) {
    id value = document[key];
    return MatrixCodeMessageValueIsBoolean(value) ? [value boolValue] : fallback;
}

static NSString *MatrixCodeSanitizedMessageChoice(NSDictionary *document,
                                                   NSString *key,
                                                   NSSet<NSString *> *allowed,
                                                   NSString *fallback) {
    id value = document[key];
    return [value isKindOfClass:NSString.class] && [allowed containsObject:value]
        ? value : fallback;
}

NSDictionary<NSString *, id> *MatrixCodeSanitizeMessagesDocument(id rawDocument) {
    NSDictionary *document = [rawDocument isKindOfClass:NSDictionary.class]
        ? rawDocument : @{};
    NSArray *rawMessages = [document[@"messages"] isKindOfClass:NSArray.class]
        ? document[@"messages"] : @[];
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    NSUInteger messageCount = MIN((NSUInteger)12, rawMessages.count);
    for (NSUInteger index = 0; index < messageCount; index++) {
        id value = rawMessages[index];
        NSString *message = [value isKindOfClass:NSString.class] ? value : @"";
        if (message.length > 120) message = [message substringToIndex:120];
        if (MatrixCodeJavaScriptTrim(message).length > 0) [messages addObject:message];
    }
    static NSSet<NSString *> *layouts;
    static NSSet<NSString *> *directions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        layouts = [NSSet setWithObjects:@"row", @"drop", nil];
        directions = [NSSet setWithObjects:@"topToBottom", @"bottomToTop", nil];
    });
    return @{
        @"messages": messages,
        @"enabled": @(MatrixCodeSanitizedMessageBoolean(document, @"enabled", NO)),
        @"frequencyMs": @(MatrixCodeSanitizedMessageNumber(
            document, @"frequencyMs", 500, 600000, 8000)),
        @"persistenceMs": @(MatrixCodeSanitizedMessageNumber(
            document, @"persistenceMs", 500, 600000, 10000)),
        @"appearMs": @(MatrixCodeSanitizedMessageNumber(
            document, @"appearMs", 0, 600000, 4000)),
        @"disappearMs": @(MatrixCodeSanitizedMessageNumber(
            document, @"disappearMs", 0, 600000, 4000)),
        @"flickerOut": @(MatrixCodeSanitizedMessageBoolean(
            document, @"flickerOut", YES)),
        @"brightnessFade": @(MatrixCodeSanitizedMessageBoolean(
            document, @"brightnessFade", NO)),
        @"messageLayout": MatrixCodeSanitizedMessageChoice(
            document, @"messageLayout", layouts, @"row"),
        @"messageDirection": MatrixCodeSanitizedMessageChoice(
            document, @"messageDirection", directions, @"topToBottom"),
        @"verticalPosition": @(MatrixCodeSanitizedMessageNumber(
            document, @"verticalPosition", 0, 1, 0.475)),
        @"verticalJitter": @(MatrixCodeSanitizedMessageNumber(
            document, @"verticalJitter", 0, 1, 0.25)),
    };
}

NSInteger MatrixCodeMessageGlyphIndexForCharacter(NSString *character) {
    static NSDictionary<NSString *, NSNumber *> *indices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *characters =
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=+-*<>:.,!?'";
        NSMutableDictionary<NSString *, NSNumber *> *next = [NSMutableDictionary dictionary];
        [MatrixCodeJavaScriptCodePoints(characters)
            enumerateObjectsUsingBlock:^(NSString *value, NSUInteger index, BOOL *stop) {
                (void)stop;
                if (!next[value]) next[value] = @(MatrixCodeMessageGlyphStart + (NSInteger)index);
            }];
        indices = [next copy];
    });
    NSNumber *index = indices[character];
    return index ? index.integerValue : NSNotFound;
}

static double MatrixCodeMessageNumber(NSDictionary<NSString *, id> *configuration,
                                      NSString *key,
                                      double fallback) {
    id value = configuration[key];
    return [value isKindOfClass:NSNumber.class] &&
        !MatrixCodeMessageValueIsBoolean(value) &&
        isfinite([value doubleValue])
        ? [value doubleValue] : fallback;
}

static BOOL MatrixCodeMessageBoolean(NSDictionary<NSString *, id> *configuration,
                                     NSString *key,
                                     BOOL fallback) {
    id value = configuration[key];
    return MatrixCodeMessageValueIsBoolean(value) ? [value boolValue] : fallback;
}

static NSArray<NSString *> *MatrixCodeMessageStrings(NSDictionary<NSString *, id> *configuration) {
    id value = configuration[@"messages"];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    for (id candidate in (NSArray *)value) {
        if ([candidate isKindOfClass:NSString.class]) [messages addObject:candidate];
    }
    return messages;
}

static BOOL MatrixCodeMessageUsesDropLayout(NSDictionary<NSString *, id> *configuration) {
    return [configuration[@"messageLayout"] isEqual:@"drop"];
}

static BOOL MatrixCodeMessageReadsBottomToTop(NSDictionary<NSString *, id> *configuration) {
    return [configuration[@"messageDirection"] isEqual:@"bottomToTop"];
}

@interface MatrixCodeMessageScheduler ()
- (MatrixCodeMessageSchedulerState *)schedulerState;
- (MatrixCodeMessageLayoutResult *)layoutMessage:(NSString *)message;
- (BOOL)applyMessage:(NSString *)display
                sink:(id<MatrixCodeMessageSink>)sink
            isUpdate:(BOOL)isUpdate;
@end

@implementation MatrixCodeMessageScheduler

- (instancetype)init {
    return [self initWithSeed:MatrixCodeMessageSchedulerSeed
           glyphIndexResolver:nil
                 textResolver:nil];
}

- (instancetype)initWithSeed:(uint32_t)seed {
    return [self initWithSeed:seed glyphIndexResolver:nil textResolver:nil];
}

- (instancetype)initWithSeed:(uint32_t)seed
          glyphIndexResolver:(MatrixCodeMessageGlyphIndexResolver)glyphIndexResolver
                textResolver:(MatrixCodeMessageTextResolver)textResolver {
    self = [super init];
    if (!self) return nil;
    _rngState = seed;
    _glyphIndexResolver = [glyphIndexResolver ?: ^NSInteger(NSString *character) {
        return MatrixCodeMessageGlyphIndexForCharacter(character);
    } copy];
    _textResolver = [textResolver ?: ^NSString *(NSString *rawText) {
        return rawText;
    } copy];
    _state = [[MatrixCodeMessageSchedulerState alloc] init];
    return self;
}

- (MatrixCodeMessageSchedulerState *)schedulerState {
    return (MatrixCodeMessageSchedulerState *)_state;
}

- (NSString *)resolveText:(NSString *)rawText {
    NSString *resolved = _textResolver(rawText);
    return [resolved isKindOfClass:NSString.class] ? resolved : @"";
}

- (void)configureWithDocument:(NSDictionary<NSString *,id> *)document {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    NSDictionary<NSString *, id> *sanitized =
        MatrixCodeSanitizeMessagesDocument(document);
    state.configuration = sanitized;
    state.hasRenderable = [self computeHasRenderable:sanitized];
    if (state.hasActiveUntil) state.pendingClear = YES;
    state.hasActiveStart = NO;
    state.hasActiveUntil = NO;
    state.hasNextFireAt = NO;
    state.activePlacements = @[];
    state.placementKey = @"";
}

- (BOOL)computeHasRenderable:(NSDictionary<NSString *, id> *)configuration {
    for (NSString *message in MatrixCodeMessageStrings(configuration)) {
        if ([self layoutMessage:[self resolveText:message]].glyphs.count > 0) return YES;
    }
    return NO;
}

- (double)gap {
    NSDictionary *configuration = self.schedulerState.configuration;
    double frequency = MatrixCodeMessageNumber(configuration, @"frequencyMs", 8000);
    return frequency * (MatrixCodeMessageJitterMinimum +
                        MatrixCodeMessageJitterSpan * MatrixCodeMessageNextRandom(&_rngState));
}

- (NSInteger)pickAxisIndexForSize:(NSInteger)size {
    NSInteger maximumIndex = size - 1;
    if (maximumIndex <= 0) return 0;
    NSDictionary *configuration = self.schedulerState.configuration;
    double position = MatrixCodeMessageNumber(configuration, @"verticalPosition", 0.475);
    double jitter = MatrixCodeMessageNumber(configuration, @"verticalJitter", 0.25);
    NSInteger anchor = (NSInteger)floor(position * maximumIndex + 0.5);
    NSInteger halfSpan = (NSInteger)floor((jitter * maximumIndex) / 2 + 0.5);
    NSInteger low = MAX(0, anchor - halfSpan);
    NSInteger high = MIN(maximumIndex, anchor + halfSpan);
    return low + (NSInteger)floor(
        MatrixCodeMessageNextRandom(&_rngState) * (double)(high - low + 1));
}

- (NSArray<MatrixCodeNormalizedMessageRegion *> *)normalizeRegionsForSink:
        (id<MatrixCodeMessageSink>)sink
        regions:(NSArray<MatrixCodeMessageRegion *> *)regions {
    if (regions.count == 0) {
        MatrixCodeNormalizedMessageRegion *full = [[MatrixCodeNormalizedMessageRegion alloc] init];
        full.columnStart = 0;
        full.rowStart = 0;
        full.columns = sink.columns;
        full.rows = sink.rows;
        return @[full];
    }

    NSMutableArray<MatrixCodeNormalizedMessageRegion *> *normalized =
        [NSMutableArray array];
    for (id candidate in regions) {
        if (![candidate isKindOfClass:MatrixCodeMessageRegion.class]) continue;
        MatrixCodeMessageRegion *region = candidate;
        if (!isfinite(region.columnStart) || !isfinite(region.rowStart) ||
            !isfinite(region.columns) || !isfinite(region.rows)) {
            continue;
        }
        NSInteger columnStart = MAX(0, MIN(sink.columns, (NSInteger)floor(region.columnStart)));
        NSInteger rowStart = MAX(0, MIN(sink.rows, (NSInteger)floor(region.rowStart)));
        NSInteger columnEnd = MAX(columnStart, MIN(sink.columns,
            (NSInteger)ceil(region.columnStart + region.columns)));
        NSInteger rowEnd = MAX(rowStart, MIN(sink.rows,
            (NSInteger)ceil(region.rowStart + region.rows)));
        if (columnEnd > columnStart && rowEnd > rowStart) {
            MatrixCodeNormalizedMessageRegion *value =
                [[MatrixCodeNormalizedMessageRegion alloc] init];
            value.columnStart = columnStart;
            value.rowStart = rowStart;
            value.columns = columnEnd - columnStart;
            value.rows = rowEnd - rowStart;
            [normalized addObject:value];
        }
    }
    if (normalized.count > 0) return normalized;

    MatrixCodeNormalizedMessageRegion *full = [[MatrixCodeNormalizedMessageRegion alloc] init];
    full.columnStart = 0;
    full.rowStart = 0;
    full.columns = sink.columns;
    full.rows = sink.rows;
    return @[full];
}

- (NSString *)keyForRegions:(NSArray<MatrixCodeNormalizedMessageRegion *> *)regions {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:regions.count];
    for (MatrixCodeNormalizedMessageRegion *region in regions) {
        [parts addObject:[NSString stringWithFormat:@"%ld,%ld,%ld,%ld",
            (long)region.columnStart, (long)region.rowStart,
            (long)region.columns, (long)region.rows]];
    }
    return [parts componentsJoinedByString:@";"];
}

- (void)choosePlacements:(NSArray<MatrixCodeNormalizedMessageRegion *> *)regions {
    BOOL dropLayout = MatrixCodeMessageUsesDropLayout(
        self.schedulerState.configuration);
    NSMutableArray<MatrixCodeMessagePlacement *> *placements =
        [NSMutableArray arrayWithCapacity:regions.count];
    for (MatrixCodeNormalizedMessageRegion *region in regions) {
        MatrixCodeMessagePlacement *placement = [[MatrixCodeMessagePlacement alloc] init];
        placement.region = region;
        if (dropLayout) {
            placement.row = region.rowStart;
            placement.column = region.columnStart +
                [self pickAxisIndexForSize:region.columns];
        } else {
            placement.row = region.rowStart + [self pickAxisIndexForSize:region.rows];
            placement.column = region.columnStart;
        }
        [placements addObject:placement];
    }
    self.schedulerState.activePlacements = placements;
}

- (MatrixCodeMessageLayoutResult *)layoutMessage:(NSString *)message {
    NSArray<NSString *> *characters =
        MatrixCodeJavaScriptCodePoints(MatrixCodeJavaScriptTrim(message));
    NSMutableArray<MatrixCodePlacedGlyph *> *glyphs = [NSMutableArray array];
    [characters enumerateObjectsUsingBlock:
        ^(NSString *character, NSUInteger index, BOOL *stop) {
            (void)stop;
            NSInteger glyph = self->_glyphIndexResolver(character);
            if (glyph != NSNotFound) {
                MatrixCodePlacedGlyph *placed = [[MatrixCodePlacedGlyph alloc] init];
                placed.offset = (NSInteger)index;
                placed.glyph = glyph;
                [glyphs addObject:placed];
            }
        }];
    MatrixCodeMessageLayoutResult *result = [[MatrixCodeMessageLayoutResult alloc] init];
    result.glyphs = glyphs;
    result.width = (NSInteger)characters.count;
    return result;
}

- (BOOL)applyMessage:(NSString *)display
                sink:(id<MatrixCodeMessageSink>)sink
            isUpdate:(BOOL)isUpdate {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    MatrixCodeMessageLayoutResult *layout = [self layoutMessage:display];
    BOOL dropLayout = MatrixCodeMessageUsesDropLayout(state.configuration);
    if (layout.glyphs.count == 0 || state.activePlacements.count == 0) return NO;
    for (MatrixCodeMessagePlacement *placement in state.activePlacements) {
        NSInteger available = dropLayout
            ? placement.region.rows : placement.region.columns;
        if (layout.width > available) return NO;
    }

    NSMutableDictionary<NSNumber *, NSNumber *> *targets = [NSMutableDictionary dictionary];
    for (MatrixCodeMessagePlacement *placement in state.activePlacements) {
        MatrixCodeNormalizedMessageRegion *region = placement.region;
        if (dropLayout) {
            NSInteger startRow = region.rowStart + (NSInteger)floor(
                (double)(region.rows - layout.width) / 2);
            BOOL bottomToTop = MatrixCodeMessageReadsBottomToTop(state.configuration);
            for (MatrixCodePlacedGlyph *placed in layout.glyphs) {
                NSInteger targetRow = bottomToTop
                    ? startRow + layout.width - 1 - placed.offset
                    : startRow + placed.offset;
                targets[@(targetRow * sink.columns + placement.column)] = @(placed.glyph);
            }
        } else {
            NSInteger startColumn = region.columnStart + (NSInteger)floor(
                (double)(region.columns - layout.width) / 2);
            for (MatrixCodePlacedGlyph *placed in layout.glyphs) {
                NSInteger targetColumn = startColumn + placed.offset;
                targets[@(placement.row * sink.columns + targetColumn)] = @(placed.glyph);
            }
        }
    }
    if (targets.count == 0) return NO;

    if (isUpdate) [sink updateMessageTargets:targets];
    else [sink setMessageTargets:targets];
    state.activeDisplay = display;
    return YES;
}

- (double)envelopeAtTime:(double)nowMilliseconds {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    double appear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"appearMs", 4000));
    double disappear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"disappearMs", 4000));
    double elapsed = nowMilliseconds - state.activeStart;
    if (appear > 0 && elapsed < appear) return elapsed / appear;
    double fadeOutStart = state.activeUntil - state.activeStart - disappear;
    if (disappear > 0 && elapsed > fadeOutStart) {
        return MAX(0, (state.activeUntil - nowMilliseconds) / disappear);
    }
    return 1;
}

- (double)scrambleAtTime:(double)nowMilliseconds {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    double appear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"appearMs", 4000));
    double disappear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"disappearMs", 4000));
    double elapsed = nowMilliseconds - state.activeStart;
    if (appear > 0 && elapsed < appear) return 1 - elapsed / appear;
    if (disappear > 0) {
        double fadeOutStart = state.activeUntil - state.activeStart - disappear;
        if (elapsed > fadeOutStart) {
            return MIN(1, (elapsed - fadeOutStart) / disappear);
        }
    }
    return 0;
}

- (void)fireAtTime:(double)nowMilliseconds
              sink:(id<MatrixCodeMessageSink>)sink
           regions:(NSArray<MatrixCodeNormalizedMessageRegion *> *)regions {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *message in MatrixCodeMessageStrings(state.configuration)) {
        NSString *trimmed = MatrixCodeJavaScriptTrim(message);
        if (trimmed.length > 0) [candidates addObject:trimmed];
    }
    if (candidates.count == 0) {
        state.hasNextFireAt = YES;
        state.nextFireAt = nowMilliseconds + self.gap;
        return;
    }

    NSUInteger index = (NSUInteger)floor(
        MatrixCodeMessageNextRandom(&_rngState) * candidates.count);
    NSString *raw = candidates[index];
    [self choosePlacements:regions];
    NSString *display = [self resolveText:raw];
    if (![self applyMessage:display sink:sink isUpdate:NO]) {
        state.activePlacements = @[];
        state.hasNextFireAt = YES;
        state.nextFireAt = nowMilliseconds + self.gap;
        return;
    }

    state.activeRaw = raw;
    state.hasActiveStart = YES;
    state.activeStart = nowMilliseconds;
    double appear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"appearMs", 4000));
    double persistence = MatrixCodeMessageNumber(
        state.configuration, @"persistenceMs", 10000);
    double disappear = MAX(0, MatrixCodeMessageNumber(
        state.configuration, @"disappearMs", 4000));
    state.hasActiveUntil = YES;
    state.activeUntil = nowMilliseconds + appear + persistence + disappear;
    double intensity = MatrixCodeMessageBoolean(
        state.configuration, @"brightnessFade", NO)
        ? [self envelopeAtTime:nowMilliseconds] : 1;
    double scramble = MatrixCodeMessageBoolean(
        state.configuration, @"flickerOut", YES)
        ? [self scrambleAtTime:nowMilliseconds] : 0;
    [sink setMessageIntensity:intensity];
    [sink setMessageScramble:scramble];
}

- (void)updateAtTimeMilliseconds:(double)nowMilliseconds
                            sink:(id<MatrixCodeMessageSink>)sink {
    [self updateAtTimeMilliseconds:nowMilliseconds sink:sink regions:nil];
}

- (void)updateAtTimeMilliseconds:(double)nowMilliseconds
                            sink:(id<MatrixCodeMessageSink>)sink
                         regions:(NSArray<MatrixCodeMessageRegion *> *)regions {
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    if (state.pendingClear) {
        [sink clearMessageTargets];
        state.pendingClear = NO;
    }

    NSDictionary *configuration = state.configuration;
    if (!configuration ||
        !MatrixCodeMessageBoolean(configuration, @"enabled", NO) ||
        !state.hasRenderable) {
        // Skip region normalization and key building on this every-frame
        // default path. placementKey is left stale: it is only consulted while
        // a message is active, and hasActiveUntil is cleared here, so the next
        // enabled update stores a fresh key before any comparison matters.
        if (state.hasActiveUntil) {
            [sink clearMessageTargets];
            state.hasActiveStart = NO;
            state.hasActiveUntil = NO;
        }
        state.hasNextFireAt = NO;
        state.lastColumns = sink.columns;
        state.lastRows = sink.rows;
        return;
    }

    NSArray<MatrixCodeNormalizedMessageRegion *> *placementRegions =
        [self normalizeRegionsForSink:sink regions:regions];
    NSString *placementKey = [self keyForRegions:placementRegions];
    BOOL placementChanged = ![placementKey isEqualToString:state.placementKey];
    if ((sink.columns != state.lastColumns ||
         sink.rows != state.lastRows ||
         placementChanged) &&
        state.hasActiveUntil) {
        [self choosePlacements:placementRegions];
        NSString *display = state.activeRaw
            ? [self resolveText:state.activeRaw] : state.activeDisplay;
        if (![self applyMessage:display sink:sink isUpdate:NO]) {
            state.activeRaw = nil;
            state.hasActiveStart = NO;
            state.hasActiveUntil = NO;
            state.hasNextFireAt = YES;
            state.nextFireAt = nowMilliseconds + self.gap;
            state.activePlacements = @[];
        }
    }
    state.lastColumns = sink.columns;
    state.lastRows = sink.rows;
    state.placementKey = placementKey;

    if (state.hasActiveUntil) {
        if (nowMilliseconds >= state.activeUntil) {
            [sink clearMessageTargets];
            state.hasActiveStart = NO;
            state.hasActiveUntil = NO;
            state.hasNextFireAt = YES;
            state.nextFireAt = nowMilliseconds + self.gap;
            state.activePlacements = @[];
        } else {
            if (state.activeRaw) {
                NSString *display = [self resolveText:state.activeRaw];
                if (![display isEqualToString:state.activeDisplay]) {
                    [self applyMessage:display sink:sink isUpdate:YES];
                }
            }
            double intensity = MatrixCodeMessageBoolean(
                configuration, @"brightnessFade", NO)
                ? [self envelopeAtTime:nowMilliseconds] : 1;
            double scramble = MatrixCodeMessageBoolean(
                configuration, @"flickerOut", YES)
                ? [self scrambleAtTime:nowMilliseconds] : 0;
            [sink setMessageIntensity:intensity];
            [sink setMessageScramble:scramble];
        }
        return;
    }

    if (!state.hasNextFireAt) {
        state.hasNextFireAt = YES;
        state.nextFireAt = nowMilliseconds + self.gap;
        return;
    }
    if (nowMilliseconds >= state.nextFireAt) {
        [self fireAtTime:nowMilliseconds sink:sink regions:placementRegions];
    }
}

- (void)previewOneAtTimeMilliseconds:(double)nowMilliseconds
                                sink:(id<MatrixCodeMessageSink>)sink
                            document:(NSDictionary<NSString *,id> *)document {
    [self previewOneAtTimeMilliseconds:nowMilliseconds
                                  sink:sink
                              document:document
                               regions:nil];
}

- (void)previewOneAtTimeMilliseconds:(double)nowMilliseconds
                                sink:(id<MatrixCodeMessageSink>)sink
                            document:(NSDictionary<NSString *,id> *)document
                             regions:(NSArray<MatrixCodeMessageRegion *> *)regions {
    if (document) [self configureWithDocument:document];
    MatrixCodeMessageSchedulerState *state = self.schedulerState;
    if (!state.configuration) return;
    if (state.pendingClear) {
        [sink clearMessageTargets];
        state.pendingClear = NO;
    }
    state.lastColumns = sink.columns;
    state.lastRows = sink.rows;
    NSArray<MatrixCodeNormalizedMessageRegion *> *placementRegions =
        [self normalizeRegionsForSink:sink regions:regions];
    state.placementKey = [self keyForRegions:placementRegions];
    [self fireAtTime:nowMilliseconds sink:sink regions:placementRegions];
}

@end
