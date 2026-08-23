#import <XCTest/XCTest.h>

#import "MatrixCodeMessageScheduler.h"
#import "MatrixCodeMetalView.h"
#import "MatrixCodeRainLifecycle.h"
#import "MatrixCodeRainSimulation.h"

@interface MatrixCodeMetalView (MessageTesting)
- (void)updateImageScheduleAtTime:(NSTimeInterval)now
                        globalCols:(NSInteger)globalCols
                        globalRows:(NSInteger)globalRows
                         localCols:(NSInteger)localCols
                         localRows:(NSInteger)localRows;
- (void)updateActiveImageFrameStateAtTime:(NSTimeInterval)now;
- (double)updateMeasuredFramesPerSecondAtTime:(NSTimeInterval)time;
+ (float)diagnosticStepChanceForReferenceRateChance:(float)chance
                                             elapsed:(float)elapsed
                                       referenceRate:(float)referenceRate;
+ (NSInteger)diagnosticBloomLevelCountForQuality:(NSString *)quality;
+ (NSInteger)diagnosticAtlasColumnCountForGlyphCount:(NSInteger)glyphCount;
+ (NSInteger)diagnosticAtlasCellPixels;
+ (NSInteger)diagnosticNormalGridDimensionForPoints:(float)points
                                           glyphScale:(float)glyphScale;
+ (BOOL)diagnosticMessagesUseLocalCoordinatesForSession:(NSDictionary *)session
                                                controls:(NSDictionary *)controls;
@end

@interface MatrixCodeMetalViewTests : XCTestCase
@end

@implementation MatrixCodeMetalViewTests

static NSString *MatrixCodeJSONString(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSUInteger MatrixCodeGreenPixelCount(NSData *frame) {
    const uint8_t *pixels = frame.bytes;
    NSUInteger greenPixels = 0;
    for (NSUInteger index = 0; index + 3 < frame.length; index += 4) {
        uint8_t blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2];
        if (green > 18 && green > red * 2 && green > blue * 2) greenPixels++;
    }
    return greenPixels;
}

static NSUInteger MatrixCodeBrightPackedCellCount(NSData *state) {
    const uint8_t *bytes = state.bytes;
    NSUInteger brightCells = 0;
    for (NSUInteger offset = 0; offset + 3 < state.length; offset += 4) {
        if (bytes[offset + 1] > 0) brightCells++;
    }
    return brightCells;
}

static const uint8_t MatrixCodeTestGlyphF[7] = {
    0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000,
};
static const uint8_t MatrixCodeTestGlyphJ[7] = {
    0b11111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100,
};
static const uint8_t MatrixCodeTestGlyphR[7] = {
    0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001,
};
static const NSUInteger MatrixCodeTestMessageGlyphCount = 3;
static const uint8_t MatrixCodeTestMessageGlyphs[3] = {104, 108, 116};
static const uint8_t *const MatrixCodeTestGlyphPatterns[3] = {
    MatrixCodeTestGlyphF, MatrixCodeTestGlyphJ, MatrixCodeTestGlyphR,
};

static uint64_t MatrixCodeTestGlyphSignature(const uint8_t pattern[7]) {
    uint64_t signature = 0;
    for (NSUInteger row = 0; row < 7; row++) {
        for (NSUInteger column = 0; column < 5; column++) {
            if ((pattern[row] & (1 << (4 - column))) != 0) {
                signature |= 1ULL << (row * 5 + column);
            }
        }
    }
    return signature;
}

static id<MTLTexture> MatrixCodeTestMessageAtlas(id<MTLDevice> device,
                                                 NSUInteger columns,
                                                 NSUInteger rows,
                                                 NSUInteger cellPixels) {
    const NSUInteger width = columns * cellPixels;
    const NSUInteger height = rows * cellPixels;
    const NSUInteger modulePixels = cellPixels / 8;
    const NSUInteger horizontalMargin = (cellPixels - modulePixels * 5) / 2;
    const NSUInteger verticalMargin = (cellPixels - modulePixels * 7) / 2;
    NSMutableData *data = [NSMutableData dataWithLength:width * height];
    uint8_t *pixels = data.mutableBytes;
    for (NSUInteger glyphPosition = 0;
         glyphPosition < MatrixCodeTestMessageGlyphCount;
         glyphPosition++) {
        NSInteger glyph = MatrixCodeTestMessageGlyphs[glyphPosition];
        NSUInteger cellX = ((NSUInteger)glyph % columns) * cellPixels;
        NSUInteger cellY = ((NSUInteger)glyph / columns) * cellPixels;
        for (NSUInteger patternRow = 0; patternRow < 7; patternRow++) {
            for (NSUInteger patternColumn = 0; patternColumn < 5; patternColumn++) {
                if ((MatrixCodeTestGlyphPatterns[glyphPosition][patternRow] &
                     (1 << (4 - patternColumn))) == 0) {
                    continue;
                }
                NSUInteger moduleX =
                    cellX + horizontalMargin + patternColumn * modulePixels;
                NSUInteger moduleY =
                    cellY + verticalMargin + patternRow * modulePixels;
                for (NSUInteger y = moduleY; y < moduleY + modulePixels; y++) {
                    memset(pixels + y * width + moduleX, 255, modulePixels);
                }
            }
        }
    }

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:pixels
               bytesPerRow:width];
    return texture;
}

static uint64_t MatrixCodeRenderedGlyphSignature(NSData *frame,
                                                  NSUInteger frameWidth,
                                                  NSUInteger cellColumn,
                                                  NSUInteger cellRow,
                                                  NSUInteger cellPixels) {
    const uint8_t *pixels = frame.bytes;
    const NSUInteger modulePixels = cellPixels / 8;
    const NSUInteger horizontalMargin = (cellPixels - modulePixels * 5) / 2;
    const NSUInteger verticalMargin = (cellPixels - modulePixels * 7) / 2;
    uint64_t signature = 0;
    for (NSUInteger patternRow = 0; patternRow < 7; patternRow++) {
        for (NSUInteger patternColumn = 0; patternColumn < 5; patternColumn++) {
            NSUInteger x = cellColumn * cellPixels + horizontalMargin +
                patternColumn * modulePixels + modulePixels / 2;
            NSUInteger y = cellRow * cellPixels + verticalMargin +
                patternRow * modulePixels + modulePixels / 2;
            NSUInteger offset = (y * frameWidth + x) * 4;
            uint8_t blue = pixels[offset];
            uint8_t green = pixels[offset + 1];
            uint8_t red = pixels[offset + 2];
            if (MAX(red, MAX(green, blue)) > 20) {
                signature |= 1ULL << (patternRow * 5 + patternColumn);
            }
        }
    }
    return signature;
}

- (void)testTrailSliderUsesExponentialScale {
    const float rows = 72.0f;
    const float averageSpeed = 3.5f + 8.0f * 0.5f;
    float trail = [MatrixCodeMetalView diagnosticEffectiveTrailLength:0.255f
                                                                rows:rows
                                                        speedControl:1.0f];
    float visibleRows = averageSpeed * 1.2f * logf(0.004f) / logf(trail);
    XCTAssertEqualWithAccuracy(visibleRows, rows * sqrtf(3.0f), 0.001f);
}

- (void)testNativeRendererCompilesAndCreatesMetalSurface {
    NSBundle *bundle = [NSBundle bundleForClass:MatrixCodeMetalView.class];
    XCTAssertNotNil([bundle URLForResource:@"default" withExtension:@"metallib"]);

    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[
            @{
                @"id": @"screen-test",
                @"left": @0,
                @"top": @0,
                @"width": @640,
                @"height": @480,
            },
        ],
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:session
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    XCTAssertNotNil(view.device);
}

- (void)testRendererBuildsWebParityPostProcessingPipelines {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:nil
                                      storedValues:@{}];

    XCTAssertNotNil(view);
    XCTAssertNotNil([view valueForKey:@"pipeline"]);
    XCTAssertNotNil([view valueForKey:@"brightPassPipeline"]);
    XCTAssertNotNil([view valueForKey:@"blurPipeline"]);
    XCTAssertNotNil([view valueForKey:@"resamplePipeline"]);
    XCTAssertNotNil([view valueForKey:@"additiveCopyPipeline"]);
    XCTAssertNotNil([view valueForKey:@"compositePipeline"]);
}

