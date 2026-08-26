#import <XCTest/XCTest.h>

#import "MatrixCodeMessageScheduler.h"
#import "MatrixCodeRainSimulation.h"

@interface MatrixCodeMessageRecordingSink : NSObject <MatrixCodeMessageSink>
@property(nonatomic) NSInteger columns;
@property(nonatomic) NSInteger rows;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *targets;
@property(nonatomic) NSUInteger setCount;
@property(nonatomic) NSUInteger updateCount;
@property(nonatomic) NSUInteger clearCount;
@property(nonatomic) double intensity;
@property(nonatomic) double scramble;
@end

@implementation MatrixCodeMessageRecordingSink

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _targets = @{};
    _intensity = 1;
    return self;
}

- (void)setMessageTargets:(NSDictionary<NSNumber *,NSNumber *> *)targets {
    self.targets = targets;
    self.setCount++;
}

- (void)updateMessageTargets:(NSDictionary<NSNumber *,NSNumber *> *)targets {
    self.targets = targets;
    self.updateCount++;
}

- (void)clearMessageTargets {
    self.targets = @{};
    self.clearCount++;
    self.intensity = 1;
    self.scramble = 0;
}

- (void)setMessageIntensity:(double)intensity {
    _intensity = intensity;
}

- (void)setMessageScramble:(double)probability {
    _scramble = probability;
}

@end

@interface MatrixCodeMessageSchedulerTests : XCTestCase
@end

@implementation MatrixCodeMessageSchedulerTests

static NSDictionary<NSString *, id> *MatrixCodeMessageDocument(NSDictionary *overrides) {
    NSMutableDictionary<NSString *, id> *document = [@{
        @"messages": @[@"HELLO"],
        @"enabled": @YES,
        @"frequencyMs": @1000,
        @"persistenceMs": @500,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @YES,
        @"messageLayout": @"row",
        @"messageDirection": @"topToBottom",
        @"verticalPosition": @0.5,
        @"verticalJitter": @0.25,
        @"horizontalPosition": @0.5,
        @"horizontalJitter": @0,
    } mutableCopy];
    [document addEntriesFromDictionary:overrides ?: @{}];
    return document;
}

static NSArray<MatrixCodeMessageRegion *> *MatrixCodeThreeDisplayRegions(void) {
    return @[
        [[MatrixCodeMessageRegion alloc] initWithColumnStart:0 rowStart:0 columns:30 rows:40],
        [[MatrixCodeMessageRegion alloc] initWithColumnStart:30 rowStart:0 columns:30 rows:40],
        [[MatrixCodeMessageRegion alloc] initWithColumnStart:60 rowStart:0 columns:30 rows:40],
    ];
}

static void MatrixCodeFixtureFeed(uint32_t *hash, uint32_t value) {
    for (NSUInteger shift = 0; shift < 32; shift += 8) {
        *hash ^= (value >> shift) & 0xffU;
        *hash *= 0x01000193U;
    }
}

- (void)testFixedSeedAndDedicatedMessageGlyphIndicesMatchWeb {
    XCTAssertEqual(MatrixCodeMessageSchedulerSeed, 0x5eed1eU);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"A"), 99);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"Z"), 124);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"a"), 125);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"z"), 150);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"0"), 151);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"9"), 160);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"="), 161);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"'"), 172);
    XCTAssertEqual(MatrixCodeMessageGlyphIndexForCharacter(@"@"), NSNotFound);
}

