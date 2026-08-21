#import <XCTest/XCTest.h>

#import <math.h>
#import <string.h>

#import "MatrixCodeImageContract.h"
#import "MatrixCodePreferences.h"
#import "MatrixCodeRainLifecycle.h"

@interface MatrixCodeImageContractTests : XCTestCase
@end

@implementation MatrixCodeImageContractTests

static NSDictionary *MatrixCodeTestImage(NSString *name,
                                         NSInteger width,
                                         NSInteger height,
                                         uint8_t fill) {
    NSMutableData *mask = [NSMutableData dataWithLength:(NSUInteger)(width * height)];
    memset(mask.mutableBytes, fill, mask.length);
    return @{
        @"name": name,
        @"width": @(width),
        @"height": @(height),
        @"data": [mask base64EncodedStringWithOptions:0],
    };
}

static NSString *MatrixCodeTestJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)testPortableConstantsAndDefaultsAreFixtureLocked {
    XCTAssertEqual(MatrixCodeImageMaskMaximumDimension, (NSUInteger)96);
    XCTAssertEqual(MatrixCodeImageMaximumCount, (NSUInteger)64);
    XCTAssertEqual(MatrixCodeImageNameMaximumLength, (NSUInteger)80);
    XCTAssertEqual(MatrixCodeImageMaskMaximumStoredCharacters, (NSUInteger)49152);
    XCTAssertEqualObjects(MatrixCodeImagesPortableBackupDefaultsKey,
                          @"mx-images-portable-backup-v0");
    XCTAssertEqualObjects(MatrixCodeDefaultImagesDocument(), (@{
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
    }));
    XCTAssertFalse([MatrixCodePreferences
        isAllowedStorageKey:MatrixCodeImagesPortableBackupDefaultsKey]);
}

- (void)testSanitizerFiltersBeforeCappingAndRetainsSourceOrder {
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSUInteger index = 0; index < 70; index++) {
        [candidates addObject:@{ @"width": @1, @"height": @1, @"data": @"not base64" }];
        [candidates addObject:MatrixCodeTestImage(
            [NSString stringWithFormat:@"mask-%02lu", (unsigned long)index], 1, 1, (uint8_t)index)];
    }

    NSDictionary *document = MatrixCodeSanitizeImagesDocument(@{ @"images": candidates });
    NSArray *images = document[@"images"];
    XCTAssertEqual(images.count, (NSUInteger)64);
    XCTAssertEqualObjects(images.firstObject[@"name"], @"mask-00");
    XCTAssertEqualObjects(images.lastObject[@"name"], @"mask-63");
}

- (void)testSanitizerMatchesPortableTypesRangesAndMaskRules {
    NSDictionary *portable = MatrixCodeTestImage(@"Portable", 96, 1, 0x5a);
    NSDictionary *sanitizedPortable = MatrixCodeSanitizeImageItem(portable);
    XCTAssertEqualObjects(sanitizedPortable, portable,
                          @"Masks at or below 96 must round-trip byte-for-byte");

    NSDictionary *fractional = @{
        @"name": @"  Fractional  ",
        @"width": @2.9,
        @"height": @1.8,
        @"data": @"AQI=",
    };
    XCTAssertEqualObjects(MatrixCodeSanitizeImageItem(fractional), (@{
        @"name": @"Fractional", @"width": @2, @"height": @1, @"data": @"AQI=",
    }));
    XCTAssertNil(MatrixCodeSanitizeImageItem(MatrixCodeTestImage(@"Legacy", 97, 1, 1)));
    XCTAssertNil(MatrixCodeSanitizeImageItem(@{
        @"name": @"Unpadded", @"width": @1, @"height": @1, @"data": @"AA",
    }));

    NSDictionary *document = MatrixCodeSanitizeImagesDocument(@{
        @"images": @[portable],
        @"enabled": @1,
        @"frequencyMs": @0,
        @"persistenceMs": @700000,
        @"appearMs": @-10,
        @"disappearMs": @(NAN),
        @"flickerOut": @"false",
        @"brightnessFade": @YES,
        @"imageScale": @0,
        @"imagePlacementJitter": @2,
    });
    XCTAssertFalse([document[@"enabled"] boolValue]);
    XCTAssertEqualObjects(document[@"frequencyMs"], @500);
    XCTAssertEqualObjects(document[@"persistenceMs"], @600000);
    XCTAssertEqualObjects(document[@"appearMs"], @0);
    XCTAssertEqualObjects(document[@"disappearMs"], @4500);
    XCTAssertTrue([document[@"flickerOut"] boolValue]);
    XCTAssertTrue([document[@"brightnessFade"] boolValue]);
    XCTAssertEqualWithAccuracy([document[@"imageScale"] doubleValue], 0.05, 0.000001);
    XCTAssertEqualWithAccuracy([document[@"imagePlacementJitter"] doubleValue], 1, 0.000001);
    XCTAssertEqualObjects(MatrixCodeSanitizeImagesJSONString(@"not-json"),
                          MatrixCodeDefaultImagesDocument());
}

