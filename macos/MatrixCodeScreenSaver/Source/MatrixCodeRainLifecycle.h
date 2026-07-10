#import <Foundation/Foundation.h>

typedef struct {
    BOOL active;
    float headRow;
    float speed;
    BOOL whiteHead;
} MatrixCodeRainStreamSample;

FOUNDATION_EXPORT float MatrixCodeRainRampEase(float progress);
FOUNDATION_EXPORT NSInteger MatrixCodeRainGlyphIndex(uint32_t key, NSString *glyphMode);
FOUNDATION_EXPORT float MatrixCodeRainEffectiveTrailSpeed(
    float streamSpeed,
    float speedControl,
    float trailVariation
);
FOUNDATION_EXPORT MatrixCodeRainStreamSample MatrixCodeRainSampleStream(
    uint32_t key,
    float rainElapsed,
    float densityScale,
    float rampDuration,
    float virtualRows,
    float speedControl,
    float density,
    float streamFraction
);
