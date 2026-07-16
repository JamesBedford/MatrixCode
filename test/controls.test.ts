import { describe, expect, it } from "vitest";

import { DEFAULT_CONTROLS, sanitizeControls } from "../src/config/controls.ts";

describe("controls sanitizer cross-platform contract", () => {
  it("uses web defaults, strict types, ranges, legacy vignette, and choices", () => {
    const controls = {
      ...DEFAULT_CONTROLS,
      ...sanitizeControls({
        speed: 99,
        trailLength: -4,
        trailVariation: 2,
        density: Number.NaN,
        rampUpMs: true as unknown as number,
        glyphRate: -1,
        glyphScale: 20,
        glow: "2.4" as unknown as number,
        leadBrightness: 9,
        glyphMode: "unknown" as never,
        glyphFont: "unknown" as never,
        preset: "unknown" as never,
        mirror: 0 as unknown as boolean,
        scanlines: 1 as unknown as boolean,
        vignette: true as unknown as number,
        allowOverlap: 0 as unknown as boolean,
        quality: "ultra" as never,
      }),
    };

    expect(controls).toEqual({
      speed: 3,
      trailLength: 0.01,
      trailVariation: 1,
      density: 2,
      rampUpMs: 8000,
      glyphRate: 0,
      glyphScale: 10,
      glyphMode: "matrix",
      glyphFont: "matrix",
      glow: 0.9,
      leadBrightness: 3,
      preset: "classic",
      mirror: true,
      scanlines: false,
      vignette: 0.42,
      allowOverlap: true,
      quality: "high",
    });
  });
});