- (void)testMigrationDetectionOnlyFlagsPortableDataLoss {
    NSMutableArray *sixtyFive = [NSMutableArray array];
    for (NSUInteger index = 0; index < 65; index++) {
        if (index == 12) [sixtyFive addObject:@"malformed"];
        [sixtyFive addObject:MatrixCodeTestImage(@"Mask", 1, 1, 0)];
    }
    XCTAssertTrue(MatrixCodeImagesJSONStringRequiresPortableBackup(
        MatrixCodeTestJSON(@{ @"images": sixtyFive })));

    [sixtyFive removeLastObject];
    XCTAssertFalse(MatrixCodeImagesJSONStringRequiresPortableBackup(
        MatrixCodeTestJSON(@{ @"images": sixtyFive })));
    XCTAssertTrue(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(@"Legacy", 97, 1, 0)],
    })));
    NSMutableDictionary *converted = [MatrixCodeTestImage(@"Converted", 96, 1, 0) mutableCopy];
    converted[@"width"] = @97;
    XCTAssertTrue(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[converted],
    })));
    XCTAssertFalse(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[@{ @"name": @"Broken", @"width": @97, @"height": @1, @"data": @"AA==" }],
    })));

    NSMutableString *longName = [NSMutableString string];
    for (NSUInteger index = 0; index < 81; index++) [longName appendString:@"A"];
    XCTAssertTrue(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(longName, 1, 1, 0)],
    })));
    XCTAssertTrue(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[@{ @"name": @"  Portable  ", @"width": @1.9, @"height": @1,
                          @"data": @"AA==" }],
    })));
    XCTAssertFalse(MatrixCodeImagesJSONStringRequiresPortableBackup(MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(@"Portable", 1, 1, 0)],
    })));
}

