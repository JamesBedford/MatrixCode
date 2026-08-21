import { describe, expect, it } from "vitest";
import { imageMaskDimensions, rgbaToMaskBytes } from "../src/sim/imageMask.ts";

describe("image mask preprocessing", () => {
  it("aspect-fits without upscaling and uses the portable 96-cell cap", () => {
    expect(imageMaskDimensions(1920, 1080)).toEqual({ width: 96, height: 54 });
    expect(imageMaskDimensions(10, 20)).toEqual({ width: 10, height: 20 });
    expect(imageMaskDimensions(1, 500)).toEqual({ width: 1, height: 96 });
  });

  it("preserves the native alpha-squared edge treatment", () => {
    const opaque = rgbaToMaskBytes({ width: 1, height: 1, rgba: new Uint8Array([255, 255, 255, 255]) });
    const half = rgbaToMaskBytes({ width: 1, height: 1, rgba: new Uint8Array([255, 255, 255, 128]) });
    expect(opaque[0]).toBe(255);
    expect(half[0]).toBe(82);
  });

  it("normalizes meaningful contrast before applying gamma", () => {
    const mask = rgbaToMaskBytes({
      width: 2,
      height: 1,
      rgba: new Uint8Array([20, 20, 20, 255, 220, 220, 220, 255]),
    });
    expect([...mask]).toEqual([0, 255]);
  });

  it("rejects malformed buffers", () => {
    expect(() => rgbaToMaskBytes({ width: 2, height: 2, rgba: new Uint8Array(3) })).toThrow();
  });
});
