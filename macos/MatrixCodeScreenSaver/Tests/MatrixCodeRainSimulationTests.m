#import <XCTest/XCTest.h>

#import "MatrixCodeRainSimulation.h"

@interface MatrixCodeRainSimulationTests : XCTestCase
@end

@implementation MatrixCodeRainSimulationTests

static NSDictionary<NSString *, id> *MatrixCodeWebGoldenControls(void) {
    return @{
        @"speed": @1,
        @"trailLength": @0.08,
        @"trailVariation": @1,
        @"density": @6,
        @"rampUpMs": @0,
        @"glyphRate": @1,
        @"glyphScale": @1,
        @"glyphMode": @"matrix",
        @"glyphFont": @"matrix",
        @"glow": @1,
        @"leadBrightness": @1.6,
        @"preset": @"classic",
        @"mirror": @YES,
        @"scanlines": @NO,
        @"vignette": @0,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
}

static uint32_t MatrixCodeFNV1aChecksum(NSData *data) {
    const uint8_t *bytes = data.bytes;
    uint32_t hash = 0x811c9dc5U;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= 0x01000193U;
    }
    return hash;
}

- (void)testDefaultConfigurationMatchesWebSimulationConfiguration {
    MatrixCodeRainSimulationConfig config = MatrixCodeRainSimulationDefaultConfig();
    XCTAssertEqualWithAccuracy(config.targetCellPx, 18, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.minSpeed, 3.5, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.speedRange, 8, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.decayPerSecond, 0.08, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.trailLengthScale, 1.2, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.mutationRate, 1.6, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.crossfadeDuration, 0.09, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.whiteHeadFraction, 0.2, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.respawnChance, 1.1, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.respawnDelayMin, 0.15, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.respawnDelayJitter, 2.6, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.startRowsAbove, 24, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.tailMargin, 36, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.globalSyncAmount, 0.35, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.globalSyncHz, 1.7, DBL_EPSILON);
    XCTAssertEqualWithAccuracy(config.messageBrightFloor, 0.45, DBL_EPSILON);
}

- (void)testPureRainMatchesWebPackedStateGoldenChecksum {
    // Shared with test/rainSimGolden.test.ts. Matching this checksum requires
    // every packed byte and every preceding PRNG draw to match the web sim.
    MatrixCodeRainSimulation *simulation =
        [[MatrixCodeRainSimulation alloc] initWithColumns:40 rows:60 seed:0xc0ffeeU];
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    [simulation warmUpWithControls:controls seconds:3 step:1.0 / 60.0];
    for (NSUInteger frame = 0; frame < 300; frame++) {
        [simulation updateWithDeltaTime:1.0 / 60.0 controls:controls];
    }

    XCTAssertEqual(simulation.stateData.length, (NSUInteger)(40 * 60 * 4));
    XCTAssertEqual(MatrixCodeFNV1aChecksum(simulation.stateData), 437809828U);
}

- (void)testMessageFadeAndScrambleMatchWebPackedStateGoldenChecksum {
    // Shared with test/rainSimGolden.test.ts, including the separate message
    // PRNG that must not perturb ambient rain randomness.
    MatrixCodeRainSimulation *simulation =
        [[MatrixCodeRainSimulation alloc] initWithColumns:24 rows:40 seed:12345U];
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    [simulation warmUpWithControls:controls seconds:2 step:1.0 / 60.0];
    NSInteger row = 20;
    NSMutableDictionary<NSNumber *, NSNumber *> *targets = [NSMutableDictionary dictionary];
    for (NSInteger index = 0; index < 5; index++) {
        targets[@(row * simulation.columns + 3 + index)] = @(99 + index);
    }
    [simulation setMessageTargets:targets];
    for (NSUInteger frame = 0; frame < 250; frame++) {
        [simulation setMessageIntensity:0.6];
        [simulation setMessageScramble:0.3];
        [simulation updateWithDeltaTime:1.0 / 60.0 controls:controls];
    }

    XCTAssertTrue(simulation.hasMessageTargets);
    XCTAssertEqual(MatrixCodeFNV1aChecksum(simulation.stateData), 3260864663U);
}