- (void)testMessageDocumentSanitizerMatchesWebTypeChecksLimitsAndDefaults {
    NSString *longMessage = [@"" stringByPaddingToLength:140
                                              withString:@"X"
                                         startingAtIndex:0];
    NSDictionary *sanitized = MatrixCodeSanitizeMessagesDocument(@{
        @"messages": @[@"  ", @42, @" KEEP ", longMessage],
        @"enabled": @2,
        @"frequencyMs": @YES,
        @"persistenceMs": @(-10),
        @"appearMs": @(INFINITY),
        @"disappearMs": @700000,
        @"flickerOut": @NO,
        @"brightnessFade": @YES,
        @"messageLayout": @"diagonal",
        @"messageDirection": @"bottomToTop",
        @"verticalPosition": @(-1),
        @"verticalJitter": @2,
        @"horizontalPosition": @2,
        @"horizontalJitter": @(-1),
    });

    NSArray<NSString *> *messages = sanitized[@"messages"];
    XCTAssertEqual(messages.count, (NSUInteger)2);
    XCTAssertEqualObjects(messages[0], @" KEEP ");
    XCTAssertEqual(((NSString *)messages[1]).length, (NSUInteger)120);
    XCTAssertFalse([sanitized[@"enabled"] boolValue]);
    XCTAssertEqualObjects(sanitized[@"frequencyMs"], @8000);
    XCTAssertEqualObjects(sanitized[@"persistenceMs"], @500);
    XCTAssertEqualObjects(sanitized[@"appearMs"], @4000);
    XCTAssertEqualObjects(sanitized[@"disappearMs"], @600000);
    XCTAssertFalse([sanitized[@"flickerOut"] boolValue]);
    XCTAssertTrue([sanitized[@"brightnessFade"] boolValue]);
    XCTAssertEqualObjects(sanitized[@"messageLayout"], @"row");
    XCTAssertEqualObjects(sanitized[@"messageDirection"], @"bottomToTop");
    XCTAssertEqualObjects(sanitized[@"verticalPosition"], @0);
    XCTAssertEqualObjects(sanitized[@"verticalJitter"], @1);
    XCTAssertEqualObjects(sanitized[@"horizontalPosition"], @1);
    XCTAssertEqualObjects(sanitized[@"horizontalJitter"], @0);
}

- (void)testMessageDocumentAxisDefaultsAndExplicitSavedValues {
    NSDictionary *defaults = MatrixCodeSanitizeMessagesDocument(@{});
    XCTAssertEqualObjects(defaults[@"verticalPosition"], @0.5);
    XCTAssertEqualObjects(defaults[@"horizontalPosition"], @0.5);
    XCTAssertEqualObjects(defaults[@"horizontalJitter"], @0);

    NSDictionary *saved = MatrixCodeSanitizeMessagesDocument(@{
        @"verticalPosition": @0.475,
        @"horizontalPosition": @0.125,
        @"horizontalJitter": @0.75,
    });
    XCTAssertEqualObjects(saved[@"verticalPosition"], @0.475);
    XCTAssertEqualObjects(saved[@"horizontalPosition"], @0.125);
    XCTAssertEqualObjects(saved[@"horizontalJitter"], @0.75);
}

- (void)testRowLayoutCentersOneCopyInEveryRegion {
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 90;
    sink.rows = 40;
    NSDictionary *document = MatrixCodeMessageDocument(@{
        @"messages": @[@"AB"],
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
    });
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:document
                                   regions:MatrixCodeThreeDisplayRegions()];

    XCTAssertEqual(sink.targets.count, (NSUInteger)6);
    for (NSNumber *startValue in @[@14, @44, @74]) {
        NSInteger start = startValue.integerValue;
        XCTAssertEqualObjects(sink.targets[@(20 * 90 + start)], @99);
        XCTAssertEqualObjects(sink.targets[@(20 * 90 + start + 1)], @100);
    }
}