- (void)testPremultipliedImportPreservesEstablishedAlphaSquaredAppearance {
    MatrixCodeImageMaskDimensions widescreen = MatrixCodeImageMaskDimensionsForSource(1920, 1080);
    XCTAssertEqual(widescreen.width, 96);
    XCTAssertEqual(widescreen.height, 54);
    MatrixCodeImageMaskDimensions small = MatrixCodeImageMaskDimensionsForSource(10, 20);
    XCTAssertEqual(small.width, 10);
    XCTAssertEqual(small.height, 20);
    MatrixCodeImageMaskDimensions thin = MatrixCodeImageMaskDimensionsForSource(1, 500);
    XCTAssertEqual(thin.width, 1);
    XCTAssertEqual(thin.height, 96);

    const uint8_t halfAlphaWhite[] = {128, 128, 128, 128};
    const uint8_t halfAlphaExpected[] = {82};
    XCTAssertEqualObjects(
        MatrixCodeImageMaskFromPremultipliedRGBA(
            [NSData dataWithBytes:halfAlphaWhite length:sizeof(halfAlphaWhite)], 1, 1),
        [NSData dataWithBytes:halfAlphaExpected length:sizeof(halfAlphaExpected)]);

    const uint8_t rgba[] = {64, 32, 16, 128};
    NSData *mask = MatrixCodeImageMaskFromPremultipliedRGBA(
        [NSData dataWithBytes:rgba length:sizeof(rgba)], 1, 1);
    const uint8_t expected[] = {30};
    XCTAssertEqualObjects(mask, [NSData dataWithBytes:expected length:sizeof(expected)]);

    const uint8_t normalizedRGBA[] = {
        0, 0, 0, 0,
        64, 32, 16, 128,
        255, 255, 255, 255,
    };
    const uint8_t normalizedExpected[] = {0, 30, 255};
    XCTAssertEqualObjects(
        MatrixCodeImageMaskFromPremultipliedRGBA(
            [NSData dataWithBytes:normalizedRGBA length:sizeof(normalizedRGBA)], 3, 1),
        [NSData dataWithBytes:normalizedExpected length:sizeof(normalizedExpected)]);

    const uint8_t contrastRGBA[] = {20, 20, 20, 255, 220, 220, 220, 255};
    const uint8_t contrastExpected[] = {0, 255};
    XCTAssertEqualObjects(
        MatrixCodeImageMaskFromPremultipliedRGBA(
            [NSData dataWithBytes:contrastRGBA length:sizeof(contrastRGBA)], 2, 1),
        [NSData dataWithBytes:contrastExpected length:sizeof(contrastExpected)]);
    XCTAssertNil(MatrixCodeImageMaskFromPremultipliedRGBA(
        [NSData dataWithBytes:rgba length:sizeof(rgba)], 97, 1));
}

- (void)testRevealMathMatchesDeterministicGoldenFixtures {
    XCTAssertEqual(MatrixCodeImageHash(0), (uint32_t)0);
    XCTAssertEqual(MatrixCodeImageHash(1), (uint32_t)1753845952);
    XCTAssertEqual(MatrixCodeImageHash(0x12345678U), (uint32_t)4125564054);
    XCTAssertEqualWithAccuracy(MatrixCodeImageUnit(0x12345678U), 0.9027799368, 0.0000001);
    XCTAssertEqual(MatrixCodeImageAnimationBucket((1.0 / 18.0) - 1e-10, 0),
                   (uint32_t)0,
                   @"Do not round elapsed time to float before flooring the web's 18 Hz bucket");
    XCTAssertEqual(MatrixCodeImageAnimationBucket(1.0 / 18.0, 0), (uint32_t)1);
    XCTAssertEqual(MatrixCodeImageCellIdentity(24680, 17, 9), (uint32_t)1775802068);
    XCTAssertEqual(MatrixCodeImageCellIdentity(24680, -3, -4), (uint32_t)554140740);
    XCTAssertEqual(MatrixCodeImageCellIdentity(0x1a2b3cU, 12, 8), (uint32_t)1316630523);

    const uint8_t sampleBytes[] = {0, 64, 128, 255};
    NSData *sample = [NSData dataWithBytes:sampleBytes length:sizeof(sampleBytes)];
    XCTAssertEqualWithAccuracy(MatrixCodeImageSampleMask(sample, 2, 2, 0.25f, 0.75f),
                               0.4855392, 0.000001);
    XCTAssertEqual(MatrixCodeImageSampleMask(sample, 2, 2, -0.01f, 0.5f), 0);

    XCTAssertEqualWithAccuracy(MatrixCodeImageSignalForLuminance(0.08f),
                               0.2486473, 0.000001);
    XCTAssertEqualWithAccuracy(MatrixCodeImageSignalForLuminance(0.5f), 0.36, 0.000001);
    XCTAssertEqualWithAccuracy(MatrixCodeImageEdgeFeather(0.05f, 0.1f, 0.1f, 0.2f),
                               0.25, 0.000001);
    XCTAssertEqualWithAccuracy(MatrixCodeImageFallingGate(17, 9, 2.5f, 24680),
                               0.01588745, 0.000001);
    XCTAssertEqualWithAccuracy(MatrixCodeImageFallingGate(12, 8, 2.5f, 0x1a2b3cU),
                               0.0509755093, 0.000001);
}

