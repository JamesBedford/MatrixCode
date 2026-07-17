#import "MatrixCodeRainSimulation.h"

#import <math.h>
#import <string.h>

// JavaScript evaluates the RainSim arithmetic as separate IEEE-754 operations.
// Keep optimized native builds from contracting multiply-add expressions so the
// packed-state fixtures retain the same rounding behavior.
#pragma STDC FP_CONTRACT OFF

static const double MatrixCodeRainMinimumBrightness = 0.004;
static const double MatrixCodeRainTrailControlMinimum = 0.01;
static const double MatrixCodeRainTrailControlMaximum = 0.5;
static const double MatrixCodeRainMaximumTrailViewports = 3.0;
static const double MatrixCodeRainDensityScale = 0.5;
static const uint8_t MatrixCodeRainHeadFlag = 0x80;
static const uint8_t MatrixCodeRainWhiteHeadFlag = 0x40;
static const uint8_t MatrixCodeRainPhaseMask = 0x3f;

static const NSInteger MatrixCodeRainKatakanaCount = 56;
static const NSInteger MatrixCodeRainDigitStart = 56;
static const NSInteger MatrixCodeRainDigitCount = 10;
static const NSInteger MatrixCodeRainLatinStart = 66;
static const NSInteger MatrixCodeRainLatinCount = 26;
static const NSInteger MatrixCodeRainSymbolsStart = 92;
static const NSInteger MatrixCodeRainSymbolsCount = 7;

typedef struct {
    double y;
    double speed;
    uint8_t white;
} MatrixCodeRainSimulationStream;

typedef struct {
    MatrixCodeRainSimulationStream *items;
    NSUInteger count;
    NSUInteger capacity;
} MatrixCodeRainSimulationStreamList;

typedef struct {
    NSInteger columns;
    NSInteger rows;
    MatrixCodeRainSimulationStreamList *streams;
    float *respawnTimer;
    float *columnGate;
    float *brightness;
    float *trailSpeed;
    uint8_t *glyphNew;
    uint8_t *glyphOld;
    float *phase;
    uint8_t *headMark;
    int16_t *messageTargets;
    uint8_t *claimed;
} MatrixCodeRainSimulationStorage;

MatrixCodeRainSimulationConfig MatrixCodeRainSimulationDefaultConfig(void) {
    return (MatrixCodeRainSimulationConfig){
        .targetCellPx = 18,
        .minSpeed = 3.5,
        .speedRange = 8,
        .decayPerSecond = 0.08,
        .trailLengthScale = 1.2,
        .mutationRate = 1.6,
        .crossfadeDuration = 0.09,
        .whiteHeadFraction = 0.2,
        .respawnChance = 1.1,
        .respawnDelayMin = 0.15,
        .respawnDelayJitter = 2.6,
        .startRowsAbove = 24,
        .tailMargin = 36,
        .globalSyncAmount = 0.35,
        .globalSyncHz = 1.7,
        .messageBrightFloor = 0.45,
    };
}

static double MatrixCodeRainClamp(double value, double minimum, double maximum) {
    return fmin(maximum, fmax(minimum, value));
}

static uint32_t MatrixCodeRainMultiply32(uint32_t left, uint32_t right) {
    return (uint32_t)((uint64_t)left * (uint64_t)right);
}

/** Exact unsigned-bit equivalent of src/util/rng.ts createRng(). */
static double MatrixCodeRainNextRandom(uint32_t *state) {
    uint32_t a = *state + 0x6d2b79f5U;
    *state = a;
    uint32_t t = MatrixCodeRainMultiply32(a ^ (a >> 15), 1U | a);
    t = (t + MatrixCodeRainMultiply32(t ^ (t >> 7), 61U | t)) ^ t;
    return (double)(t ^ (t >> 14)) / 4294967296.0;
}

static BOOL MatrixCodeRainValidGlyphMode(NSString *mode) {
    static NSSet<NSString *> *modes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        modes = [NSSet setWithObjects:
            @"matrix", @"katakana", @"binary", @"digits", @"latin", @"symbols", nil];
    });
    return [mode isKindOfClass:NSString.class] && [modes containsObject:mode];
}