- (void)testRowLayoutHorizontalPositionAnchorsMessageWithinRegion {
    MatrixCodeMessageRegion *region = [[MatrixCodeMessageRegion alloc]
        initWithColumnStart:5 rowStart:2 columns:10 rows:5];

    for (NSNumber *position in @[@0, @1]) {
        MatrixCodeMessageScheduler *scheduler =
            [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
        MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
        sink.columns = 20;
        sink.rows = 10;
        [scheduler previewOneAtTimeMilliseconds:0
                                          sink:sink
                                      document:MatrixCodeMessageDocument(@{
                                          @"messages": @[@"AB"],
                                          @"verticalPosition": @0,
                                          @"verticalJitter": @0,
                                          @"horizontalPosition": position,
                                      })
                                       regions:@[region]];

        NSInteger startColumn = position.doubleValue == 0 ? 5 : 13;
        XCTAssertEqualObjects(sink.targets[@(2 * 20 + startColumn)], @99);
        XCTAssertEqualObjects(sink.targets[@(2 * 20 + startColumn + 1)], @100);
    }
}

- (void)testRowLayoutHorizontalJitterStaysWithinLegalStartRange {
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 10;
    sink.rows = 5;
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"AB"],
                                      @"verticalPosition": @0,
                                      @"verticalJitter": @0,
                                      @"horizontalPosition": @1,
                                      @"horizontalJitter": @1,
                                  })];

    NSInteger startColumn = [sink.targets allKeysForObject:@99].firstObject.integerValue;
    XCTAssertGreaterThanOrEqual(startColumn, (NSInteger)4);
    XCTAssertLessThanOrEqual(startColumn, (NSInteger)8);
    XCTAssertEqualObjects(sink.targets[@(startColumn + 1)], @100);
}

- (void)testDropLayoutSupportsBothDirectionsAndSpaces {
    MatrixCodeMessageRecordingSink *topSink = [[MatrixCodeMessageRecordingSink alloc] init];
    topSink.columns = 21;
    topSink.rows = 11;
    MatrixCodeMessageScheduler *top = [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    [top previewOneAtTimeMilliseconds:0
                                sink:topSink
                            document:MatrixCodeMessageDocument(@{
                                @"messages": @[@"A B"],
                                @"messageLayout": @"drop",
                                @"messageDirection": @"topToBottom",
                                @"verticalPosition": @0.5,
                                @"verticalJitter": @0,
                            })];
    XCTAssertEqual(topSink.targets.count, (NSUInteger)2);
    XCTAssertEqualObjects(topSink.targets[@(4 * 21 + 10)], @99);
    XCTAssertEqualObjects(topSink.targets[@(6 * 21 + 10)], @100);

    MatrixCodeMessageRecordingSink *bottomSink = [[MatrixCodeMessageRecordingSink alloc] init];
    bottomSink.columns = 21;
    bottomSink.rows = 11;
    MatrixCodeMessageScheduler *bottom = [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    [bottom previewOneAtTimeMilliseconds:0
                                   sink:bottomSink
                               document:MatrixCodeMessageDocument(@{
                                   @"messages": @[@"ABC"],
                                   @"messageLayout": @"drop",
                                   @"messageDirection": @"bottomToTop",
                                   @"verticalPosition": @0.5,
                                   @"verticalJitter": @0,
                               })];
    XCTAssertEqualObjects(bottomSink.targets[@(4 * 21 + 10)], @101);
    XCTAssertEqualObjects(bottomSink.targets[@(5 * 21 + 10)], @100);
    XCTAssertEqualObjects(bottomSink.targets[@(6 * 21 + 10)], @99);
}

- (void)testDropLayoutPositionsBothAxesWithinLegalRegionStarts {
    MatrixCodeMessageRegion *region = [[MatrixCodeMessageRegion alloc]
        initWithColumnStart:5 rowStart:2 columns:10 rows:8];
    MatrixCodeMessageRecordingSink *topLeftSink = [[MatrixCodeMessageRecordingSink alloc] init];
    topLeftSink.columns = 20;
    topLeftSink.rows = 12;
    MatrixCodeMessageScheduler *topLeft = [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    [topLeft previewOneAtTimeMilliseconds:0
                                    sink:topLeftSink
                                document:MatrixCodeMessageDocument(@{
                                    @"messages": @[@"A B"],
                                    @"messageLayout": @"drop",
                                    @"verticalPosition": @0,
                                    @"verticalJitter": @0,
                                    @"horizontalPosition": @0,
                                })
                                 regions:@[region]];
    XCTAssertEqualObjects(topLeftSink.targets[@(2 * 20 + 5)], @99);
    XCTAssertEqualObjects(topLeftSink.targets[@(4 * 20 + 5)], @100);

    MatrixCodeMessageRecordingSink *bottomRightSink = [[MatrixCodeMessageRecordingSink alloc] init];
    bottomRightSink.columns = 20;
    bottomRightSink.rows = 12;
    MatrixCodeMessageScheduler *bottomRight = [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    [bottomRight previewOneAtTimeMilliseconds:0
                                        sink:bottomRightSink
                                    document:MatrixCodeMessageDocument(@{
                                        @"messages": @[@"A B"],
                                        @"messageLayout": @"drop",
                                        @"verticalPosition": @1,
                                        @"verticalJitter": @0,
                                        @"horizontalPosition": @1,
                                    })
                                     regions:@[region]];
    XCTAssertEqualObjects(bottomRightSink.targets[@(7 * 20 + 14)], @99);
    XCTAssertEqualObjects(bottomRightSink.targets[@(9 * 20 + 14)], @100);
}

- (void)testLayoutCountsUnicodeCodePointsRatherThanUTF16CodeUnits {
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 5;
    sink.rows = 3;
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"A😀B"],
                                      @"verticalPosition": @0,
                                      @"verticalJitter": @0,
                                  })];

    XCTAssertEqual(sink.targets.count, (NSUInteger)2);
    XCTAssertEqualObjects(sink.targets[@1], @99);
    XCTAssertEqualObjects(sink.targets[@3], @100);
}