- (void)testResizePreservesStreamsAndReplacesCellState {
    MatrixCodeRainSimulation *simulation =
        [[MatrixCodeRainSimulation alloc] initWithColumns:12 rows:18 seed:2468U];
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    [simulation warmUpWithControls:controls seconds:8 step:1.0 / 60.0];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    for (NSInteger column = 0; column < simulation.columns; column++) {
        [counts addObject:@([simulation activeStreamCountForColumn:column])];
    }

    [simulation setMessageTargets:@{@10: @101}];
    [simulation resizeToColumns:16 rows:11];

    XCTAssertEqual(simulation.columns, 16);
    XCTAssertEqual(simulation.rows, 11);
    XCTAssertEqual(simulation.stateData.length, (NSUInteger)(16 * 11 * 4));
    XCTAssertFalse(simulation.hasMessageTargets);
    for (NSInteger column = 0; column < 12; column++) {
        XCTAssertEqual([simulation activeStreamCountForColumn:column],
                       counts[(NSUInteger)column].unsignedIntegerValue);
    }
    const uint8_t *bytes = simulation.stateData.bytes;
    for (NSUInteger index = 0; index < simulation.stateData.length; index++) {
        XCTAssertEqual(bytes[index], (uint8_t)0);
    }
}

- (void)testResetEmptiesStateAndStreamsWithoutChangingGrid {
    MatrixCodeRainSimulation *simulation =
        [[MatrixCodeRainSimulation alloc] initWithColumns:10 rows:14 seed:9876U];
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    [simulation warmUpWithControls:controls seconds:6 step:1.0 / 60.0];
    [simulation setMessageTargets:@{@3: @99}];

    [simulation reset];

    XCTAssertEqual(simulation.columns, 10);
    XCTAssertEqual(simulation.rows, 14);
    XCTAssertEqualWithAccuracy(simulation.simulationTime, 0, DBL_EPSILON);
    XCTAssertFalse(simulation.hasMessageTargets);
    for (NSInteger column = 0; column < simulation.columns; column++) {
        XCTAssertEqual([simulation activeStreamCountForColumn:column], (NSUInteger)0);
    }
    XCTAssertEqual(MatrixCodeFNV1aChecksum(simulation.stateData), 611215237U);
}

- (void)testElapsedTimeAdvanceMatchesWebSubstepPlanner {
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    MatrixCodeRainSimulation *planned =
        [[MatrixCodeRainSimulation alloc] initWithColumns:18 rows:30 seed:112233U];
    MatrixCodeRainSimulation *manual =
        [[MatrixCodeRainSimulation alloc] initWithColumns:18 rows:30 seed:112233U];

    [planned advanceElapsedTime:0.2 controls:controls];
    for (NSUInteger step = 0; step < 3; step++) {
        [manual updateWithDeltaTime:0.2 / 3.0 controls:controls];
    }
    XCTAssertEqualObjects(planned.stateData, manual.stateData);
    XCTAssertEqualWithAccuracy(planned.simulationTime, 0.2, 1e-12);

    [planned advanceElapsedTime:1.0 controls:controls];
    for (NSUInteger step = 0; step < 4; step++) {
        [manual updateWithDeltaTime:0.25 / 4.0 controls:controls];
    }
    XCTAssertEqualObjects(planned.stateData, manual.stateData);
    XCTAssertEqualWithAccuracy(planned.simulationTime, 0.45, 1e-12);
}

- (void)testDistributedWarmUpIsDeterministicAndPopulatesEveryThirdOfTallGrid {
    NSDictionary *controls = MatrixCodeWebGoldenControls();
    MatrixCodeRainSimulation *first =
        [[MatrixCodeRainSimulation alloc] initWithColumns:24 rows:90 seed:13579U];
    MatrixCodeRainSimulation *second =
        [[MatrixCodeRainSimulation alloc] initWithColumns:24 rows:90 seed:13579U];
    [first warmUpDistributedWithControls:controls seconds:2.5 step:1.0 / 60.0];
    [second warmUpDistributedWithControls:controls seconds:2.5 step:1.0 / 60.0];
    XCTAssertEqualObjects(first.stateData, second.stateData);
    XCTAssertEqual(MatrixCodeFNV1aChecksum(first.stateData), 3658144001U);

    const uint8_t *state = first.stateData.bytes;
    NSUInteger litByRegion[3] = {0, 0, 0};
    for (NSInteger row = 0; row < first.rows; row++) {
        for (NSInteger column = 0; column < first.columns; column++) {
            NSUInteger offset = ((NSUInteger)row * (NSUInteger)first.columns +
                                 (NSUInteger)column) * 4;
            if (state[offset + 1] > 0) litByRegion[MIN(2, row / 30)]++;
        }
    }
    for (NSUInteger region = 0; region < 3; region++) {
        XCTAssertGreaterThan(litByRegion[region], (NSUInteger)0);
    }
}

@end