// randomGlyphIndex runs on every head light and glyph mutation, so the mode is
// resolved to this enum once in setGlyphMode: instead of comparing strings per
// call.
typedef NS_ENUM(NSInteger, MatrixCodeRainGlyphModeKind) {
    MatrixCodeRainGlyphModeKindMatrix = 0,
    MatrixCodeRainGlyphModeKindKatakana,
    MatrixCodeRainGlyphModeKindBinary,
    MatrixCodeRainGlyphModeKindDigits,
    MatrixCodeRainGlyphModeKindLatin,
    MatrixCodeRainGlyphModeKindSymbols,
};

static NSInteger MatrixCodeRainGlyphModeKindForMode(NSString *mode) {
    if ([mode isEqualToString:@"katakana"]) return MatrixCodeRainGlyphModeKindKatakana;
    if ([mode isEqualToString:@"binary"]) return MatrixCodeRainGlyphModeKindBinary;
    if ([mode isEqualToString:@"digits"]) return MatrixCodeRainGlyphModeKindDigits;
    if ([mode isEqualToString:@"latin"]) return MatrixCodeRainGlyphModeKindLatin;
    if ([mode isEqualToString:@"symbols"]) return MatrixCodeRainGlyphModeKindSymbols;
    return MatrixCodeRainGlyphModeKindMatrix;
}

static double MatrixCodeRainControlNumber(NSDictionary<NSString *, id> *controls,
                                          NSString *key,
                                          double fallback) {
    id value = controls[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue])) {
        return fallback;
    }
    return [value doubleValue];
}

static void MatrixCodeRainAppendStream(MatrixCodeRainSimulationStreamList *list,
                                       MatrixCodeRainSimulationStream stream) {
    if (list->count == list->capacity) {
        NSUInteger nextCapacity = MAX((NSUInteger)2, list->capacity * 2);
        MatrixCodeRainSimulationStream *next = realloc(
            list->items, nextCapacity * sizeof(MatrixCodeRainSimulationStream));
        NSCAssert(next != NULL, @"Unable to allocate Matrix rain streams");
        list->items = next;
        list->capacity = nextCapacity;
    }
    list->items[list->count++] = stream;
}

static void MatrixCodeRainRemoveStream(MatrixCodeRainSimulationStreamList *list,
                                       NSUInteger index) {
    if (index >= list->count) return;
    NSUInteger trailing = list->count - index - 1;
    if (trailing > 0) {
        memmove(&list->items[index],
                &list->items[index + 1],
                trailing * sizeof(MatrixCodeRainSimulationStream));
    }
    list->count--;
}

static MatrixCodeRainSimulationStorage *MatrixCodeRainCreateStorage(NSInteger columns,
                                                                   NSInteger rows,
                                                                   uint32_t seed) {
    MatrixCodeRainSimulationStorage *storage = calloc(1, sizeof(MatrixCodeRainSimulationStorage));
    NSCAssert(storage != NULL, @"Unable to allocate Matrix rain storage");
    storage->columns = columns;
    storage->rows = rows;
    NSUInteger columnCount = (NSUInteger)columns;
    NSUInteger rowCount = (NSUInteger)rows;
    NSUInteger cellCount = columnCount * rowCount;
    storage->streams = calloc(columnCount, sizeof(MatrixCodeRainSimulationStreamList));
    storage->respawnTimer = calloc(columnCount, sizeof(float));
    storage->columnGate = calloc(columnCount, sizeof(float));
    storage->brightness = calloc(cellCount, sizeof(float));
    storage->trailSpeed = calloc(cellCount, sizeof(float));
    storage->glyphNew = calloc(cellCount, sizeof(uint8_t));
    storage->glyphOld = calloc(cellCount, sizeof(uint8_t));
    storage->phase = calloc(cellCount, sizeof(float));
    storage->headMark = calloc(rowCount, sizeof(uint8_t));
    storage->claimed = calloc(cellCount, sizeof(uint8_t));
    NSCAssert(storage->streams && storage->respawnTimer && storage->columnGate &&
              storage->brightness && storage->trailSpeed && storage->glyphNew &&
              storage->glyphOld && storage->phase && storage->headMark && storage->claimed,
              @"Unable to allocate Matrix rain grid");

    uint32_t gateState = seed ^ 0x85ebca6bU;
    for (NSInteger column = 0; column < columns; column++) {
        storage->columnGate[column] = (float)MatrixCodeRainNextRandom(&gateState);
    }
    return storage;
}