- (void)testFractionalRegionsUseWebFloorCeilNormalization {
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 20;
    sink.rows = 10;
    MatrixCodeMessageRegion *region =
        [[MatrixCodeMessageRegion alloc] initWithColumnStart:-2.4
                                                   rowStart:1.2
                                                    columns:12.1
                                                       rows:7.1];
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"AB"],
                                      @"verticalPosition": @0.5,
                                      @"verticalJitter": @0,
                                  })
                                   regions:@[region]];

    XCTAssertEqualObjects(sink.targets[@(5 * 20 + 4)], @99);
    XCTAssertEqualObjects(sink.targets[@(5 * 20 + 5)], @100);
}

- (void)testDynamicResolutionUsesTargetUpdatesWithoutMovingPlacement {
    __block NSInteger tick = 0;
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc]
            initWithSeed:4
            glyphIndexResolver:nil
            textResolver:^NSString *(NSString *rawText) {
                (void)rawText;
                return [NSString stringWithFormat:@"T%ld", (long)tick];
            }];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 20;
    sink.rows = 40;
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"m"],
                                      @"persistenceMs": @100000,
                                  })];
    NSArray<NSNumber *> *before = [sink.targets.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    [scheduler updateAtTimeMilliseconds:1000 sink:sink];
    XCTAssertEqual(sink.updateCount, (NSUInteger)0);
    tick = 2;
    [scheduler updateAtTimeMilliseconds:2000 sink:sink];

    XCTAssertEqual(sink.setCount, (NSUInteger)1);
    XCTAssertEqual(sink.updateCount, (NSUInteger)1);
    XCTAssertEqualObjects([sink.targets.allKeys sortedArrayUsingSelector:@selector(compare:)],
                          before);
}