- (void)testGlyphMappingGoldenPreservesCurrentModesAndBinaryQuirk {
    const float luminance[] = {0, 0.2f, 0.4f, 0.6f, 0.8f, 1};
    const NSInteger binary[] = {57, 57, 57, 56, 56, 56};
    const NSInteger digits[] = {57, 63, 60, 61, 64, 56};
    const NSInteger latin[] = {74, 77, 85, 79, 78, 88};
    const NSInteger symbols[] = {93, 98, 96, 94, 95, 92};
    const NSInteger katakana[] = {50, 4, 3, 51, 16, 50};
    for (NSUInteger index = 0; index < sizeof(luminance) / sizeof(luminance[0]); index++) {
        XCTAssertEqual(MatrixCodeImageGlyphForLuminance(luminance[index], 0x12345678U, @"binary"),
                       binary[index]);
        XCTAssertEqual(MatrixCodeImageGlyphForLuminance(luminance[index], 0x12345678U, @"digits"),
                       digits[index]);
        XCTAssertEqual(MatrixCodeImageGlyphForLuminance(luminance[index], 0x12345678U, @"latin"),
                       latin[index]);
        XCTAssertEqual(MatrixCodeImageGlyphForLuminance(luminance[index], 0x12345678U, @"symbols"),
                       symbols[index]);
        XCTAssertEqual(MatrixCodeImageGlyphForLuminance(luminance[index], 0x12345678U, @"katakana"),
                       katakana[index]);
    }
    XCTAssertEqual(MatrixCodeRainDigitStartIndex(), 56);
    XCTAssertEqual(MatrixCodeRainLatinStartIndex(), 66);
    XCTAssertEqual(MatrixCodeRainSymbolsStartIndex(), 92);
}

- (void)testPreferencesBackUpLegacyImagesOnceBeforeCanonicalDataLoss {
    NSString *suite = [NSString stringWithFormat:@"MatrixCodeImageContractTests.%@",
                       NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    MatrixCodePreferences *preferences = [[MatrixCodePreferences alloc] initWithDefaults:defaults];

    NSString *legacy97 = MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(@"Legacy 97", 97, 1, 0x33)],
    });
    [defaults setObject:legacy97 forKey:@"mx-images"];
    NSString *legacy97StillUnportable = MatrixCodeTestJSON(@{
        @"enabled": @YES,
        @"images": @[MatrixCodeTestImage(@"Legacy 97", 97, 1, 0x33)],
    });
    [preferences setImmediateValue:legacy97StillUnportable forKey:@"mx-images"];
    XCTAssertNil([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                 @"A change that retains all legacy content is not a canonicalizing save");

    NSString *portable = MatrixCodeTestJSON(MatrixCodeDefaultImagesDocument());
    [preferences commitValues:@{ @"mx-images": portable }];
    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                          legacy97StillUnportable);

    NSMutableArray *sixtyFive = [NSMutableArray array];
    for (NSUInteger index = 0; index < 65; index++) {
        [sixtyFive addObject:MatrixCodeTestImage(@"Mask", 1, 1, (uint8_t)index)];
    }
    [defaults setObject:MatrixCodeTestJSON(@{ @"images": sixtyFive }) forKey:@"mx-images"];
    [preferences setImmediateValue:portable forKey:@"mx-images"];
    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                          legacy97StillUnportable,
                          @"The first raw compatibility backup must never be overwritten");
    [defaults removePersistentDomainForName:suite];
}