static void MatrixCodeRainDestroyStorage(MatrixCodeRainSimulationStorage *storage) {
    if (!storage) return;
    for (NSInteger column = 0; column < storage->columns; column++) {
        free(storage->streams[column].items);
    }
    free(storage->streams);
    free(storage->respawnTimer);
    free(storage->columnGate);
    free(storage->brightness);
    free(storage->trailSpeed);
    free(storage->glyphNew);
    free(storage->glyphOld);
    free(storage->phase);
    free(storage->headMark);
    free(storage->messageTargets);
    free(storage->claimed);
    free(storage);
}

static double MatrixCodeRainVisibleTrailRows(double trailLength,
                                             double speedRowsPerSecond,
                                             double scale) {
    return speedRowsPerSecond * scale * log(MatrixCodeRainMinimumBrightness) / log(trailLength);
}

static double MatrixCodeRainTrailLengthForVisibleRows(double rows,
                                                      double speedRowsPerSecond,
                                                      double scale) {
    return exp(log(MatrixCodeRainMinimumBrightness) * scale * speedRowsPerSecond /
               fmax(1, rows));
}

static double MatrixCodeRainEffectiveTrailLength(NSDictionary<NSString *, id> *controls,
                                                 NSInteger rows,
                                                 MatrixCodeRainSimulationConfig config) {
    double trailLength = MatrixCodeRainControlNumber(controls, @"trailLength", 0.255);
    double percent = MatrixCodeRainClamp(
        (trailLength - MatrixCodeRainTrailControlMinimum) /
            (MatrixCodeRainTrailControlMaximum - MatrixCodeRainTrailControlMinimum),
        0,
        1);
    double speed = MatrixCodeRainControlNumber(controls, @"speed", 1);
    double averageSpeed = (config.minSpeed + config.speedRange * 0.5) * fmax(speed, 0.1);
    double viewportRows = fmax(1, rows);
    double previousMaximumRows = MatrixCodeRainVisibleTrailRows(
        MatrixCodeRainTrailControlMaximum, averageSpeed, config.trailLengthScale);
    double minimumRows = viewportRows;
    double maximumRows = fmax(fmax(viewportRows * MatrixCodeRainMaximumTrailViewports,
                                   previousMaximumRows),
                              minimumRows + 1);
    double targetRows = minimumRows * pow(maximumRows / minimumRows, percent);
    return MatrixCodeRainTrailLengthForVisibleRows(
        targetRows, averageSpeed, config.trailLengthScale);
}

double MatrixCodeRainEffectiveTrailLengthForControls(NSDictionary<NSString *, id> *controls,
                                                     NSInteger rows,
                                                     MatrixCodeRainSimulationConfig config) {
    return MatrixCodeRainEffectiveTrailLength(controls, rows, config);
}

static double MatrixCodeRainEffectiveTrailSpeed(double streamSpeed,
                                                double speedControl,
                                                double variation,
                                                MatrixCodeRainSimulationConfig config) {
    double averageSpeed = (config.minSpeed + config.speedRange * 0.5) *
        fmax(speedControl, 0.1);
    return averageSpeed + (streamSpeed - averageSpeed) * MatrixCodeRainClamp(variation, 0, 1);
}

@implementation MatrixCodeRainSimulation

- (instancetype)initWithColumns:(NSInteger)columns
                            rows:(NSInteger)rows
                            seed:(uint32_t)seed {
    return [self initWithColumns:columns
                            rows:rows
                          config:MatrixCodeRainSimulationDefaultConfig()
                       glyphMode:@"matrix"
                            seed:seed];
}

- (instancetype)initWithColumns:(NSInteger)columns
                            rows:(NSInteger)rows
                          config:(MatrixCodeRainSimulationConfig)config
                       glyphMode:(NSString *)glyphMode
                            seed:(uint32_t)seed {
    NSParameterAssert(columns > 0);
    NSParameterAssert(rows > 0);
    self = [super init];
    if (!self) return nil;
    _columns = columns;
    _rows = rows;
    _config = config;
    _seed = seed;
    _rngState = seed;
    _messageRngState = seed ^ 0x27d4eb2dU;
    _spawnRateScale = 1;
    _messageIntensity = 1;
    _glyphMode = MatrixCodeRainValidGlyphMode(glyphMode) ? [glyphMode copy] : @"matrix";
    _glyphModeKind = MatrixCodeRainGlyphModeKindForMode(_glyphMode);
    _storage = MatrixCodeRainCreateStorage(columns, rows, seed);
    _stateData = [NSMutableData dataWithLength:(NSUInteger)columns * (NSUInteger)rows * 4];
    [self seedColumnsFrom:0 to:columns storage:(MatrixCodeRainSimulationStorage *)_storage];
    return self;
}