- (void)testHighQualityRendererAllocatesWebParityHDRTargetHierarchy {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:nil
                                      storedValues:@{}];
    [view setDensityScale:0 rainElapsed:0];

    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    id<MTLTexture> scene = [view valueForKey:@"sceneTexture"];
    NSArray<id<MTLTexture>> *mainTextures = [view valueForKey:@"bloomMainTextures"];
    NSArray<id<MTLTexture>> *temporaryTextures =
        [view valueForKey:@"bloomTemporaryTextures"];

    XCTAssertNotNil(frame);
    XCTAssertEqual(scene.pixelFormat, MTLPixelFormatRGBA16Float);
    XCTAssertEqual(scene.width, 640);
    XCTAssertEqual(scene.height, 360);
    XCTAssertEqual(mainTextures.count, 3);
    XCTAssertEqual(temporaryTextures.count, 3);
    XCTAssertEqual(mainTextures.firstObject.pixelFormat, MTLPixelFormatRG11B10Float);
    XCTAssertEqual(mainTextures.firstObject.width, 320);
    XCTAssertEqual(mainTextures.firstObject.height, 180);
    XCTAssertEqual(mainTextures.lastObject.width, 80);
    XCTAssertEqual(mainTextures.lastObject.height, 45);
}

- (void)testCompositeEffectsApplyToBackgroundWithoutRain {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[
            @{
                @"id": @"screen-test",
                @"left": @0,
                @"top": @0,
                @"width": @160,
                @"height": @90,
            },
        ],
    };
    NSDictionary *plainControls = @{ @"scanlines": @NO, @"vignette": @0 };
    NSDictionary *effectControls = @{ @"scanlines": @YES, @"vignette": @1 };
    MatrixCodeMetalView *plain = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 160, 90)
              session:session
         storedValues:@{ @"mx-controls": MatrixCodeJSONString(plainControls) }];
    MatrixCodeMetalView *effects = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 160, 90)
              session:session
         storedValues:@{ @"mx-controls": MatrixCodeJSONString(effectControls) }];
    [plain setDensityScale:0 rainElapsed:0];
    [effects setDensityScale:0 rainElapsed:0];

    NSData *plainFrame = [plain diagnosticBGRAFrameWithWidth:160 height:90];
    NSData *effectsFrame = [effects diagnosticBGRAFrameWithWidth:160 height:90];

    XCTAssertNotNil(plainFrame);
    XCTAssertNotNil(effectsFrame);
    XCTAssertNotEqualObjects(plainFrame, effectsFrame);
}

- (void)testRendererUsesWebBloomLevelCounts {
    XCTAssertEqual([MatrixCodeMetalView diagnosticBloomLevelCountForQuality:@"low"], 1);
    XCTAssertEqual([MatrixCodeMetalView diagnosticBloomLevelCountForQuality:@"med"], 2);
    XCTAssertEqual([MatrixCodeMetalView diagnosticBloomLevelCountForQuality:@"high"], 3);
}

- (void)testAdaptiveResolutionScalesOnlyDrawableAndCanBeDisabled {
    MatrixCodeMetalView *adaptive = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];
    [adaptive diagnosticPackedStateWithWidth:320 height:200];
    MatrixCodeRainSimulation *simulation = [adaptive valueForKey:@"rainSimulation"];
    NSInteger columns = simulation.columns;
    CGSize fullDrawableSize = adaptive.drawableSize;
    double adaptiveScale = 1;
    for (NSInteger frame = 0; frame < 200; frame++) {
        adaptiveScale = [adaptive
            diagnosticUpdateAdaptiveResolutionWithFrameMilliseconds:100];
    }

    XCTAssertEqualWithAccuracy(adaptiveScale, 0.5, 0.000001);
    XCTAssertLessThan(adaptive.drawableSize.width, fullDrawableSize.width);
    XCTAssertEqual(simulation.columns, columns);

    MatrixCodeMetalView *disabled = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:@{@"adaptive": @NO}
         storedValues:@{}];
    CGSize disabledDrawableSize = disabled.drawableSize;
    double disabledScale = 1;
    for (NSInteger frame = 0; frame < 200; frame++) {
        disabledScale = [disabled
            diagnosticUpdateAdaptiveResolutionWithFrameMilliseconds:100];
    }
    XCTAssertEqualWithAccuracy(disabledScale, 1, 0.000001);
    XCTAssertEqualWithAccuracy(disabled.drawableSize.width,
                               disabledDrawableSize.width,
                               0.001);
}

- (void)testRendererUsesWebAtlasPackingAndCellResolution {
    XCTAssertEqual([MatrixCodeMetalView diagnosticAtlasCellPixels], 64);
    XCTAssertEqual([MatrixCodeMetalView diagnosticAtlasColumnCountForGlyphCount:173], 14);
    XCTAssertEqual([MatrixCodeMetalView diagnosticAtlasColumnCountForGlyphCount:1], 1);
}

- (void)testAtlasCoverageFallbackLeavesEveryGlyphIndexVisible {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];

    XCTAssertNotNil(view);
    XCTAssertEqual([[view valueForKey:@"atlasBlankCellCount"] unsignedIntegerValue],
                   (NSUInteger)0);
}

- (void)testMessageGlyphsRenderUprightAndLeftToRight {
    const NSUInteger frameDimension = 512;
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @NO,
        @"glyphScale": @4,
        @"glow": @0,
        @"vignette": @0,
        @"scanlines": @NO,
        @"quality": @"low",
        @"mirror": @YES,
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, frameDimension, frameDimension)
              session:@{@"seed": @12345, @"epoch": @1700000000000}
         storedValues:@{@"mx-controls": MatrixCodeJSONString(controls)}];
    XCTAssertNotNil(view);
    [view diagnosticPackedStateWithWidth:frameDimension height:frameDimension];

    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    XCTAssertEqual(simulation.columns, 8);
    XCTAssertEqual(simulation.rows, 8);
    NSUInteger screenCellPixels = frameDimension / (NSUInteger)simulation.columns;
    NSInteger targetRow = 3;
    NSInteger firstTargetColumn = 2;
    NSMutableDictionary<NSNumber *, NSNumber *> *targets = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < MatrixCodeTestMessageGlyphCount; index++) {
        NSInteger cellIndex = targetRow * simulation.columns + firstTargetColumn + index;
        targets[@(cellIndex)] = @(MatrixCodeTestMessageGlyphs[index]);
    }
    [simulation setMessageTargets:targets];

    BOOL resolved = NO;
    for (NSUInteger frameIndex = 0; frameIndex < 2500 && !resolved; frameIndex++) {
        [simulation updateWithDeltaTime:1.0 / 60.0 controls:controls];
        const uint8_t *state = simulation.stateData.bytes;
        resolved = YES;
        for (NSUInteger index = 0; index < MatrixCodeTestMessageGlyphCount; index++) {
            NSUInteger offset = ((NSUInteger)targetRow * (NSUInteger)simulation.columns +
                                 (NSUInteger)(firstTargetColumn + index)) * 4;
            if (state[offset] != MatrixCodeTestMessageGlyphs[index] ||
                state[offset + 1] == 0) {
                resolved = NO;
                break;
            }
        }
    }
    XCTAssertTrue(resolved, @"Every synthetic message glyph must be claimed before rendering");

    simulation.spawnRateScale = 0;
    NSMutableDictionary *settledControls = [controls mutableCopy];
    settledControls[@"speed"] = @0;
    settledControls[@"glyphRate"] = @0;
    for (NSUInteger frameIndex = 0; frameIndex < 10; frameIndex++) {
        [simulation updateWithDeltaTime:1.0 / 60.0 controls:settledControls];
    }

    NSUInteger atlasColumns = [[view valueForKey:@"atlasColumns"] unsignedIntegerValue];
    NSUInteger atlasRows = [[view valueForKey:@"atlasRows"] unsignedIntegerValue];
    NSUInteger atlasCellPixels =
        (NSUInteger)[MatrixCodeMetalView diagnosticAtlasCellPixels];
    id<MTLTexture> atlas = MatrixCodeTestMessageAtlas(
        view.device, atlasColumns, atlasRows, atlasCellPixels);
    XCTAssertNotNil(atlas);
    [view setValue:atlas forKey:@"atlas"];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:frameDimension
                                                height:frameDimension];
    XCTAssertNotNil(frame);

    for (NSUInteger index = 0; index < MatrixCodeTestMessageGlyphCount; index++) {
        uint64_t actual = MatrixCodeRenderedGlyphSignature(
            frame, frameDimension, (NSUInteger)firstTargetColumn + index,
            (NSUInteger)targetRow, screenCellPixels);
        XCTAssertEqual(actual,
                       MatrixCodeTestGlyphSignature(MatrixCodeTestGlyphPatterns[index]),
                       @"Message glyph %lu must retain its identity and upright orientation",
                       (unsigned long)index);
    }
}

