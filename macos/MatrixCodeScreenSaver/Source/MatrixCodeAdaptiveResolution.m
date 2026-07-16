#import "MatrixCodeAdaptiveResolution.h"

#import <math.h>

// Preserve the web controller's per-operation IEEE-754 rounding under Release
// optimization; the EMA must not become a fused multiply-add.
#pragma STDC FP_CONTRACT OFF

MatrixCodeAdaptiveResolutionConfig MatrixCodeAdaptiveResolutionDefaultConfig(void) {
    return (MatrixCodeAdaptiveResolutionConfig){
        .targetMilliseconds = 1000.0 / 60.0,
        .minimumScale = 0.5,
        .step = 0.1,
        .emaAlpha = 0.15,
        .upHeadroom = 0.6,
        .downThreshold = 1.15,
        .cooldownFrames = 30,
        .warmFrames = 20,
    };
}

@interface MatrixCodeAdaptiveResolution ()
@property(nonatomic) MatrixCodeAdaptiveResolutionConfig config;
@property(nonatomic) double value;
@property(nonatomic) double smoothedMilliseconds;
@property(nonatomic) NSInteger seenFrames;
@property(nonatomic) NSInteger cooldown;
@end

@implementation MatrixCodeAdaptiveResolution

- (instancetype)init {
    return [self initWithConfig:MatrixCodeAdaptiveResolutionDefaultConfig()];
}

- (instancetype)initWithConfig:(MatrixCodeAdaptiveResolutionConfig)config {
    self = [super init];
    if (!self) return nil;
    self.config = config;
    [self reset];
    return self;
}

- (void)reset {
    self.value = 1;
    self.smoothedMilliseconds = 0;
    self.seenFrames = 0;
    self.cooldown = 0;
}

- (double)updateWithFrameMilliseconds:(double)frameMilliseconds {
    self.smoothedMilliseconds = self.seenFrames == 0
        ? frameMilliseconds
        : self.smoothedMilliseconds + self.config.emaAlpha *
            (frameMilliseconds - self.smoothedMilliseconds);
    self.seenFrames++;
    if (self.seenFrames <= self.config.warmFrames) return self.value;
    if (self.cooldown > 0) {
        self.cooldown--;
        return self.value;
    }

    if (self.smoothedMilliseconds >
            self.config.targetMilliseconds * self.config.downThreshold &&
        self.value > self.config.minimumScale) {
        self.value = fmax(self.config.minimumScale, self.value - self.config.step);
        self.cooldown = self.config.cooldownFrames;
    } else if (self.smoothedMilliseconds <
                   self.config.targetMilliseconds * self.config.upHeadroom &&
               self.value < 1) {
        self.value = fmin(1, self.value + self.config.step);
        self.cooldown = self.config.cooldownFrames;
    }
    return self.value;
}

@end