- (void)dealloc {
    MatrixCodeRainDestroyStorage((MatrixCodeRainSimulationStorage *)_storage);
}

- (NSInteger)columns { return _columns; }
- (NSInteger)rows { return _rows; }
- (NSData *)stateData { return _stateData; }
- (double)simulationTime { return _simulationTime; }
- (double)spawnRateScale { return _spawnRateScale; }
- (void)setSpawnRateScale:(double)spawnRateScale { _spawnRateScale = spawnRateScale; }
- (NSString *)glyphMode { return _glyphMode; }

- (void)setGlyphMode:(NSString *)glyphMode {
    _glyphMode = MatrixCodeRainValidGlyphMode(glyphMode) ? [glyphMode copy] : @"matrix";
    _glyphModeKind = MatrixCodeRainGlyphModeKindForMode(_glyphMode);
}

- (BOOL)hasMessageTargets {
    return ((MatrixCodeRainSimulationStorage *)_storage)->messageTargets != NULL;
}

- (void)seedColumnsFrom:(NSInteger)from
                     to:(NSInteger)to
                storage:(MatrixCodeRainSimulationStorage *)storage {
    for (NSInteger column = from; column < to; column++) {
        storage->streams[column].count = 0;
        storage->respawnTimer[column] =
            (float)(MatrixCodeRainNextRandom(&_rngState) * _config.respawnDelayJitter);
    }
}

- (uint8_t)randomGlyphIndex {
    switch (_glyphModeKind) {
        case MatrixCodeRainGlyphModeKindBinary:
            return (uint8_t)(MatrixCodeRainDigitStart +
                floor(MatrixCodeRainNextRandom(&_rngState) * 2));
        case MatrixCodeRainGlyphModeKindKatakana:
            return (uint8_t)floor(MatrixCodeRainNextRandom(&_rngState) *
                                  MatrixCodeRainKatakanaCount);
        case MatrixCodeRainGlyphModeKindDigits:
            return (uint8_t)(MatrixCodeRainDigitStart +
                floor(MatrixCodeRainNextRandom(&_rngState) * MatrixCodeRainDigitCount));
        case MatrixCodeRainGlyphModeKindLatin:
            return (uint8_t)(MatrixCodeRainLatinStart +
                floor(MatrixCodeRainNextRandom(&_rngState) * MatrixCodeRainLatinCount));
        case MatrixCodeRainGlyphModeKindSymbols:
            return (uint8_t)(MatrixCodeRainSymbolsStart +
                floor(MatrixCodeRainNextRandom(&_rngState) * MatrixCodeRainSymbolsCount));
        default:
            break;
    }

    static const double weights[] = {0.8, 0.11, 0.05, 0.04};
    static const NSInteger starts[] = {
        0, MatrixCodeRainDigitStart, MatrixCodeRainLatinStart, MatrixCodeRainSymbolsStart,
    };
    static const NSInteger counts[] = {
        MatrixCodeRainKatakanaCount, MatrixCodeRainDigitCount,
        MatrixCodeRainLatinCount, MatrixCodeRainSymbolsCount,
    };
    double total = 0;
    for (NSUInteger index = 0; index < 4; index++) total += weights[index];
    double selection = MatrixCodeRainNextRandom(&_rngState) * total;
    NSUInteger group = 3;
    for (NSUInteger index = 0; index < 4; index++) {
        selection -= weights[index];
        if (selection < 0) {
            group = index;
            break;
        }
    }
    return (uint8_t)(starts[group] +
        floor(MatrixCodeRainNextRandom(&_rngState) * counts[group]));
}

- (void)spawnStreamInColumn:(NSInteger)column {
    MatrixCodeRainSimulationStorage *storage = _storage;
    MatrixCodeRainSimulationStream stream = {
        .y = -MatrixCodeRainNextRandom(&_rngState) * _config.startRowsAbove,
        .speed = _config.minSpeed + MatrixCodeRainNextRandom(&_rngState) * _config.speedRange,
        .white = MatrixCodeRainNextRandom(&_rngState) < _config.whiteHeadFraction ? 1 : 0,
    };
    MatrixCodeRainAppendStream(&storage->streams[column], stream);
}

