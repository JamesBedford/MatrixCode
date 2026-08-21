import { describe, expect, it } from "vitest";
import {
  imageCellIdentity,
  imageEdgeFeather,
  imageFallingGate,
  imageRevealGeometry,
  imageSignal,
  sampleImageMask,
} from "../src/sim/imageReveal.ts";
import type { ActiveImageFrame } from "../src/sim/imageScheduler.ts";
import type { ImagesDoc } from "../src/types.ts";

const frame: ActiveImageFrame = {
  image: { name: "wide", width: 2, height: 1, data: "AP8=" },
  mask: new Uint8Array([0, 255]),
  intensity: 1,
  scramble: 0,
  placementX: 0,
  placementY: 1,
  rainElapsed: 2,
  animationBucket: 36,
};
const doc: ImagesDoc = {
  images: [frame.image], enabled: true, frequencyMs: 1000, persistenceMs: 1000,
  appearMs: 0, disappearMs: 0, flickerOut: true, brightnessFade: false,
  imageScale: 0.5, imagePlacementJitter: 1,
};

describe("image reveal reference", () => {
  it("fits and jitters inside the full virtual grid", () => {
    expect(imageRevealGeometry(frame, doc, 100, 40)).toEqual({
      originCol: 0,
      originRow: 15,
      cols: 50,
      rows: 25,
      featherU: 0.04,
      featherV: 0.04,
    });
  });

  it("samples masks bilinearly in top-to-bottom row order", () => {
    expect(sampleImageMask(new Uint8Array([0, 255, 255, 0]), 2, 2, 0, 0)).toBe(0);
    expect(sampleImageMask(new Uint8Array([0, 255, 255, 0]), 2, 2, 0.5, 0.5)).toBeCloseTo(0.5);
  });

  it("keeps zero masks inert and feathers every edge", () => {
    expect(imageSignal(0)).toBe(0);
    expect(imageSignal(1)).toBeGreaterThan(0.7);
    expect(imageEdgeFeather(0, 0.5, 0.1, 0.1)).toBe(0);
    expect(imageEdgeFeather(0.5, 0.5, 0.1, 0.1)).toBe(1);
  });

  it("locks deterministic cell and falling-wave values", () => {
    expect(imageCellIdentity(0x1a2b3c, 12, 8)).toBe(1316630523);
    expect(imageFallingGate(12, 8, 2.5, 0x1a2b3c)).toBeCloseTo(0.0509755093, 8);
  });
});
