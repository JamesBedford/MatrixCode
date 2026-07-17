#import "MatrixCodeMessageScheduler.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Native representation of src/config/simConfig.ts. Keep these values in sync
 * with DEFAULT_SIM_CONFIG; the simulation intentionally accepts an injected
 * configuration so deterministic fixtures can exercise non-default tuning.
 */
typedef struct {
    double targetCellPx;
    double minSpeed;
    double speedRange;
    double decayPerSecond;
    double trailLengthScale;
    double mutationRate;
    double crossfadeDuration;
    double whiteHeadFraction;
    double respawnChance;
    double respawnDelayMin;
    double respawnDelayJitter;
    double startRowsAbove;
    double tailMargin;
    double globalSyncAmount;
    double globalSyncHz;
    double messageBrightFloor;
} MatrixCodeRainSimulationConfig;

FOUNDATION_EXPORT MatrixCodeRainSimulationConfig MatrixCodeRainSimulationDefaultConfig(void);

/**
 * Maps the `trailLength` control onto the per-second brightness decay the
 * simulation applies, mirroring RainSim's effectiveTrailLength. Exposed so
 * render-side diagnostics measure the same curve the rain actually uses
 * rather than re-deriving it.
 */
FOUNDATION_EXPORT double MatrixCodeRainEffectiveTrailLengthForControls(
    NSDictionary<NSString *, id> *controls,
    NSInteger rows,
    MatrixCodeRainSimulationConfig config);

/**
 * Direct CPU-side port of the web RainSim. `stateData` uses the same locked
 * RGBA8 cell layout as src/types.ts:
 *
 *   R new glyph, G brightness, B head flags + crossfade phase, A old glyph.
 *
 * The class owns its storage. Callers may retain `stateData`, but a resize
 * replaces the backing object, so render integrations should fetch it again
 * after changing the grid.
 */
@interface MatrixCodeRainSimulation : NSObject <MatrixCodeMessageSink> {
@private
    void *_storage;
    NSMutableData *_stateData;
    NSInteger _columns;
    NSInteger _rows;
    MatrixCodeRainSimulationConfig _config;
    uint32_t _seed;
    uint32_t _rngState;
    uint32_t _messageRngState;
    double _simulationTime;
    double _spawnRateScale;
    double _messageIntensity;
    double _messageScramble;
    NSString *_glyphMode;
}

- (instancetype)initWithColumns:(NSInteger)columns
                            rows:(NSInteger)rows
                            seed:(uint32_t)seed;

- (instancetype)initWithColumns:(NSInteger)columns
                            rows:(NSInteger)rows
                          config:(MatrixCodeRainSimulationConfig)config
                       glyphMode:(NSString *)glyphMode
                            seed:(uint32_t)seed NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSInteger columns;
@property(nonatomic, readonly) NSInteger rows;
@property(nonatomic, readonly) NSData *stateData;
@property(nonatomic, readonly) double simulationTime;
@property(nonatomic) double spawnRateScale;
@property(nonatomic, copy) NSString *glyphMode;
@property(nonatomic, readonly) BOOL hasMessageTargets;

/** Advance one bounded web-compatible simulation step. */
- (void)updateWithDeltaTime:(double)deltaTime
                   controls:(NSDictionary<NSString *, id> *)controls;

/**
 * Apply src/sim/frameSteps.ts semantics to one rendered frame: preserve at
 * most 250 ms of wall time using evenly sized steps no larger than 1/15 s.
 */
- (void)advanceElapsedTime:(double)elapsedTime
                  controls:(NSDictionary<NSString *, id> *)controls;

/** Pre-fill by repeatedly running the ordinary update path. */
- (void)warmUpWithControls:(NSDictionary<NSString *, id> *)controls
                   seconds:(double)seconds
                      step:(double)step;

/** Seed streams throughout a virtual grid, then run the ordinary warm-up. */
- (void)warmUpDistributedWithControls:(NSDictionary<NSString *, id> *)controls
                              seconds:(double)seconds
                                 step:(double)step;

/** Preserve stream/timer state for columns that survive the resize. */
- (void)resizeToColumns:(NSInteger)columns rows:(NSInteger)rows;

/** Match RainSim.reset(): empty cells/streams without rewinding either PRNG. */
- (void)reset;

/** Cell-index -> dedicated message glyph index. */
- (void)setMessageTargets:(NSDictionary<NSNumber *, NSNumber *> *)targets;
- (void)updateMessageTargets:(NSDictionary<NSNumber *, NSNumber *> *)targets;
- (void)clearMessageTargets;
- (void)setMessageIntensity:(double)intensity;
- (void)setMessageScramble:(double)probability;

/** Test/integration diagnostics that do not expose mutable simulation storage. */
- (NSUInteger)activeStreamCountForColumn:(NSInteger)column;

@end

NS_ASSUME_NONNULL_END