- (void)lightHeadAtColumn:(NSInteger)column
                      row:(NSInteger)row
               trailSpeed:(double)trailSpeed {
    MatrixCodeRainSimulationStorage *storage = _storage;
    NSUInteger index = (NSUInteger)row * (NSUInteger)_columns + (NSUInteger)column;
    uint8_t randomGlyph = [self randomGlyphIndex];
    NSInteger target = storage->messageTargets ? storage->messageTargets[index] : -1;
    storage->brightness[index] = 1;
    storage->trailSpeed[index] = (float)trailSpeed;
    storage->glyphOld[index] = storage->glyphNew[index];
    if (target < 0) {
        storage->glyphNew[index] = randomGlyph;
    } else if (_messageScramble > 0 &&
               MatrixCodeRainNextRandom(&_messageRngState) < _messageScramble) {
        storage->glyphNew[index] = randomGlyph;
    } else {
        storage->glyphNew[index] = (uint8_t)target;
    }
    storage->phase[index] = 1;
    if (target >= 0) storage->claimed[index] = 1;
}

- (void)resizeToColumns:(NSInteger)columns rows:(NSInteger)rows {
    NSParameterAssert(columns > 0);
    NSParameterAssert(rows > 0);
    if (columns == _columns && rows == _rows) return;

    MatrixCodeRainSimulationStorage *oldStorage = _storage;
    NSInteger oldColumns = _columns;
    MatrixCodeRainSimulationStorage *newStorage = MatrixCodeRainCreateStorage(columns, rows, _seed);
    NSInteger keptColumns = MIN(oldColumns, columns);
    for (NSInteger column = 0; column < keptColumns; column++) {
        newStorage->streams[column] = oldStorage->streams[column];
        oldStorage->streams[column] = (MatrixCodeRainSimulationStreamList){0};
        newStorage->respawnTimer[column] = oldStorage->respawnTimer[column];
    }
    if (columns > oldColumns) {
        [self seedColumnsFrom:oldColumns to:columns storage:newStorage];
    }

    _storage = newStorage;
    _columns = columns;
    _rows = rows;
    _stateData = [NSMutableData dataWithLength:(NSUInteger)columns * (NSUInteger)rows * 4];
    _messageIntensity = 1;
    _messageScramble = 0;
    MatrixCodeRainDestroyStorage(oldStorage);
}

- (void)reset {
    MatrixCodeRainSimulationStorage *storage = _storage;
    NSUInteger cellCount = (NSUInteger)_columns * (NSUInteger)_rows;
    memset(storage->brightness, 0, cellCount * sizeof(float));
    memset(storage->trailSpeed, 0, cellCount * sizeof(float));
    memset(storage->glyphNew, 0, cellCount * sizeof(uint8_t));
    memset(storage->glyphOld, 0, cellCount * sizeof(uint8_t));
    memset(storage->phase, 0, cellCount * sizeof(float));
    memset(_stateData.mutableBytes, 0, _stateData.length);
    _simulationTime = 0;
    [self seedColumnsFrom:0 to:_columns storage:storage];
    free(storage->messageTargets);
    storage->messageTargets = NULL;
    memset(storage->claimed, 0, cellCount * sizeof(uint8_t));
    _messageIntensity = 1;
    _messageScramble = 0;
}

- (int16_t *)messageTargetBufferFromDictionary:(NSDictionary<NSNumber *, NSNumber *> *)targets {
    NSUInteger cellCount = (NSUInteger)_columns * (NSUInteger)_rows;
    int16_t *buffer = malloc(cellCount * sizeof(int16_t));
    NSCAssert(buffer != NULL, @"Unable to allocate Matrix message targets");
    for (NSUInteger index = 0; index < cellCount; index++) buffer[index] = -1;
    [targets enumerateKeysAndObjectsUsingBlock:^(NSNumber *indexValue, NSNumber *glyphValue, BOOL *stop) {
        (void)stop;
        NSInteger index = indexValue.integerValue;
        if (index >= 0 && (NSUInteger)index < cellCount) {
            buffer[index] = (int16_t)glyphValue.integerValue;
        }
    }];
    return buffer;
}