- (void)testNormalGridRoundsAndStretchesLikeWebRenderer {
    XCTAssertEqual([MatrixCodeMetalView diagnosticNormalGridDimensionForPoints:640
                                                                     glyphScale:1],
                   36);
    XCTAssertEqual([MatrixCodeMetalView diagnosticNormalGridDimensionForPoints:1080
                                                                     glyphScale:1],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticNormalGridDimensionForPoints:20
                                                                     glyphScale:10],
                   8);
}

- (void)testMultiDisplayMessagePlacementUsesCapturedSessionMode {
    NSDictionary *multiDisplay = @{ @"screens": @[@{}, @{}] };
    NSDictionary *capturedPerDisplay = @{
        @"screens": @[@{}, @{}],
        @"perDisplayMessages": @YES,
    };
    NSDictionary *capturedVirtualGrid = @{
        @"screens": @[@{}, @{}],
        @"perDisplayMessages": @NO,
    };

    XCTAssertTrue([MatrixCodeMetalView
        diagnosticMessagesUseLocalCoordinatesForSession:capturedPerDisplay
                                              controls:@{ @"vignette": @0 }]);
    XCTAssertFalse([MatrixCodeMetalView
        diagnosticMessagesUseLocalCoordinatesForSession:capturedVirtualGrid
                                              controls:@{ @"vignette": @1 }]);
    XCTAssertTrue([MatrixCodeMetalView
        diagnosticMessagesUseLocalCoordinatesForSession:multiDisplay
                                              controls:@{ @"vignette": @1 }]);
    XCTAssertTrue([MatrixCodeMetalView
        diagnosticMessagesUseLocalCoordinatesForSession:@{ @"screens": @[@{}] }
                                              controls:@{ @"vignette": @1 }]);
}

- (void)testRainControlReloadPreservesUnchangedMessageAndImageTimelines {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:@{ @"mx-controls": MatrixCodeJSONString(@{ @"speed": @1 }) }];
    MatrixCodeMessageScheduler *scheduler = [view valueForKey:@"messageScheduler"];
    NSDictionary *initialMessages = [view valueForKey:@"messages"];
    NSDictionary *activeImage = @{ @"id": @"active-image" };
    NSData *activeImageMask = [@"active-mask" dataUsingEncoding:NSUTF8StringEncoding];
    [view setValue:activeImage forKey:@"activeImage"];
    [view setValue:activeImageMask forKey:@"activeImageMaskData"];
    [view setValue:@2345.5 forKey:@"nextImageFire"];

    [view reloadStoredValues:@{
        @"mx-controls": MatrixCodeJSONString(@{ @"speed": @2 }),
    }];

    XCTAssertEqual([view valueForKey:@"messageScheduler"], scheduler);
    XCTAssertEqualObjects([view valueForKey:@"messages"], initialMessages);
    XCTAssertEqualObjects([view valueForKey:@"activeImage"], activeImage);
    XCTAssertEqualObjects([view valueForKey:@"activeImageMaskData"], activeImageMask);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"nextImageFire"] doubleValue], 2345.5, 0.001);

    [view reloadStoredValues:@{
        @"mx-controls": MatrixCodeJSONString(@{ @"speed": @2 }),
        @"mx-messages": MatrixCodeJSONString(@{ @"enabled": @YES }),
    }];

    XCTAssertEqual([view valueForKey:@"messageScheduler"], scheduler);
    XCTAssertTrue([[[view valueForKey:@"messages"] objectForKey:@"enabled"] boolValue]);
    XCTAssertEqualObjects([view valueForKey:@"activeImage"], activeImage);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"nextImageFire"] doubleValue], 2345.5, 0.001);
}

- (void)testRendererSanitizesMalformedStoredControlsBeforeSimulation {
    NSDictionary *malformed = @{
        @"density": @-5,
        @"speed": @YES,
        @"trailLength": @99,
        @"glyphRate": @"fast",
        @"glyphScale": @0,
        @"glyphMode": @"emoji",
        @"glyphFont": @"fantasy",
        @"quality": @"ultra",
        @"mirror": @1,
        @"scanlines": @"yes",
        @"vignette": @YES,
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{ @"mx-controls": MatrixCodeJSONString(malformed) }];
    NSDictionary *controls = [view valueForKey:@"controls"];

    XCTAssertEqualWithAccuracy([controls[@"density"] doubleValue], 0.1, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"speed"] doubleValue], 1, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"trailLength"] doubleValue], 0.5, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"glyphRate"] doubleValue], 1, 0.0001);
    XCTAssertEqualWithAccuracy([controls[@"glyphScale"] doubleValue], 0.5, 0.0001);
    XCTAssertEqualObjects(controls[@"glyphMode"], @"matrix");
    XCTAssertEqualObjects(controls[@"glyphFont"], @"matrix");
    XCTAssertEqualObjects(controls[@"quality"], @"high");
    XCTAssertTrue([controls[@"mirror"] boolValue]);
    XCTAssertFalse([controls[@"scanlines"] boolValue]);
    XCTAssertEqualWithAccuracy([controls[@"vignette"] doubleValue], 0.42, 0.0001);
    XCTAssertNotNil([view diagnosticPackedStateWithWidth:320 height:200]);
}

- (void)testTokenTimelineShiftSurvivesSettingsReloadAndMultiKeepsEpoch {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:@{@"epoch": @1700000000000}
         storedValues:@{}];
    [view setTokenTimelineStartDate:[NSDate dateWithTimeIntervalSince1970:2000]];
    [view restartDeterministicRainFromEmpty:NO];
    XCTAssertEqualWithAccuracy([[view valueForKey:@"imageEpochSeconds"] doubleValue],
                               2000, 0.000001);
    [view shiftTokenTimelineBy:12.5];
    XCTAssertEqualWithAccuracy([[view valueForKey:@"imageEpochSeconds"] doubleValue],
                               2012.5, 0.000001);
    [view reloadStoredValues:@{
        @"mx-controls": MatrixCodeJSONString(@{@"speed": @2}),
    }];
    NSDate *reloadedStart = [[view valueForKey:@"tokenResolver"]
        valueForKey:@"runStartDate"];
    XCTAssertEqualWithAccuracy(reloadedStart.timeIntervalSince1970, 2012.5, 0.000001);

    NSArray *screens = @[
        @{@"id": @"left", @"left": @0, @"top": @0,
          @"width": @320, @"height": @200},
        @{@"id": @"right", @"left": @320, @"top": @0,
          @"width": @320, @"height": @200},
    ];
    MatrixCodeMetalView *multi = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:@{@"epoch": @1700000000000,
                        @"currentScreenId": @"left",
                        @"screens": screens}
         storedValues:@{}];
    [multi setTokenTimelineStartDate:[NSDate dateWithTimeIntervalSince1970:2000]];
    [multi shiftTokenTimelineBy:12.5];
    NSDate *multiStart = [[multi valueForKey:@"tokenResolver"]
        valueForKey:@"runStartDate"];
    XCTAssertEqualWithAccuracy(multiStart.timeIntervalSince1970,
                               1700000000,
                               0.000001);
}

- (void)testStandaloneGeometryTracksViewResizeBeforeRendering {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)
                                           session:nil
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualWidth"] floatValue], 800, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualHeight"] floatValue], 500, 0.001);

    [view setFrameSize:NSMakeSize(1920, 1200)];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:1920 height:1200];

    XCTAssertNotNil(frame);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualWidth"] floatValue], 1920, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"virtualHeight"] floatValue], 1200, 0.001);
}

- (void)testNativeRendererUsesDisplayMaximumFramePacingAndPausesWhenInactive {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                           session:nil
                                      storedValues:@{}];
    XCTAssertNotNil(view);
    NSInteger expected = [MatrixCodeMetalView maximumFramesPerSecondForScreen:NSScreen.mainScreen];
    XCTAssertEqual(view.preferredFramesPerSecond, expected);
    XCTAssertTrue(view.isPaused);

    [view setAnimationActive:YES];
    XCTAssertFalse(view.isPaused);

    [view setAnimationActive:NO];
    XCTAssertTrue(view.isPaused);
}

