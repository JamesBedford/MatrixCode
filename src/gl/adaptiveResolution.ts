// Pure, deterministic controller for adaptive render-resolution scaling. It watches a smoothed
// frame interval and, only under sustained load, lowers an internal scale (the fraction of the full
// device-pixel backing actually rendered) to keep the frame rate up; when headroom returns it raises
// the scale back to 1.0. A dead zone between the up/down thresholds plus a cooldown prevent
// oscillation. It holds no timing or GL state — frame times are injected — so it is fully unit-testable.

export interface AdaptiveResolutionConfig {
  /** Target frame budget in ms (e.g. 1000/60). */
  targetMs: number;
  /** Lowest allowed scale (e.g. 0.5 = render at half the linear backing resolution). */
  minScale: number;
  /** Scale change per adjustment. */
  step: number;
  /** EMA smoothing factor for the frame interval (0..1). */
  emaAlpha: number;
  /** Scale UP only when the smoothed interval < targetMs * upHeadroom (margin against oscillation). */
  upHeadroom: number;
  /** Scale DOWN when the smoothed interval > targetMs * downThreshold. */
  downThreshold: number;
  /** Minimum frames between scale changes. */
  cooldownFrames: number;
  /** Frames to observe before acting, so the EMA reflects steady state. */
  warmFrames: number;
}

export const DEFAULT_ADAPTIVE_CONFIG: AdaptiveResolutionConfig = {
  targetMs: 1000 / 60,
  minScale: 0.5,
  step: 0.1,
  emaAlpha: 0.15,
  upHeadroom: 0.6,
  downThreshold: 1.15,
  cooldownFrames: 30,
  warmFrames: 20,
};

export class AdaptiveResolution {
  private cfg: AdaptiveResolutionConfig;
  private scaleValue = 1;
  private ema = 0;
  private seen = 0;
  private cooldown = 0;

  constructor(cfg: AdaptiveResolutionConfig = DEFAULT_ADAPTIVE_CONFIG) {
    this.cfg = cfg;
  }

  /** Current render scale in (0, 1]. */
  get value(): number {
    return this.scaleValue;
  }

  /** Smoothed frame interval (ms), for diagnostics/HUD. */
  get smoothedMs(): number {
    return this.ema;
  }

  reset(): void {
    this.scaleValue = 1;
    this.ema = 0;
    this.seen = 0;
    this.cooldown = 0;
  }

  /** Feed one frame's interval (ms); returns the (possibly changed) scale. */
  update(frameMs: number): number {
    this.ema = this.seen === 0 ? frameMs : this.ema + this.cfg.emaAlpha * (frameMs - this.ema);
    this.seen++;
    if (this.seen <= this.cfg.warmFrames) return this.scaleValue;
    if (this.cooldown > 0) {
      this.cooldown--;
      return this.scaleValue;
    }
    const { targetMs, downThreshold, upHeadroom, step, minScale } = this.cfg;
    if (this.ema > targetMs * downThreshold && this.scaleValue > minScale) {
      this.scaleValue = Math.max(minScale, this.scaleValue - step);
      this.cooldown = this.cfg.cooldownFrames;
    } else if (this.ema < targetMs * upHeadroom && this.scaleValue < 1) {
      this.scaleValue = Math.min(1, this.scaleValue + step);
      this.cooldown = this.cfg.cooldownFrames;
    }
    return this.scaleValue;
  }
}