- (void)setMessageTargets:(NSDictionary<NSNumber *,NSNumber *> *)targets {
    MatrixCodeRainSimulationStorage *storage = _storage;
    free(storage->messageTargets);
    storage->messageTargets = [self messageTargetBufferFromDictionary:targets];
    memset(storage->claimed, 0, (NSUInteger)_columns * (NSUInteger)_rows);
    _messageIntensity = 1;
    _messageScramble = 0;
}

- (void)updateMessageTargets:(NSDictionary<NSNumber *,NSNumber *> *)targets {
    MatrixCodeRainSimulationStorage *storage = _storage;
    if (!storage->messageTargets) {
        [self setMessageTargets:targets];
        return;
    }
    NSUInteger cellCount = (NSUInteger)_columns * (NSUInteger)_rows;
    int16_t *next = [self messageTargetBufferFromDictionary:targets];
    for (NSUInteger index = 0; index < cellCount; index++) {
        if (next[index] != storage->messageTargets[index]) storage->claimed[index] = 0;
    }
    free(storage->messageTargets);
    storage->messageTargets = next;
}

- (void)clearMessageTargets {
    MatrixCodeRainSimulationStorage *storage = _storage;
    NSUInteger cellCount = (NSUInteger)_columns * (NSUInteger)_rows;
    if (storage->messageTargets) {
        for (NSUInteger index = 0; index < cellCount; index++) {
            if (storage->claimed[index]) {
                storage->brightness[index] = (float)(
                    fmax(storage->brightness[index], _config.messageBrightFloor) *
                    _messageIntensity);
            }
        }
    }
    free(storage->messageTargets);
    storage->messageTargets = NULL;
    memset(storage->claimed, 0, cellCount);
    _messageIntensity = 1;
    _messageScramble = 0;
}

- (void)setMessageIntensity:(double)intensity {
    _messageIntensity = MatrixCodeRainClamp(intensity, 0, 1);
}

- (void)setMessageScramble:(double)probability {
    _messageScramble = MatrixCodeRainClamp(probability, 0, 1);
}