- (void)testAnimationTransitionsPreserveMeasuredFPSContinuity {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];
    [view setValue:@(1000.0 / 59.94) forKey:@"fpsEmaMs"];
    [view setValue:@59.94 forKey:@"measuredFramesPerSecond"];

    [view setAnimationActive:YES];
    [view setAnimationActive:NO];
    [view setAnimationActive:YES];

    XCTAssertEqualWithAccuracy([[view valueForKey:@"fpsEmaMs"] doubleValue],
                               1000.0 / 59.94,
                               0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"measuredFramesPerSecond"] doubleValue],
                               59.94,
                               0.000001);
    XCTAssertGreaterThan([[view valueForKey:@"lastMeasuredFrameTimeSeconds"] doubleValue], 0);
}

- (void)testAnimationTransitionsDiscardStaleNormalFrameTimestamps {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];
    [view diagnosticPackedStateWithWidth:320 height:200];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    NSTimeInterval simulationTime = simulation.simulationTime;
    [view setValue:@YES forKey:@"hasLastNormalSimulationTime"];
    [view setValue:@1 forKey:@"lastNormalSimulationTimeSeconds"];

    [view setAnimationActive:YES];
    [view setAnimationActive:NO];

    XCTAssertFalse([[view valueForKey:@"hasLastNormalSimulationTime"] boolValue]);
    XCTAssertEqualWithAccuracy(simulation.simulationTime, simulationTime, 0.000001);

    [view setValue:@YES forKey:@"hasLastNormalSimulationTime"];
    [view freezeAnimationAtDate:[NSDate dateWithTimeIntervalSince1970:2000]];
    XCTAssertFalse([[view valueForKey:@"hasLastNormalSimulationTime"] boolValue]);
}

- (void)testFirstActiveFrameAdvancesFromActivationTimestamp {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];
    [view diagnosticPackedStateWithWidth:320 height:200];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    NSTimeInterval simulationTime = simulation.simulationTime;

    [view setAnimationActive:YES];
    NSTimeInterval activationTime =
        [[view valueForKey:@"lastNormalSimulationTimeSeconds"] doubleValue];
    XCTAssertTrue([[view valueForKey:@"hasLastNormalSimulationTime"] boolValue]);
    XCTAssertGreaterThan(activationTime, 0);
    [view setValue:@YES forKey:@"hasCurrentFrameTime"];
    [view setValue:@(activationTime + 1.0 / 60.0) forKey:@"currentFrameTimeSeconds"];

    [view diagnosticPackedStateWithWidth:320 height:200];

    XCTAssertEqualWithAccuracy(simulation.simulationTime,
                               simulationTime + 1.0 / 60.0,
                               0.000001);
}

- (void)testSessionPreferredFramePacingOverridesPerDisplayMaximum {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"preferredFramesPerSecond": @60,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @320, @"height": @200}],
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                           session:session
                                      storedValues:@{}];
    [view configureFramePacingForScreen:NSScreen.mainScreen];

    XCTAssertEqual(view.preferredFramesPerSecond, 60);
}

- (void)testDisplayFramePacingDoesNotStickAtThirtyWhenDisplayReportsHigherRefresh {
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:60
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:120],
                   120);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:120
                                                          displayModeRefreshRate:60
                                                          displayLinkRefreshRate:60],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:0
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:30
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:24
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   60);
    XCTAssertEqual([MatrixCodeMetalView diagnosticFramesPerSecondForScreenMaximum:300
                                                          displayModeRefreshRate:0
                                                          displayLinkRefreshRate:0],
                   240);
}

- (void)testMeasuredFPSUsesFrameIntervalsInsteadOfPreferredRate {
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                                           session:nil
                                      storedValues:@{}];
    view.preferredFramesPerSecond = 120;

    XCTAssertEqualWithAccuracy([view updateMeasuredFramesPerSecondAtTime:1000.0], 0, 0.001);
    for (NSUInteger frame = 1; frame <= 20; frame++) {
        [view updateMeasuredFramesPerSecondAtTime:1000.0 + frame / 60.0];
    }

    XCTAssertEqualWithAccuracy([[view valueForKey:@"measuredFramesPerSecond"] doubleValue],
                               60,
                               0.5);
}

- (void)testImageMutationChanceScalesWithFrameTime {
    float perSixtyHzFrame =
        [MatrixCodeMetalView diagnosticStepChanceForReferenceRateChance:0.54f
                                                                 elapsed:1.0f / 60.0f
                                                           referenceRate:60.0f];
    float perOneTwentyHzFrame =
        [MatrixCodeMetalView diagnosticStepChanceForReferenceRateChance:0.54f
                                                                 elapsed:1.0f / 120.0f
                                                           referenceRate:60.0f];
    float twoOneTwentyHzFrames = 1.0f - powf(1.0f - perOneTwentyHzFrame, 2.0f);

    XCTAssertEqualWithAccuracy(perSixtyHzFrame, 0.54f, 0.0001f);
    XCTAssertEqualWithAccuracy(twoOneTwentyHzFrames, perSixtyHzFrame, 0.0001f);
    XCTAssertLessThan(perOneTwentyHzFrame, perSixtyHzFrame);
}

- (void)testNativeRendererProducesVisibleGreenGlyphPixels {
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @480}],
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:session storedValues:@{}];
    [view setDensityScale:1];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:480];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)100);
}

- (void)testBinaryAndDigitModesUseReadableAtlasDigits {
    NSDictionary *binaryControls = @{@"glyphMode": @"binary", @"glyphFont": @"matrix"};
    NSDictionary *digitControls = @{@"glyphMode": @"digits", @"glyphFont": @"rounded"};
    NSDictionary *matrixControls = @{@"glyphMode": @"matrix", @"glyphFont": @"matrix"};

    NSString *binaryDigitFont = [MatrixCodeMetalView
        diagnosticAtlasPrimaryFontNameForGlyph:@"0"
                                      controls:binaryControls];
    NSString *digitFont = [MatrixCodeMetalView
        diagnosticAtlasPrimaryFontNameForGlyph:@"1"
                                      controls:digitControls];
    NSString *binaryMessageFont = [MatrixCodeMetalView
        diagnosticAtlasPrimaryFontNameForGlyph:@"A"
                                      controls:binaryControls];
    XCTAssertTrue(([@[@"SFMono-Regular", @"Menlo-Regular", @"Consolas",
                       @"LiberationMono", @"CourierNewPSMT"]
        containsObject:binaryDigitFont]));
    XCTAssertEqualObjects(binaryDigitFont, digitFont);
    XCTAssertEqualObjects(binaryDigitFont, binaryMessageFont);
    NSString *matrixFont = [MatrixCodeMetalView
        diagnosticAtlasPrimaryFontNameForGlyph:@"0"
                                      controls:matrixControls];
    XCTAssertTrue(([@[@"HiraKakuProN-W3", @"HiraKakuPro-W3",
                       @"YuGothic-Medium", @"HiraginoSans-W3", @"Menlo-Regular"]
        containsObject:matrixFont]));
    XCTAssertTrue([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"0"
                                                                controls:binaryControls]);
    XCTAssertTrue([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"1"
                                                                controls:digitControls]);
    XCTAssertFalse([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"A"
                                                                 controls:binaryControls]);
    XCTAssertFalse([MatrixCodeMetalView diagnosticDrawsReadableDigitGlyph:@"0"
                                                                 controls:matrixControls]);
}

- (void)testDigitOnlyModesRemapEveryRainAtlasCell {
    NSDictionary *binaryControls = @{@"glyphMode": @"binary"};
    NSDictionary *digitControls = @{@"glyphMode": @"digits"};
    NSDictionary *matrixControls = @{@"glyphMode": @"matrix"};
    const NSUInteger rainGlyphCount = (NSUInteger)MatrixCodeRainGlyphCount();

    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"ｦ"
                                                                             index:0
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"0");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:57
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"1");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"ｦ"
                                                                             index:64
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:digitControls],
                          @"8");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:57
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:matrixControls],
                          @"M");
    XCTAssertEqualObjects([MatrixCodeMetalView diagnosticAtlasDisplayGlyphForGlyph:@"M"
                                                                             index:rainGlyphCount
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                          @"M");

    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:78
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                   0);
    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:87
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:binaryControls],
                   1);
    XCTAssertEqual([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:64
                                                                    rainGlyphCount:rainGlyphCount
                                                                          controls:digitControls],
                   8);
    XCTAssertLessThan([MatrixCodeMetalView diagnosticProceduralDigitValueForGlyphIndex:rainGlyphCount
                                                                        rainGlyphCount:rainGlyphCount
                                                                              controls:binaryControls],
                      0);
}

