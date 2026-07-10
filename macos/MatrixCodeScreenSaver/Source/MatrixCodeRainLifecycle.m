#import "MatrixCodeRainLifecycle.h"

static uint32_t MatrixCodeRainHash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    return value ^ (value >> 16);
}

static float MatrixCodeRainUnit(uint32_t value) {
    return (float)(MatrixCodeRainHash(value) & 0x00ffffffU) / 16777216.0f;
}

float MatrixCodeRainRampEase(float progress) {
    float p = fminf(1, fmaxf(0, progress));
    const float edge = 0.2f;
    const float velocity = 1.0f / (1.0f - edge);
    if (p < edge) return velocity * p * p / (2.0f * edge);
    if (p > 1.0f - edge) {
        float remaining = 1.0f - p;
        return 1.0f - velocity * remaining * remaining / (2.0f * edge);
    }
    return velocity * edge / 2.0f + velocity * (p - edge);
}

NSInteger MatrixCodeRainGlyphIndex(uint32_t key, NSString *glyphMode) {
    float pick = MatrixCodeRainUnit(key ^ 0x68e31da4U);
    if ([glyphMode isEqualToString:@"binary"]) return 56 + (NSInteger)(pick * 2);
    if ([glyphMode isEqualToString:@"katakana"]) return (NSInteger)(pick * 56);
    if ([glyphMode isEqualToString:@"digits"]) return 56 + (NSInteger)(pick * 10);
    if ([glyphMode isEqualToString:@"latin"]) return 66 + (NSInteger)(pick * 26);
    if ([glyphMode isEqualToString:@"symbols"]) return 92 + (NSInteger)(pick * 7);
    // Match the web glyph-set group weights: Katakana 80%, digits 11%,
    // Latin 5%, symbols 4%. A second hash chooses inside the selected group.
    float group = MatrixCodeRainUnit(key ^ 0xb5297a4dU);
    NSInteger start = 0;
    NSInteger count = 56;
    if (group >= 0.96f) {
        start = 92; count = 7;
    } else if (group >= 0.91f) {
        start = 66; count = 26;
    } else if (group >= 0.80f) {
        start = 56; count = 10;
    }
    return start + (NSInteger)(pick * count);
}

float MatrixCodeRainEffectiveTrailSpeed(
    float streamSpeed,
    float speedControl,
    float trailVariation
) {
    float averageSpeed = (3.5f + 8.0f * 0.5f) * fmaxf(speedControl, 0.1f);
    float variation = fminf(1, fmaxf(0, trailVariation));
    return averageSpeed + (streamSpeed - averageSpeed) * variation;
}

static float MatrixCodeRainInverseRampEase(float value) {
    float y = fminf(1, fmaxf(0, value));
    const float edge = 0.2f;
    const float velocity = 1.0f / (1.0f - edge);
    const float easedEdge = velocity * edge / 2.0f;
    if (y < easedEdge) return sqrtf(2.0f * edge * y / velocity);
    if (y > 1.0f - easedEdge) {
        return 1.0f - sqrtf(2.0f * edge * (1.0f - y) / velocity);
    }
    return edge + (y - easedEdge) / velocity;
}

MatrixCodeRainStreamSample MatrixCodeRainSampleStream(
    uint32_t key,
    float rainElapsed,
    float densityScale,
    float rampDuration,
    float virtualRows,
    float speedControl,
    float density,
    float streamFraction
) {
    MatrixCodeRainStreamSample sample = {NO, 0, 0, NO};
    float fraction = fminf(1, fmaxf(0, streamFraction));
    float gate = MatrixCodeRainUnit(key ^ 0x51ed270bU);
    if (fraction <= 0 || gate > fraction * densityScale) return sample;

    float activationScale = gate / fraction;
    float activationTime = rampDuration > 0
        ? MatrixCodeRainInverseRampEase(activationScale) * rampDuration
        : 0;
    float age = rainElapsed - activationTime;
    if (age < 0) return sample;

    sample.speed = (3.5f + MatrixCodeRainUnit(key ^ 0x27d4eb2dU) * 8.0f) *
        fmaxf(speedControl, 0.1f);
    sample.whiteHead = MatrixCodeRainUnit(key ^ 0xd3a2646cU) < 0.2f;
    float startRow = -MatrixCodeRainUnit(key ^ 0x165667b1U) * 24.0f;
    float fallDuration = (virtualRows + 36.0f - startRow) / sample.speed;
    float gapDuration = (0.15f + MatrixCodeRainUnit(key ^ 0x94d049bbU) * 2.6f) /
        fmaxf(density, 0.1f);
    float cycleDuration = fallDuration + gapDuration;

    // With no ramp, reproduce WebGL's pre-warmed distributed start. During a
    // ramp there is deliberately no phase offset: every newly admitted stream
    // begins above the virtual desktop instead of materialising inside it.
    if (rampDuration <= 0) {
        age += MatrixCodeRainUnit(key ^ 0x6c8e9cf5U) * cycleDuration;
    }
    float phase = fmodf(age, cycleDuration);
    if (phase < 0 || phase > fallDuration) return sample;
    sample.active = YES;
    sample.headRow = startRow + phase * sample.speed;
    return sample;
}