- (void)testLiveTokenLengthRecomputesLegalHorizontalStartWithoutNewPlacement {
    __block NSString *display = @"AB";
    MatrixCodeMessageScheduler *scheduler = [[MatrixCodeMessageScheduler alloc]
        initWithSeed:4
        glyphIndexResolver:nil
        textResolver:^NSString *(NSString *rawText) {
            (void)rawText;
            return display;
        }];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 10;
    sink.rows = 5;
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"TOKEN"],
                                      @"persistenceMs": @100000,
                                      @"verticalPosition": @0,
                                      @"verticalJitter": @0,
                                      @"horizontalPosition": @1,
                                      @"horizontalJitter": @1,
                                  })];
    XCTAssertEqualObjects(sink.targets[@5], @99);
    XCTAssertEqualObjects(sink.targets[@6], @100);

    display = @"ABCDE";
    [scheduler updateAtTimeMilliseconds:1000 sink:sink];
    XCTAssertEqual(sink.updateCount, (NSUInteger)1);
    XCTAssertEqualObjects(sink.targets[@3], @99);
    XCTAssertEqualObjects(sink.targets[@7], @103);
}

- (void)testBrightnessAndScrambleEnvelopesMatchWebPhaseBoundaries {
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 40;
    sink.rows = 40;
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:sink
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"NEO"],
                                      @"persistenceMs": @1000,
                                      @"appearMs": @2000,
                                      @"disappearMs": @2000,
                                      @"flickerOut": @YES,
                                  })];
    XCTAssertEqualWithAccuracy(sink.intensity, 0, 1e-12);
    XCTAssertEqualWithAccuracy(sink.scramble, 1, 1e-12);
    [scheduler updateAtTimeMilliseconds:1000 sink:sink];
    XCTAssertEqualWithAccuracy(sink.intensity, 0.5, 1e-12);
    XCTAssertEqualWithAccuracy(sink.scramble, 0.5, 1e-12);
    [scheduler updateAtTimeMilliseconds:2500 sink:sink];
    XCTAssertEqualWithAccuracy(sink.intensity, 1, 1e-12);
    XCTAssertEqualWithAccuracy(sink.scramble, 0, 1e-12);
    [scheduler updateAtTimeMilliseconds:4000 sink:sink];
    XCTAssertEqualWithAccuracy(sink.intensity, 0.5, 1e-12);
    XCTAssertEqualWithAccuracy(sink.scramble, 0.5, 1e-12);
    [scheduler updateAtTimeMilliseconds:5000 sink:sink];
    XCTAssertEqual(sink.targets.count, (NSUInteger)0);
}

- (void)testTimelineShiftKeepsAnActiveMessageFrozenAcrossPause {
    MatrixCodeMessageScheduler *scheduler = [[MatrixCodeMessageScheduler alloc]
        initWithSeed:MatrixCodeMessageSchedulerSeed];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 30;
    sink.rows = 40;
    NSDictionary *document = MatrixCodeMessageDocument(@{
        @"messages": @[@"HI"],
        @"appearMs": @500,
        @"persistenceMs": @1000,
        @"disappearMs": @500,
    });

    [scheduler previewOneAtTimeMilliseconds:0 sink:sink document:document];
    [scheduler updateAtTimeMilliseconds:400 sink:sink];
    double intensityBeforePause = sink.intensity;

    [scheduler shiftTimelineByMilliseconds:5000];
    [scheduler updateAtTimeMilliseconds:5400 sink:sink];
    XCTAssertGreaterThan(sink.targets.count, (NSUInteger)0);
    XCTAssertEqualWithAccuracy(sink.intensity, intensityBeforePause, 0.00001);

    [scheduler updateAtTimeMilliseconds:7000 sink:sink];
    XCTAssertEqual(sink.targets.count, (NSUInteger)0);
}

- (void)testRainSimulationSatisfiesMessageSinkSurface {
    MatrixCodeRainSimulation *simulation =
        [[MatrixCodeRainSimulation alloc] initWithColumns:20 rows:30 seed:1234U];
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc] initWithSeed:1];
    [scheduler previewOneAtTimeMilliseconds:0
                                      sink:simulation
                                  document:MatrixCodeMessageDocument(@{
                                      @"messages": @[@"AB"],
                                      @"verticalJitter": @0,
                                  })];
    XCTAssertTrue(simulation.hasMessageTargets);
}