- (void)testHighDensityOverlapVisualFrameRemainsPopulatedAfterStreamCaching {
    NSDictionary *session = @{
        @"seed": @24680,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @800, @"height": @500}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
        @"trailLength": @0.255,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)
                                           session:session
                                      storedValues:@{@"mx-controls": MatrixCodeJSONString(controls)}];
    [view setDensityScale:1 rainElapsed:12.5];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:800 height:500];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)1000,
                         @"High-density overlap render should remain visibly populated");
}

- (void)testReducedMotionTransitionWarmsCurrentFullDensitySimulations {
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:@{ @"mx-controls": MatrixCodeJSONString(controls) }];
    [view setDensityScale:0 rainElapsed:0];
    NSData *emptyState = [view diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    NSTimeInterval partialSimulationTime = simulation.simulationTime;

    XCTAssertEqual(MatrixCodeBrightPackedCellCount(emptyState), (NSUInteger)0);
    [view prepareReducedMotionFrame];
    NSData *warmedState = [view diagnosticPackedStateWithWidth:640 height:360];

    XCTAssertEqual([view valueForKey:@"rainSimulation"], simulation);
    XCTAssertEqualWithAccuracy(simulation.simulationTime,
                               partialSimulationTime + 2.5,
                               0.000001);
    XCTAssertGreaterThan(MatrixCodeBrightPackedCellCount(warmedState), (NSUInteger)0);
    XCTAssertGreaterThan([[view valueForKey:@"activeOverlapLaneIndexes"] count],
                         (NSUInteger)0);
    XCTAssertFalse([[view valueForKey:@"needsReducedMotionWarmFrame"] boolValue]);
}

- (void)testDeterministicRestartMatchesFreshLoadRampTrajectory {
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    MatrixCodeMetalView *restarted = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:session
         storedValues:@{}];
    [restarted diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeMessageScheduler *oldScheduler = [restarted valueForKey:@"messageScheduler"];
    [restarted setValue:@16 forKey:@"fpsEmaMs"];
    [restarted setValue:@60 forKey:@"measuredFramesPerSecond"];
    [restarted setValue:@1234 forKey:@"lastMeasuredFrameTimeSeconds"];
    [restarted restartDeterministicRainFromEmpty:YES];
    NSData *restartedEmpty = [restarted diagnosticPackedStateWithWidth:640 height:360];

    MatrixCodeMetalView *fresh = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:session
         storedValues:@{}];
    [fresh setDensityScale:0 rainElapsed:0];
    NSData *freshEmpty = [fresh diagnosticPackedStateWithWidth:640 height:360];

    XCTAssertEqualObjects(restartedEmpty, freshEmpty);
    XCTAssertEqual(MatrixCodeBrightPackedCellCount(restartedEmpty), (NSUInteger)0);
    XCTAssertNotEqual([restarted valueForKey:@"messageScheduler"], oldScheduler);
    XCTAssertEqualObjects([[restarted valueForKey:@"messageScheduler"] valueForKey:@"rngState"],
                          [[fresh valueForKey:@"messageScheduler"] valueForKey:@"rngState"]);
    XCTAssertEqualWithAccuracy(restarted.currentRenderScale, 1, 0.000001);
    XCTAssertEqualWithAccuracy([[restarted valueForKey:@"fpsEmaMs"] doubleValue], 0, 0.000001);
    XCTAssertEqualWithAccuracy([[restarted valueForKey:@"measuredFramesPerSecond"] doubleValue],
                               0,
                               0.000001);
    XCTAssertEqualWithAccuracy([[restarted valueForKey:@"lastMeasuredFrameTimeSeconds"] doubleValue],
                               0,
                               0.000001);

    MatrixCodeRainSimulation *restartedSimulation = [restarted valueForKey:@"rainSimulation"];
    MatrixCodeRainSimulation *freshSimulation = [fresh valueForKey:@"rainSimulation"];
    restartedSimulation.spawnRateScale = 1;
    freshSimulation.spawnRateScale = 1;
    NSDictionary *controls = [restarted valueForKey:@"controls"];
    for (NSInteger step = 0; step < 120; step++) {
        [restartedSimulation updateWithDeltaTime:1.0 / 60.0 controls:controls];
        [freshSimulation updateWithDeltaTime:1.0 / 60.0 controls:controls];
    }
    XCTAssertEqualObjects(restartedSimulation.stateData, freshSimulation.stateData);
}

- (void)testDeterministicRestartWithoutLoadRampKeepsFreshWarmState {
    NSDictionary *storedValues = @{
        @"mx-controls": MatrixCodeJSONString(@{@"rampUpMs": @0}),
    };
    MatrixCodeMetalView *restarted = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:storedValues];
    [restarted diagnosticPackedStateWithWidth:640 height:360];
    [restarted restartDeterministicRainFromEmpty:NO];
    NSData *restartedWarm = [restarted diagnosticPackedStateWithWidth:640 height:360];

    MatrixCodeMetalView *fresh = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:storedValues];
    NSData *freshWarm = [fresh diagnosticPackedStateWithWidth:640 height:360];

    XCTAssertEqualObjects(restartedWarm, freshWarm);
    XCTAssertGreaterThan(MatrixCodeBrightPackedCellCount(restartedWarm), (NSUInteger)0);
}

- (void)testActiveDeterministicRestartSeedsFreshFrameTiming {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:@{}];
    [view setAnimationActive:YES];
    [view setValue:@16 forKey:@"fpsEmaMs"];
    [view setValue:@60 forKey:@"measuredFramesPerSecond"];

    [view restartDeterministicRainFromEmpty:NO];

    XCTAssertGreaterThan([[view valueForKey:@"lastMeasuredFrameTimeSeconds"] doubleValue], 0);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"fpsEmaMs"] doubleValue], 0, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"measuredFramesPerSecond"] doubleValue],
                               0,
                               0.000001);
}

- (void)testLowPowerShaderPathRemainsVisibleWithOptionalEffectsDisabled {
    NSDictionary *session = @{
        @"seed": @4242,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @40,
        @"quality": @"low",
        @"glow": @0,
        @"vignette": @0,
        @"scanlines": @NO,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{@"mx-controls": MatrixCodeJSONString(controls)}];
    [view setDensityScale:1 rainElapsed:9.0];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)250,
                         @"Low-power shader branch should keep glyphs visible");
}

- (void)testActiveMessageVisualFrameRendersFromRainSimulationTargets {
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"HELLO {fps}"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-messages": MatrixCodeJSONString(messages),
    }];
    [view diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    [view previewMessageAtDate:NSDate.date];

    XCTAssertTrue(simulation.hasMessageTargets);
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertTrue(simulation.hasMessageTargets);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500);
}