- (void)testPreferencesDoNotBackUpPortableOrMalformedMasks {
    NSString *suite = [NSString stringWithFormat:@"MatrixCodeImageContractTests.%@",
                       NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    MatrixCodePreferences *preferences = [[MatrixCodePreferences alloc] initWithDefaults:defaults];
    NSString *portable = MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(@"Portable", 96, 1, 0x11)],
    });
    [defaults setObject:portable forKey:@"mx-images"];
    [preferences setImmediateValue:MatrixCodeTestJSON(MatrixCodeDefaultImagesDocument())
                            forKey:@"mx-images"];
    XCTAssertNil([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey]);

    NSString *broken = MatrixCodeTestJSON(@{
        @"images": @[@{ @"name": @"Broken", @"width": @128, @"height": @1,
                         @"data": @"AA==" }],
    });
    [defaults setObject:broken forKey:@"mx-images"];
    [preferences setImmediateValue:nil forKey:@"mx-images"];
    XCTAssertNil([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey]);

    NSString *legacyButUntouched = MatrixCodeTestJSON(@{
        @"images": @[MatrixCodeTestImage(@"Legacy", 97, 1, 0x22)],
    });
    [defaults setObject:legacyButUntouched forKey:@"mx-images"];
    [preferences commitValues:@{}];
    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                          legacyButUntouched,
                          @"A full commit which omits mx-images removes it and must back it up");
    [defaults removePersistentDomainForName:suite];
}

- (void)testPreferencesBackUpMoreThanSixtyFourValidMasks {
    NSString *suite = [NSString stringWithFormat:@"MatrixCodeImageContractTests.%@",
                       NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    MatrixCodePreferences *preferences = [[MatrixCodePreferences alloc] initWithDefaults:defaults];
    NSMutableArray *masks = [NSMutableArray array];
    for (NSUInteger index = 0; index < 65; index++) {
        [masks addObject:MatrixCodeTestImage(
            [NSString stringWithFormat:@"Mask %lu", (unsigned long)index], 1, 1, (uint8_t)index)];
    }
    NSString *raw = MatrixCodeTestJSON(@{ @"images": masks });
    [defaults setObject:raw forKey:@"mx-images"];

    [preferences setImmediateValue:MatrixCodeTestJSON(MatrixCodeDefaultImagesDocument())
                            forKey:@"mx-images"];

    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey], raw);
    [defaults removePersistentDomainForName:suite];
}

- (void)testPreferencesBackUpPartialLossEvenWhenReplacementRemainsNonPortable {
    NSString *suite = [NSString stringWithFormat:@"MatrixCodeImageContractTests.%@",
                       NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    MatrixCodePreferences *preferences = [[MatrixCodePreferences alloc] initWithDefaults:defaults];

    NSDictionary *first = MatrixCodeTestImage(@"First legacy", 97, 1, 0x11);
    NSDictionary *second = MatrixCodeTestImage(@"Second legacy", 97, 1, 0x22);
    NSString *stored = MatrixCodeTestJSON(@{ @"images": @[first, second] });
    [defaults setObject:stored forKey:@"mx-images"];

    NSDictionary *replacement = MatrixCodeTestImage(@"Replacement legacy", 97, 1, 0x33);
    [preferences setImmediateValue:MatrixCodeTestJSON(@{ @"images": @[second, replacement] })
                            forKey:@"mx-images"];

    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                          stored,
                          @"Keeping one incompatible mask must not hide the loss of another");
    [defaults removePersistentDomainForName:suite];
}

- (void)testPreferencesBackUpPortableMaskBeforeCanonicalizingItsName {
    NSString *suite = [NSString stringWithFormat:@"MatrixCodeImageContractTests.%@",
                       NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    MatrixCodePreferences *preferences = [[MatrixCodePreferences alloc] initWithDefaults:defaults];
    NSDictionary *rawImage = MatrixCodeTestImage(@"  User label  ", 1, 1, 0x44);
    NSString *stored = MatrixCodeTestJSON(@{ @"images": @[rawImage] });
    [defaults setObject:stored forKey:@"mx-images"];

    NSDictionary *canonical = MatrixCodeSanitizeImagesDocument(@{ @"images": @[rawImage] });
    [preferences setImmediateValue:MatrixCodeTestJSON(canonical) forKey:@"mx-images"];

    XCTAssertEqualObjects([defaults objectForKey:MatrixCodeImagesPortableBackupDefaultsKey],
                          stored);
    [defaults removePersistentDomainForName:suite];
}

@end