- (void)updateWithDeltaTime:(double)deltaTime
                   controls:(NSDictionary<NSString *,id> *)controls {
    NSString *requestedGlyphMode = [controls[@"glyphMode"] isKindOfClass:NSString.class]
        ? controls[@"glyphMode"] : nil;
    if (requestedGlyphMode && ![requestedGlyphMode isEqualToString:_glyphMode]) {
        self.glyphMode = requestedGlyphMode;
    }

    double dt = MatrixCodeRainClamp(deltaTime, 0, 1.0 / 15.0);
    _simulationTime += dt;
    MatrixCodeRainSimulationStorage *storage = _storage;
    NSInteger columns = _columns;
    NSInteger rows = _rows;
    double trailLength = MatrixCodeRainEffectiveTrailLength(controls, rows, _config);
    double decayMultiplier = pow(trailLength, dt / _config.trailLengthScale);
    double trailVariation = MatrixCodeRainClamp(
        MatrixCodeRainControlNumber(controls, @"trailVariation", 1), 0, 1);
    double averageSpeed = _config.minSpeed + _config.speedRange * 0.5;
    double crossfadeStep = dt / _config.crossfadeDuration;
    double synchronization = fmax(0, 1 + _config.globalSyncAmount *
        sin(_simulationTime * _config.globalSyncHz * M_PI * 2));
    double glyphRate = MatrixCodeRainControlNumber(controls, @"glyphRate", 1);
    double mutationChance = 1 - exp(-_config.mutationRate * glyphRate * synchronization * dt);
    double density = MatrixCodeRainControlNumber(controls, @"density", 2) * MatrixCodeRainDensityScale;
    double respawnProbability = 1 - exp(-_config.respawnChance * density * dt);
    double speedMultiplier = MatrixCodeRainControlNumber(controls, @"speed", 1);
    NSInteger maximumStreams = MAX(1, (NSInteger)floor(density + 0.5));
    double gapScale = 1 / density;
    uint8_t *state = _stateData.mutableBytes;

    for (NSInteger column = 0; column < columns; column++) {
        MatrixCodeRainSimulationStreamList *streams = &storage->streams[column];
        storage->respawnTimer[column] = (float)(storage->respawnTimer[column] - dt);
        if (storage->respawnTimer[column] <= 0 &&
            streams->count < (NSUInteger)maximumStreams) {
            if (MatrixCodeRainNextRandom(&_rngState) < respawnProbability &&
                _spawnRateScale > storage->columnGate[column]) {
                [self spawnStreamInColumn:column];
                storage->respawnTimer[column] = (float)((_config.respawnDelayMin +
                    MatrixCodeRainNextRandom(&_rngState) * _config.respawnDelayJitter) * gapScale);
            }
        }

        for (NSInteger streamIndex = (NSInteger)streams->count - 1;
             streamIndex >= 0;
             streamIndex--) {
            MatrixCodeRainSimulationStream *stream = &streams->items[streamIndex];
            NSInteger previousRow = (NSInteger)floor(stream->y);
            stream->y += stream->speed * speedMultiplier * dt;
            NSInteger newRow = (NSInteger)floor(stream->y);
            for (NSInteger row = MAX(previousRow + 1, 0); row <= newRow; row++) {
                if (row < rows) {
                    [self lightHeadAtColumn:column row:row trailSpeed:stream->speed];
                }
            }
            if (stream->y - _config.tailMargin > rows) {
                MatrixCodeRainRemoveStream(streams, (NSUInteger)streamIndex);
            }
        }

        for (NSUInteger streamIndex = 0; streamIndex < streams->count; streamIndex++) {
            MatrixCodeRainSimulationStream stream = streams->items[streamIndex];
            NSInteger headRow = (NSInteger)floor(stream.y);
            if (headRow >= 0 && headRow < rows) {
                storage->headMark[headRow] |= stream.white ? 0b11 : 0b01;
            }
        }

        for (NSInteger row = 0; row < rows; row++) {
            NSUInteger index = (NSUInteger)row * (NSUInteger)columns + (NSUInteger)column;
            NSInteger target = storage->messageTargets ? storage->messageTargets[index] : -1;
            double brightness = storage->brightness[index];
            if (brightness > MatrixCodeRainMinimumBrightness) {
                if (trailVariation == 1) {
                    brightness *= decayMultiplier;
                } else {
                    double streamSpeed = (storage->trailSpeed[index] != 0
                        ? storage->trailSpeed[index] : averageSpeed) * speedMultiplier;
                    double variedSpeed = MatrixCodeRainEffectiveTrailSpeed(
                        streamSpeed, speedMultiplier, trailVariation, _config);
                    brightness *= pow(trailLength,
                        dt * streamSpeed / variedSpeed / _config.trailLengthScale);
                }
                if (brightness < MatrixCodeRainMinimumBrightness) brightness = 0;
                storage->brightness[index] = (float)brightness;
            } else if (brightness != 0) {
                storage->brightness[index] = 0;
                brightness = 0;
            }

            if (storage->phase[index] < 1) {
                storage->phase[index] = (float)fmin(1, storage->phase[index] + crossfadeStep);
            }

            uint8_t mark = storage->headMark[row];
            storage->headMark[row] = 0;
            BOOL isHead = (mark & 0b01) != 0;
            BOOL whiteHead = (mark & 0b10) != 0;
            if (!isHead && brightness > 0.05 &&
                MatrixCodeRainNextRandom(&_rngState) < mutationChance) {
                uint8_t randomGlyph = [self randomGlyphIndex];
                if (target >= 0) {
                    storage->claimed[index] = 1;
                    uint8_t next = _messageScramble > 0 &&
                        MatrixCodeRainNextRandom(&_messageRngState) < _messageScramble
                        ? randomGlyph : (uint8_t)target;
                    if (next != storage->glyphNew[index]) {
                        storage->glyphOld[index] = storage->glyphNew[index];
                        storage->glyphNew[index] = next;
                        storage->phase[index] = 0;
                    }
                } else {
                    storage->glyphOld[index] = storage->glyphNew[index];
                    storage->glyphNew[index] = randomGlyph;
                    storage->phase[index] = 0;
                }
            }

            double packedBrightness = target >= 0 && storage->claimed[index]
                ? fmax(brightness, _config.messageBrightFloor) * _messageIntensity
                : brightness;
            NSUInteger offset = index * 4;
            state[offset] = storage->glyphNew[index];
            state[offset + 1] = (uint8_t)floor(
                MatrixCodeRainClamp(packedBrightness, 0, 1) * 255 + 0.5);
            uint8_t packedPhase = (uint8_t)floor(storage->phase[index] *
                MatrixCodeRainPhaseMask + 0.5) & MatrixCodeRainPhaseMask;
            state[offset + 2] = (isHead ? MatrixCodeRainHeadFlag : 0) |
                (whiteHead ? MatrixCodeRainWhiteHeadFlag : 0) | packedPhase;
            state[offset + 3] = storage->glyphOld[index];
        }
    }
}