- (void)testDraftMessagePreviewUsesLiveSchedulerAndContinuesDraftSchedule {
    NSDictionary *liveMessages = @{
        @"enabled": @YES,
        @"messages": @[@"LIVE"],
        @"appearMs": @0,
        @"disappearMs": @0,
    };
    NSDictionary *draftMessages = @{
        @"enabled": @YES,
        @"messages": @[@"DRAFT"],
        @"frequencyMs": @500,
        @"persistenceMs": @500,
        @"appearMs": @0,
        @"disappearMs": @0,
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:@{@"mx-messages": MatrixCodeJSONString(liveMessages)}];
    [view diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    NSData *packedBefore = [simulation.stateData copy];
    MatrixCodeMessageScheduler *liveScheduler = [view valueForKey:@"messageScheduler"];
    NSDictionary *liveConfiguration = [[view valueForKey:@"messages"] copy];

    [view previewMessageWithStoredValues:@{
        @"mx-messages": MatrixCodeJSONString(draftMessages),
    } atDate:[NSDate dateWithTimeIntervalSince1970:2000]];

    XCTAssertTrue(simulation.hasMessageTargets);
    XCTAssertEqualObjects(simulation.stateData, packedBefore);
    XCTAssertEqual([view valueForKey:@"messageScheduler"], liveScheduler);
    XCTAssertEqualObjects([view valueForKey:@"messages"], liveConfiguration);

    [view setValue:@YES forKey:@"hasCurrentFrameTime"];
    [view setValue:@2000.6 forKey:@"currentFrameTimeSeconds"];
    [view diagnosticPackedStateWithWidth:640 height:360];
    [view setValue:@NO forKey:@"hasCurrentFrameTime"];

    XCTAssertFalse(simulation.hasMessageTargets);

    [view setValue:@YES forKey:@"hasCurrentFrameTime"];
    [view setValue:@2001.3 forKey:@"currentFrameTimeSeconds"];
    [view diagnosticPackedStateWithWidth:640 height:360];
    [view setValue:@NO forKey:@"hasCurrentFrameTime"];

    XCTAssertTrue(simulation.hasMessageTargets);

    [view reloadStoredValues:@{
        @"mx-messages": MatrixCodeJSONString(liveMessages),
    }];
    NSDictionary *restoredConfiguration =
        [[liveScheduler valueForKey:@"state"] valueForKey:@"configuration"];
    XCTAssertEqualObjects(restoredConfiguration[@"messages"], (@[@"LIVE"]));
    XCTAssertFalse([[view valueForKey:@"messageDraftPreviewActive"] boolValue]);
}

- (void)testSavingDraftMessagePreviewAdoptsDraftSchedule {
    NSDictionary *liveMessages = @{
        @"enabled": @YES,
        @"messages": @[@"LIVE"],
    };
    NSDictionary *draftMessages = @{
        @"enabled": @YES,
        @"messages": @[@"DRAFT"],
        @"frequencyMs": @500,
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 360)
              session:nil
         storedValues:@{@"mx-messages": MatrixCodeJSONString(liveMessages)}];
    [view diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeMessageScheduler *scheduler = [view valueForKey:@"messageScheduler"];

    [view previewMessageWithStoredValues:@{
        @"mx-messages": MatrixCodeJSONString(draftMessages),
    } atDate:[NSDate dateWithTimeIntervalSince1970:2000]];
    [view reloadStoredValues:@{
        @"mx-messages": MatrixCodeJSONString(draftMessages),
    }];

    NSDictionary *savedConfiguration =
        [[scheduler valueForKey:@"state"] valueForKey:@"configuration"];
    XCTAssertEqualObjects(savedConfiguration[@"messages"], (@[@"DRAFT"]));
    XCTAssertEqualObjects([view valueForKey:@"messages"],
                          MatrixCodeSanitizeMessagesDocument(draftMessages));
    XCTAssertFalse([[view valueForKey:@"messageDraftPreviewActive"] boolValue]);
}

- (void)testImageScheduleActivatesStoredMaskAndFadeState {
    const uint8_t bytes[] = {0, 96, 180, 255};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSDictionary *session = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Signal", @"width": @2, @"height": @2,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @1000,
        @"disappearMs": @1000,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
        @"imageScale": @0.75,
        @"imagePlacementJitter": @1,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:session
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSTimeInterval now = 1700000001.0;
    [view updateImageScheduleAtTime:now globalCols:21 globalRows:20 localCols:21 localRows:20];
    [view updateActiveImageFrameStateAtTime:now + 0.5];

    XCTAssertNotNil([view valueForKey:@"activeImage"]);
    XCTAssertEqualObjects([[view valueForKey:@"activeImage"] objectForKey:@"name"], @"Signal");
    XCTAssertEqual([[view valueForKey:@"activeImageWidth"] integerValue], 2);
    XCTAssertEqual([[view valueForKey:@"activeImageHeight"] integerValue], 2);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageStart"] doubleValue], now, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageEnd"] doubleValue], now + 12, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageFrameIntensity"] floatValue], 0.5, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageFrameScramble"] floatValue], 0.5, 0.001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImagePlacementX"] floatValue],
                               0.31529415, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImagePlacementY"] floatValue],
                               0.02486330, 0.000001);
}

- (void)testReducedMotionStaticFrameSuppressesImageScheduleWithoutConsumingIt {
    NSString *mask = [[NSData dataWithBytes:(const uint8_t[]){255} length:1]
        base64EncodedStringWithOptions:0];
    NSDictionary *storedValues = @{
        @"mx-images": MatrixCodeJSONString(@{
            @"images": @[@{ @"name": @"Pixel", @"width": @1, @"height": @1,
                              @"data": mask }],
            @"enabled": @YES,
            @"frequencyMs": @500,
            @"persistenceMs": @500,
            @"appearMs": @0,
            @"disappearMs": @0,
        }),
    };
    NSTimeInterval epoch = 1700000000;
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 240)
              session:@{ @"seed": @1234, @"epoch": @(epoch * 1000.0) }
         storedValues:storedValues];
    if (!view) {
        XCTSkip(@"Metal is unavailable on this test host");
        return;
    }

    [view setReducedMotionEnabled:YES];
    [view updateImageScheduleAtTime:epoch + 2.5
                         globalCols:20
                         globalRows:20
                          localCols:20
                          localRows:20];
    XCTAssertNil([view valueForKey:@"activeImage"]);

    // Suppression must not disable or consume the playlist: normal playback can
    // still activate the same schedule after reduced motion is turned off.
    [view setReducedMotionEnabled:NO];
    [view updateImageScheduleAtTime:epoch + 2.5
                         globalCols:20
                         globalRows:20
                          localCols:20
                          localRows:20];
    XCTAssertNotNil([view valueForKey:@"activeImage"]);
}

- (void)testSingleDisplayPauseShiftFreezesImageScheduleAndRevealEpoch {
    const uint8_t bytes[] = {0, 96, 180, 255};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Signal", @"width": @2, @"height": @2,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @1000,
        @"disappearMs": @1000,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
    };
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 420, 400)
              session:@{
                  @"seed": @13579,
                  @"epoch": @1700000000000,
                  @"currentScreenId": @"screen-test",
                  @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                                  @"width": @420, @"height": @400}],
              }
         storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSTimeInterval activation = 1700000001.0;
    [view updateImageScheduleAtTime:activation
                         globalCols:21 globalRows:20 localCols:21 localRows:20];
    [view updateActiveImageFrameStateAtTime:activation + 0.4];
    float intensityBeforePause = [[view valueForKey:@"activeImageFrameIntensity"] floatValue];
    NSTimeInterval startBeforePause = [[view valueForKey:@"activeImageStart"] doubleValue];
    NSTimeInterval endBeforePause = [[view valueForKey:@"activeImageEnd"] doubleValue];
    NSTimeInterval epochBeforePause = [[view valueForKey:@"imageEpochSeconds"] doubleValue];

    [view shiftTokenTimelineBy:10];
    [view updateActiveImageFrameStateAtTime:activation + 10.4];

    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageStart"] doubleValue],
                               startBeforePause + 10, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageEnd"] doubleValue],
                               endBeforePause + 10, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"imageEpochSeconds"] doubleValue],
                               epochBeforePause + 10, 0.000001);
    XCTAssertEqualWithAccuracy([[view valueForKey:@"activeImageFrameIntensity"] floatValue],
                               intensityBeforePause, 0.000001);
}

- (void)testMultiMonitorImageScheduleUsesSharedFireTime {
    const uint8_t bytes[] = {0, 96, 180, 255};
    NSData *mask = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSArray *screens = @[
        @{@"id": @"left", @"left": @0, @"top": @0, @"width": @420, @"height": @400},
        @{@"id": @"right", @"left": @420, @"top": @0, @"width": @420, @"height": @400},
    ];
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Signal", @"width": @2, @"height": @2,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @1000,
        @"disappearMs": @1000,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
    };
    NSDictionary *leftSession = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"left",
        @"screens": screens,
    };
    NSDictionary *rightSession = @{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"right",
        @"screens": screens,
    };
    MatrixCodeMetalView *left =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:leftSession
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    MatrixCodeMetalView *right =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:rightSession
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];

    [left updateImageScheduleAtTime:1700000001.0
                         globalCols:42 globalRows:20 localCols:21 localRows:20];
    [right updateImageScheduleAtTime:1700000001.0 + 1.0 / 120.0
                          globalCols:42 globalRows:20 localCols:21 localRows:20];

    XCTAssertNotNil([left valueForKey:@"activeImage"]);
    XCTAssertNotNil([right valueForKey:@"activeImage"]);
    XCTAssertEqualWithAccuracy([[left valueForKey:@"activeImageStart"] doubleValue],
                               [[right valueForKey:@"activeImageStart"] doubleValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[left valueForKey:@"activeImageEnd"] doubleValue],
                               [[right valueForKey:@"activeImageEnd"] doubleValue],
                               0.000001);
}

