import type { ImageMask, ImagesDoc } from "../types.ts";
import { decodeBase64Mask, sanitizeImages } from "../config/imagesStore.ts";

const GAP_SALT = 0x6d2b79f5;
const SELECT_SALT = 0x3f4d1c23;
const PLACEMENT_X_SALT = 0x731f4a7d;
const PLACEMENT_Y_SALT = 0x4c2d65bf;
// More than 15 hours at the shortest legal reveal+gap cadence. Reaching this limit means the
// synchronized epoch is stale or hostile, not that a normal panel merely missed a few frames.
const MAX_SYNCHRONIZED_FAST_FORWARD_STEPS = 65_536;

export function imageHash(value: number): number {
  let v = value >>> 0;
  v = (v ^ (v >>> 16)) >>> 0;
  v = Math.imul(v, 0x7feb352d) >>> 0;
  v = (v ^ (v >>> 15)) >>> 0;
  v = Math.imul(v, 0x846ca68b) >>> 0;
  return (v ^ (v >>> 16)) >>> 0;
}

export function imageUnit(value: number): number {
  return (imageHash(value) & 0x00ffffff) / 0x01000000;
}

export interface ActiveImageFrame {
  image: ImageMask;
  mask: Uint8Array;
  intensity: number;
  scramble: number;
  placementX: number;
  placementY: number;
  /** Seconds on the scheduler's shared epoch, used by the deterministic falling reveal. */
  rainElapsed: number;
  /** 18 Hz epoch-relative bucket used by deterministic cell scrambling. */
  animationBucket: number;
}

interface ActiveImage {
  image: ImageMask;
  mask: Uint8Array;
  startMs: number;
  endMs: number;
  placementX: number;
  placementY: number;
}

export interface ImageSchedulerOptions {
  seed: number;
  epochMs: number;
  /** Shared multi-display mode activates at the exact scheduled time rather than a panel's late frame. */
  synchronized?: boolean;
}

/** Hash-scheduled image playlist which owns no mutable PRNG and never touches RainSim state. */
export class ImageScheduler {
  private readonly seed: number;
  private epochMs: number;
  private readonly synchronized: boolean;
  private doc: ImagesDoc | null = null;
  private signature = "";
  private nextFireAt: number | null = null;
  private active: ActiveImage | null = null;

  constructor(options: ImageSchedulerOptions) {
    this.seed = options.seed >>> 0;
    this.epochMs = options.epochMs;
    this.synchronized = options.synchronized === true;
  }

  /** Adopt a changed document, cancel the active reveal, and re-arm from the correct timeline. */
  configure(doc: ImagesDoc, nowMs: number, force = false): void {
    const clean = sanitizeImages(doc);
    const signature = JSON.stringify(clean);
    if (!force && signature === this.signature) return;
    this.doc = clean;
    this.signature = signature;
    this.active = null;
    this.nextFireAt = null;
    if (clean.enabled && clean.images.length > 0) {
      const base = this.synchronized ? this.epochMs : nowMs;
      this.nextFireAt = base + this.gapMs(GAP_SALT);
    }
  }

  /** Shift app-relative clocks across a pause. Shared wall-clock sessions never call this. */
  shiftTimelineBy(deltaMs: number): void {
    if (!(deltaMs > 0) || this.synchronized) return;
    this.epochMs += deltaMs;
    if (this.nextFireAt !== null) this.nextFireAt += deltaMs;
    if (this.active) {
      this.active.startMs += deltaMs;
      this.active.endMs += deltaMs;
    }
  }