- (void)testTimelineMatchesWebCrossLanguageFixture {
    __block NSInteger tick = 0;
    MatrixCodeMessageScheduler *scheduler =
        [[MatrixCodeMessageScheduler alloc]
            initWithSeed:MatrixCodeMessageSchedulerSeed
            glyphIndexResolver:nil
            textResolver:^NSString *(NSString *rawText) {
                return [rawText stringByReplacingOccurrencesOfString:@"{tick}"
                                                           withString:[NSString stringWithFormat:
                                                               @"%ld", (long)tick]];
            }];
    MatrixCodeMessageRecordingSink *sink = [[MatrixCodeMessageRecordingSink alloc] init];
    sink.columns = 48;
    sink.rows = 30;
    [scheduler configureWithDocument:MatrixCodeMessageDocument(@{
        @"messages": @[@"WAKE {tick}", @"NEO", @"A 😀 B"],
        @"frequencyMs": @900,
        @"persistenceMs": @650,
        @"appearMs": @300,
        @"disappearMs": @450,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
        @"verticalPosition": @0.42,
        @"verticalJitter": @0.6,
        @"horizontalPosition": @0.68,
        @"horizontalJitter": @0.4,
    })];

    uint32_t hash = 0x811c9dc5U;
    for (NSInteger now = 0; now <= 16000; now += 125) {
        tick = (now / 1000) % 10;
        if (now == 7000) {
            sink.columns = 52;
            sink.rows = 32;
        }
        NSArray<MatrixCodeMessageRegion *> *regions = now < 7000
            ? @[
                [[MatrixCodeMessageRegion alloc] initWithColumnStart:0.2
                    rowStart:0.4 columns:23.4 rows:29.2],
                [[MatrixCodeMessageRegion alloc] initWithColumnStart:24.2
                    rowStart:0.4 columns:23.4 rows:29.2],
            ]
            : @[
                [[MatrixCodeMessageRegion alloc] initWithColumnStart:-2.4
                    rowStart:1.2 columns:28.1 rows:30.1],
                [[MatrixCodeMessageRegion alloc] initWithColumnStart:26.2
                    rowStart:1.2 columns:28.1 rows:30.1],
            ];
        [scheduler updateAtTimeMilliseconds:now sink:sink regions:regions];
        MatrixCodeFixtureFeed(&hash, (uint32_t)now);
        MatrixCodeFixtureFeed(&hash, (uint32_t)sink.setCount);
        MatrixCodeFixtureFeed(&hash, (uint32_t)sink.updateCount);
        MatrixCodeFixtureFeed(&hash, (uint32_t)sink.clearCount);
        MatrixCodeFixtureFeed(&hash,
            (uint32_t)floor(sink.intensity * 1000000 + 0.5));
        MatrixCodeFixtureFeed(&hash,
            (uint32_t)floor(sink.scramble * 1000000 + 0.5));
        NSArray<NSNumber *> *keys = [sink.targets.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        MatrixCodeFixtureFeed(&hash, (uint32_t)keys.count);
        for (NSNumber *key in keys) {
            MatrixCodeFixtureFeed(&hash, key.unsignedIntValue);
            MatrixCodeFixtureFeed(&hash, sink.targets[key].unsignedIntValue);
        }
    }

    XCTAssertEqual(hash, 539469798U);
    XCTAssertEqual(sink.setCount, (NSUInteger)8);
    XCTAssertEqual(sink.updateCount, (NSUInteger)3);
    XCTAssertEqual(sink.clearCount, (NSUInteger)6);
    XCTAssertEqual(sink.targets.count, (NSUInteger)10);
    XCTAssertEqualObjects(sink.targets[@380], @121);
    XCTAssertEqualObjects(sink.targets[@385], @157);
    XCTAssertEqualObjects(sink.targets[@562], @121);
    XCTAssertEqualObjects(sink.targets[@567], @157);
}

@end