- (void)testMultiMonitorLateStartFastForwardsWithoutReplayingBacklog {
    const uint8_t firstByte = 255;
    const uint8_t secondByte = 128;
    NSData *firstMask = [NSData dataWithBytes:&firstByte length:1];
    NSData *secondMask = [NSData dataWithBytes:&secondByte length:1];
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[
            @{@"name": @"First", @"width": @1, @"height": @1,
              @"data": [firstMask base64EncodedStringWithOptions:0]},
            @{@"name": @"Second", @"width": @1, @"height": @1,
              @"data": [secondMask base64EncodedStringWithOptions:0]},
        ],
        @"frequencyMs": @500,
        @"persistenceMs": @500,
        @"appearMs": @100,
        @"disappearMs": @100,
        @"flickerOut": @YES,
        @"brightnessFade": @YES,
    };
    NSArray *screens = @[
        @{@"id": @"left", @"left": @0, @"top": @0, @"width": @420, @"height": @400},
        @{@"id": @"right", @"left": @420, @"top": @0, @"width": @420, @"height": @400},
    ];
    NSDictionary *session = @{
        @"seed": @(0x2468acU),
        @"epoch": @1700000000000,
        @"currentScreenId": @"left",
        @"screens": screens,
    };
    MatrixCodeMetalView *reference = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 420, 400)
              session:session
         storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    MatrixCodeMetalView *late = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 420, 400)
              session:session
         storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSTimeInterval epoch = 1700000000.0;
    NSTimeInterval now = epoch + 60;

    for (NSUInteger step = 0; step <= 600; step++) {
        [reference updateImageScheduleAtTime:epoch + step * 0.1
                                  globalCols:42 globalRows:20 localCols:21 localRows:20];
    }
    [late updateImageScheduleAtTime:now
                         globalCols:42 globalRows:20 localCols:21 localRows:20];
    [reference updateActiveImageFrameStateAtTime:now];
    [late updateActiveImageFrameStateAtTime:now];

    NSDictionary *referenceActive = [reference valueForKey:@"activeImage"];
    NSDictionary *lateActive = [late valueForKey:@"activeImage"];
    if (lateActive) {
        XCTAssertGreaterThan([[late valueForKey:@"activeImageEnd"] doubleValue], now);
    } else {
        XCTAssertGreaterThan([[late valueForKey:@"nextImageFire"] doubleValue], now);
    }
    XCTAssertEqualObjects(lateActive[@"name"], @"First");
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageStart"] doubleValue] - epoch,
                               59.8733743876, 0.00001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageEnd"] doubleValue] - epoch,
                               60.5733743876, 0.00001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImagePlacementX"] floatValue],
                               0.3110779524, 0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImagePlacementY"] floatValue],
                               0.3646557331, 0.000001);
    XCTAssertEqualObjects(lateActive, referenceActive);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageStart"] doubleValue],
                               [[reference valueForKey:@"activeImageStart"] doubleValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageEnd"] doubleValue],
                               [[reference valueForKey:@"activeImageEnd"] doubleValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"nextImageFire"] doubleValue],
                               [[reference valueForKey:@"nextImageFire"] doubleValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImagePlacementX"] floatValue],
                               [[reference valueForKey:@"activeImagePlacementX"] floatValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImagePlacementY"] floatValue],
                               [[reference valueForKey:@"activeImagePlacementY"] floatValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageFrameIntensity"] floatValue],
                               [[reference valueForKey:@"activeImageFrameIntensity"] floatValue],
                               0.000001);
    XCTAssertEqualWithAccuracy([[late valueForKey:@"activeImageFrameScramble"] floatValue],
                               [[reference valueForKey:@"activeImageFrameScramble"] floatValue],
                               0.000001);
}

- (void)testRendererDropsStoredImagesWithInvalidDimensions {
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[
            @{@"name": @"Empty", @"width": @"wide", @"height": @"tall", @"data": @""},
        ],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)
                                           session:@{
        @"seed": @13579,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @420, @"height": @400}],
    }
                                      storedValues:@{@"mx-images": MatrixCodeJSONString(images)}];
    NSDictionary *sanitizedImages = [view valueForKey:@"images"];
    XCTAssertEqual([sanitizedImages[@"images"] count], (NSUInteger)0);

    [view updateImageScheduleAtTime:1700000100.0
                         globalCols:21
                         globalRows:20
                          localCols:21
                          localRows:20];
    XCTAssertNil([view valueForKey:@"activeImage"]);
}

- (void)testRendererUsesPortableImageDimensionAndCountLimits {
    NSMutableData *legacyMask = [NSMutableData dataWithLength:97];
    NSMutableArray *items = [NSMutableArray arrayWithObject:@{
        @"name": @"Legacy 97", @"width": @97, @"height": @1,
        @"data": [legacyMask base64EncodedStringWithOptions:0],
    }];
    for (NSUInteger index = 0; index < 65; index++) {
        const uint8_t byte = (uint8_t)index;
        NSData *mask = [NSData dataWithBytes:&byte length:1];
        [items addObject:@{
            @"name": [NSString stringWithFormat:@"Portable %02lu", (unsigned long)index],
            @"width": @1, @"height": @1,
            @"data": [mask base64EncodedStringWithOptions:0],
        }];
    }
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 420, 400)
              session:nil
         storedValues:@{ @"mx-images": MatrixCodeJSONString(@{ @"images": items }) }];
    NSArray *sanitized = [[view valueForKey:@"images"] objectForKey:@"images"];

    XCTAssertEqual(sanitized.count, (NSUInteger)64);
    XCTAssertEqualObjects(sanitized.firstObject[@"name"], @"Portable 00");
    XCTAssertEqualObjects(sanitized.lastObject[@"name"], @"Portable 63");
}

- (void)testActiveImageVisualFrameStillRendersAsRain {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    uint8_t *bytes = mask.mutableBytes;
    for (NSUInteger row = 0; row < 8; row++) {
        for (NSUInteger column = 0; column < 8; column++) {
            BOOL diagonal = row == column || row + column == 7;
            bytes[row * 8 + column] = diagonal ? 255 : (uint8_t)(row * 24 + column * 6);
        }
    }
    NSDictionary *session = @{
        @"seed": @24680,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"X", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @0.25,
        @"imagePlacementJitter": @0.75,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-images": MatrixCodeJSONString(images),
    }];
    [view setDensityScale:1 rainElapsed:2.5];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];
    XCTAssertNotNil(frame);
    XCTAssertNotNil([view valueForKey:@"activeImage"]);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500,
                         @"Image-enabled render should remain animated rain, not a blank mask");
}

- (void)testZeroMaskImageDoesNotStampInvisibleRectangle {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    NSDictionary *session = @{
        @"seed": @86420,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"rampUpMs": @0,
        @"glyphRate": @5,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Empty", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @1,
        @"imagePlacementJitter": @0,
    };
    MatrixCodeMetalView *baselineView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
    }];
    MatrixCodeMetalView *imageView =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-images": MatrixCodeJSONString(images),
    }];

    [baselineView setDensityScale:1 rainElapsed:2.5];
    [imageView setDensityScale:1 rainElapsed:2.5];
    NSData *baseline = [baselineView diagnosticBGRAFrameWithWidth:640 height:360];
    NSData *imageFrame = [imageView diagnosticBGRAFrameWithWidth:640 height:360];

    XCTAssertNotNil(baseline);
    XCTAssertNotNil(imageFrame);
    XCTAssertNotNil([imageView valueForKey:@"activeImage"]);
    XCTAssertEqualObjects(imageFrame, baseline);
}