- (void)advanceElapsedTime:(double)elapsedTime
                  controls:(NSDictionary<NSString *,id> *)controls {
    if (!isfinite(elapsedTime) || elapsedTime <= 0) return;
    double elapsed = fmin(elapsedTime, 0.25);
    NSInteger steps = (NSInteger)ceil(elapsed / (1.0 / 15.0));
    double deltaTime = elapsed / steps;
    for (NSInteger index = 0; index < steps; index++) {
        [self updateWithDeltaTime:deltaTime controls:controls];
    }
}

- (void)warmUpWithControls:(NSDictionary<NSString *,id> *)controls
                   seconds:(double)seconds
                      step:(double)step {
    if (!isfinite(seconds) || !isfinite(step) || step <= 0) return;
    NSInteger steps = (NSInteger)floor(seconds / step);
    for (NSInteger index = 0; index < steps; index++) {
        [self updateWithDeltaTime:step controls:controls];
    }
}

- (void)warmUpDistributedWithControls:(NSDictionary<NSString *,id> *)controls
                              seconds:(double)seconds
                                 step:(double)step {
    MatrixCodeRainSimulationStorage *storage = _storage;
    double density = MatrixCodeRainControlNumber(controls, @"density", 2) * MatrixCodeRainDensityScale;
    NSInteger streamCount = MAX(1, (NSInteger)floor(density + 0.5));
    double activeChance = MatrixCodeRainClamp(density / (density + 0.6), 0.1, 1);
    double minimumY = -_config.startRowsAbove;
    double spanY = _rows + _config.tailMargin - minimumY;
    double speedMultiplier = fmax(MatrixCodeRainControlNumber(controls, @"speed", 1), 0.1);
    double trailLength = MatrixCodeRainEffectiveTrailLength(controls, _rows, _config);
    double trailVariation = MatrixCodeRainControlNumber(controls, @"trailVariation", 1);

    for (NSInteger column = 0; column < _columns; column++) {
        if (MatrixCodeRainNextRandom(&_rngState) > activeChance) continue;
        for (NSInteger streamIndex = 0; streamIndex < streamCount; streamIndex++) {
            MatrixCodeRainSimulationStream stream = {
                .y = minimumY + MatrixCodeRainNextRandom(&_rngState) * spanY,
                .speed = _config.minSpeed + MatrixCodeRainNextRandom(&_rngState) * _config.speedRange,
                .white = MatrixCodeRainNextRandom(&_rngState) < _config.whiteHeadFraction ? 1 : 0,
            };
            MatrixCodeRainAppendStream(&storage->streams[column], stream);
            NSInteger headRow = MIN((NSInteger)floor(stream.y), _rows - 1);
            for (NSInteger row = headRow; row >= 0; row--) {
                double variedSpeed = MatrixCodeRainEffectiveTrailSpeed(
                    stream.speed * speedMultiplier, speedMultiplier, trailVariation, _config);
                double ageSeconds = (stream.y - row) / variedSpeed;
                double brightness = pow(
                    trailLength, ageSeconds / _config.trailLengthScale);
                if (brightness < MatrixCodeRainMinimumBrightness) break;
                NSUInteger index = (NSUInteger)row * (NSUInteger)_columns + (NSUInteger)column;
                float previous = storage->brightness[index];
                float previousTrailSpeed = storage->trailSpeed[index];
                [self lightHeadAtColumn:column row:row trailSpeed:stream.speed];
                storage->brightness[index] = (float)fmax(previous, brightness);
                if (previous > brightness) storage->trailSpeed[index] = previousTrailSpeed;
            }
        }
    }
    [self updateWithDeltaTime:0 controls:controls];
    [self warmUpWithControls:controls seconds:seconds step:step];
}

- (NSUInteger)activeStreamCountForColumn:(NSInteger)column {
    if (column < 0 || column >= _columns) return 0;
    MatrixCodeRainSimulationStorage *storage = _storage;
    return storage->streams[column].count;
}

@end