  update(nowMs: number): ActiveImageFrame | null {
    const doc = this.doc;
    if (!doc || !doc.enabled || doc.images.length === 0) {
      this.active = null;
      this.nextFireAt = null;
      return null;
    }

    if (this.active && nowMs >= this.active.endMs) {
      const endedAt = this.active.endMs;
      this.active = null;
      const anchor = this.synchronized ? endedAt : nowMs;
      const cycle = Math.floor((anchor - this.epochMs) / 1000) >>> 0;
      this.nextFireAt = anchor + this.gapMs((cycle ^ GAP_SALT) >>> 0);
    }

    // Synchronized panels can attach after the shared epoch (or be briefly stalled). Walk the
    // deterministic schedule to the interval containing `nowMs` in this same update, rather than
    // replaying one already-expired reveal per rendered frame while the panels catch up.
    let fastForwardSteps = 0;
    while (!this.active && this.nextFireAt !== null && nowMs >= this.nextFireAt) {
      if (this.synchronized && fastForwardSteps++ >= MAX_SYNCHRONIZED_FAST_FORWARD_STEPS) {
        // Rebase pathological epochs to a deterministic whole-second boundary. A second boundary
        // keeps separate panels aligned; advancing once more when its gap already elapsed guarantees
        // this call returns without immediately entering another historical catch-up loop.
        let anchor = this.epochMs + Math.floor(Math.max(0, nowMs - this.epochMs) / 1000) * 1000;
        let cycle = Math.floor((anchor - this.epochMs) / 1000) >>> 0;
        this.nextFireAt = anchor + this.gapMs((cycle ^ GAP_SALT) >>> 0);
        if (this.nextFireAt <= nowMs) {
          anchor += 1000;
          cycle = Math.floor((anchor - this.epochMs) / 1000) >>> 0;
          this.nextFireAt = anchor + this.gapMs((cycle ^ GAP_SALT) >>> 0);
        }
        break;
      }
      const fireTime = this.nextFireAt;
      const activationTime = this.synchronized ? fireTime : nowMs;
      const activation = Math.floor((activationTime - this.epochMs) / 100) >>> 0;
      const selected = imageHash((this.seed ^ activation ^ SELECT_SALT) >>> 0) % doc.images.length;
      const image = doc.images[selected]!;
      const mask = decodeBase64Mask(image.data);
      if (!mask || mask.length !== image.width * image.height) {
        const anchor = this.synchronized ? fireTime : nowMs;
        this.nextFireAt = anchor + this.gapMs((activation ^ GAP_SALT) >>> 0);
      } else {
        this.active = {
          image,
          mask,
          startMs: activationTime,
          endMs: activationTime + doc.appearMs + doc.persistenceMs + doc.disappearMs,
          placementX: imageUnit((this.seed ^ activation ^ PLACEMENT_X_SALT) >>> 0),
          placementY: imageUnit((this.seed ^ activation ^ PLACEMENT_Y_SALT) >>> 0),
        };
        this.nextFireAt = null;

        if (this.synchronized && nowMs >= this.active.endMs) {
          const endedAt = this.active.endMs;
          this.active = null;
          const cycle = Math.floor((endedAt - this.epochMs) / 1000) >>> 0;
          this.nextFireAt = endedAt + this.gapMs((cycle ^ GAP_SALT) >>> 0);
        }
      }

      // App-relative scheduling deliberately activates late at `nowMs`, so it can never have a
      // backlog. The synchronized path continues until it reaches the present interval.
      if (!this.synchronized) break;
    }

    return this.frame(nowMs);
  }

  /** Fire immediately for editor preview; configure() restores the persisted schedule afterwards. */
  previewOne(nowMs: number, doc: ImagesDoc): ActiveImageFrame | null {
    const clean = sanitizeImages({ ...doc, enabled: true });
    this.doc = clean;
    this.signature = JSON.stringify(clean);
    this.nextFireAt = null;
    if (clean.images.length === 0) {
      this.active = null;
      return null;
    }
    const activation = Math.floor((nowMs - this.epochMs) / 100) >>> 0;
    const image = clean.images[imageHash((this.seed ^ activation ^ SELECT_SALT) >>> 0) % clean.images.length]!;
    const mask = decodeBase64Mask(image.data);
    if (!mask) return null;
    this.active = {
      image,
      mask,
      startMs: nowMs,
      endMs: nowMs + clean.appearMs + clean.persistenceMs + clean.disappearMs,
      placementX: imageUnit((this.seed ^ activation ^ PLACEMENT_X_SALT) >>> 0),
      placementY: imageUnit((this.seed ^ activation ^ PLACEMENT_Y_SALT) >>> 0),
    };
    return this.frame(nowMs);
  }

  private gapMs(salt: number): number {
    return this.doc!.frequencyMs * (0.75 + 0.5 * imageUnit((this.seed ^ salt) >>> 0));
  }

  private frame(nowMs: number): ActiveImageFrame | null {
    const active = this.active;
    const doc = this.doc;
    if (!active || !doc) return null;
    const elapsed = nowMs - active.startMs;
    const remaining = active.endMs - nowMs;
    let fade = 1;
    let flicker = 0;
    if (doc.appearMs > 0 && elapsed < doc.appearMs) {
      fade = Math.max(0, elapsed / doc.appearMs);
      flicker = 1 - fade;
    } else if (doc.disappearMs > 0 && remaining < doc.disappearMs) {
      fade = Math.max(0, remaining / doc.disappearMs);
      flicker = 1 - fade;
    }
    return {
      image: active.image,
      mask: active.mask,
      intensity: doc.brightnessFade ? fade : 1,
      scramble: doc.flickerOut ? flicker : 0,
      placementX: active.placementX,
      placementY: active.placementY,
      rainElapsed: (nowMs - this.epochMs) / 1000,
      animationBucket: Math.floor(((nowMs - this.epochMs) / 1000) * 18) >>> 0,
    };
  }
}