- (void)testNativeImageExtensionDoesNotMutateCanonicalPackedMessageState {
    NSMutableData *mask = [NSMutableData dataWithLength:64];
    memset(mask.mutableBytes, 255, mask.length);
    NSDictionary *session = @{
        @"seed": @97531,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @360}],
    };
    NSDictionary *controls = @{
        @"density": @100,
        @"allowOverlap": @YES,
        @"quality": @"high",
        @"glyphRate": @5,
    };
    NSDictionary *messages = @{
        @"enabled": @YES,
        @"messages": @[@"HELLO"],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"verticalPosition": @0.5,
        @"verticalJitter": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
    };
    NSDictionary *images = @{
        @"enabled": @YES,
        @"images": @[@{@"name": @"Full", @"width": @8, @"height": @8,
                       @"data": [mask base64EncodedStringWithOptions:0]}],
        @"frequencyMs": @500,
        @"persistenceMs": @10000,
        @"appearMs": @0,
        @"disappearMs": @0,
        @"flickerOut": @NO,
        @"brightnessFade": @NO,
        @"imageScale": @1,
        @"imagePlacementJitter": @0,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)
                                           session:session
                                      storedValues:@{
        @"mx-controls": MatrixCodeJSONString(controls),
        @"mx-messages": MatrixCodeJSONString(messages),
        @"mx-images": MatrixCodeJSONString(images),
    }];

    [view diagnosticPackedStateWithWidth:640 height:360];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    MatrixCodeMessageScheduler *scheduler = [view valueForKey:@"messageScheduler"];
    [scheduler previewOneAtTimeMilliseconds:NSDate.date.timeIntervalSince1970 * 1000
                                       sink:simulation
                                   document:messages];
    NSData *packedBefore = [simulation.stateData copy];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:640 height:360];

    XCTAssertNotNil(frame);
    XCTAssertNotNil([view valueForKey:@"activeImage"]);
    XCTAssertTrue(simulation.hasMessageTargets);
    XCTAssertEqualObjects(simulation.stateData, packedBefore);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)500);
}

- (void)testMultiMonitorPanelsExtractExactSlicesOfOneSharedPackedSimulation {
    NSArray *screens = @[
        @{@"id": @"left", @"left": @0, @"top": @0,
          @"width": @360, @"height": @360},
        @{@"id": @"right", @"left": @360, @"top": @0,
          @"width": @360, @"height": @360},
    ];
    NSDictionary *baseSession = @{
        @"seed": @24680,
        @"epoch": @1700000000000,
        @"screens": screens,
    };
    NSMutableDictionary *leftSession = [baseSession mutableCopy];
    leftSession[@"currentScreenId"] = @"left";
    NSMutableDictionary *rightSession = [baseSession mutableCopy];
    rightSession[@"currentScreenId"] = @"right";
    MatrixCodeMetalView *left = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 360, 360)
              session:leftSession
         storedValues:@{}];
    MatrixCodeMetalView *right = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 360, 360)
              session:rightSession
         storedValues:@{}];

    NSData *leftLocal = [left diagnosticPackedStateWithWidth:360 height:360];
    NSData *rightLocal = [right diagnosticPackedStateWithWidth:360 height:360];
    MatrixCodeRainSimulation *leftSimulation = [left valueForKey:@"rainSimulation"];
    MatrixCodeRainSimulation *rightSimulation = [right valueForKey:@"rainSimulation"];

    XCTAssertEqual(leftSimulation.columns, (NSInteger)40);
    XCTAssertEqual(leftSimulation.rows, (NSInteger)20);
    XCTAssertEqualWithAccuracy([[left valueForKey:@"simulationClockSeconds"] doubleValue],
                               2.5,
                               0.000001);
    XCTAssertEqualWithAccuracy([[right valueForKey:@"simulationClockSeconds"] doubleValue],
                               2.5,
                               0.000001);
    XCTAssertEqualObjects(leftSimulation.stateData, rightSimulation.stateData);
    XCTAssertEqual(leftLocal.length, (NSUInteger)(20 * 20 * 4));
    XCTAssertEqual(rightLocal.length, (NSUInteger)(20 * 20 * 4));
    const uint8_t *full = leftSimulation.stateData.bytes;
    const uint8_t *leftBytes = leftLocal.bytes;
    const uint8_t *rightBytes = rightLocal.bytes;
    for (NSUInteger row = 0; row < 20; row++) {
        XCTAssertEqual(memcmp(leftBytes + row * 20 * 4,
                              full + row * 40 * 4,
                              20 * 4),
                       0);
        XCTAssertEqual(memcmp(rightBytes + row * 20 * 4,
                              full + (row * 40 + 20) * 4,
                              20 * 4),
                       0);
    }
}

- (void)testTShapedMultiMonitorWarmStartRendersLeftDisplay {
    NSArray *screens = @[
        @{@"id": @"screen-1", @"left": @0, @"top": @1200,
          @"width": @1710, @"height": @1112},
        @{@"id": @"screen-16", @"left": @-1920, @"top": @1200,
          @"width": @1920, @"height": @1200},
        @{@"id": @"screen-17", @"left": @-112, @"top": @0,
          @"width": @1920, @"height": @1200},
        @{@"id": @"screen-18", @"left": @1710, @"top": @1200,
          @"width": @1920, @"height": @1200},
    ];
    NSDictionary *session = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-16",
        @"screens": screens,
    };
    MatrixCodeMetalView *view =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1920, 1200)
                                           session:session storedValues:@{}];
    [view setDensityScale:1 rainElapsed:0];
    NSData *frame = [view diagnosticBGRAFrameWithWidth:1920 height:1200];
    XCTAssertNotNil(frame);
    XCTAssertGreaterThan(MatrixCodeGreenPixelCount(frame), (NSUInteger)100,
                         @"The left display must not start as an empty virtual-grid slice");
}

- (void)testNormalRendererUsesCanonicalSeedsAndConsumesPackedSimulationState {
    NSDictionary *controls = @{
        @"density": @20,
        @"glyphRate": @5,
        @"allowOverlap": @YES,
        @"quality": @"high",
    };
    NSDictionary *firstSession = @{
        @"seed": @12345,
        @"epoch": @1700000000000,
        @"currentScreenId": @"screen-test",
        @"screens": @[@{@"id": @"screen-test", @"left": @0, @"top": @0,
                        @"width": @640, @"height": @480}],
    };
    NSDictionary *secondSession = @{
        @"seed": @98765,
        @"epoch": @1800000000000,
        @"currentScreenId": @"screen-test",
        @"screens": firstSession[@"screens"],
    };
    NSDictionary *storedValues = @{
        @"mx-controls": MatrixCodeJSONString(controls),
    };
    MatrixCodeMetalView *first =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:firstSession
                                      storedValues:storedValues];
    MatrixCodeMetalView *second =
        [[MatrixCodeMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)
                                           session:secondSession
                                      storedValues:storedValues];

    NSData *firstState = [first diagnosticPackedStateWithWidth:640 height:480];
    NSData *secondState = [second diagnosticPackedStateWithWidth:640 height:480];

    XCTAssertEqual([MatrixCodeMetalView diagnosticNormalRainSeed], (uint32_t)0x1a2b3c);
    XCTAssertEqual([MatrixCodeMetalView diagnosticRainSeedForLane:3],
                   (uint32_t)(0x1a2b3cU ^ (3U * 0x9e3779b9U)));
    XCTAssertEqualObjects(firstState, secondState);
    XCTAssertTrue([first diagnosticRendererConsumesPackedStateWithWidth:640 height:480]);
}

- (void)testRendererKeepsPackedBrightnessByteOneCells {
    MatrixCodeMetalView *view = [[MatrixCodeMetalView alloc]
        initWithFrame:NSMakeRect(0, 0, 320, 200)
              session:nil
         storedValues:@{}];
    [view diagnosticPackedStateWithWidth:320 height:200];
    MatrixCodeRainSimulation *simulation = [view valueForKey:@"rainSimulation"];
    NSMutableData *state = (NSMutableData *)simulation.stateData;
    memset(state.mutableBytes, 0, state.length);
    uint8_t *bytes = state.mutableBytes;
    bytes[0] = 2;
    bytes[1] = 1;
    bytes[2] = 0x3f;
    bytes[3] = 1;

    XCTAssertTrue([view diagnosticRendererConsumesPackedStateWithWidth:320 height:200]);
    XCTAssertEqual([[view valueForKey:@"instanceCount"] unsignedIntegerValue],
                   (NSUInteger)1);
}

@end
