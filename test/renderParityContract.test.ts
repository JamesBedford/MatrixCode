import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { DEFAULT_ADAPTIVE_CONFIG } from "../src/gl/adaptiveResolution.ts";
import { getPreset, PRESET_NAMES } from "../src/config/colorPresets.ts";

const read = (relativePath: string): string =>
  readFileSync(fileURLToPath(new URL(`../${relativePath}`, import.meta.url)), "utf8");

const webRenderer = read("src/gl/renderer.ts");
const webApp = read("src/app.ts");
const webAtlas = read("src/gl/glyphAtlas.ts");
const webBlur = read("src/gl/shaders/blur.frag.glsl");
const webComposite = read("src/gl/shaders/composite.frag.glsl");
const nativeRenderer = read("macos/MatrixCodeScreenSaver/Source/MatrixCodeMetalView.m");
const nativeShaders = read("macos/MatrixCodeScreenSaver/Resources/MatrixCodeShaders.msl");
const nativeAdaptive = read("macos/MatrixCodeScreenSaver/Source/MatrixCodeAdaptiveResolution.m");
const nativeApp = read("macos/MatrixCodeScreenSaver/AppSource/MatrixCodeAppDelegate.m");

function numericConstant(source: string, name: string): number {
  const match = source.match(new RegExp(`\\b${name}\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)f?\\b`));
  if (!match?.[1]) throw new Error(`Missing numeric constant ${name}`);
  return Number(match[1]);
}

function hex(rgb: readonly number[]): number {
  return rgb.reduce((value, channel) => (value << 8) | Math.round(channel * 255), 0);
}

function objcConfigNumber(source: string, name: string): number {
  const match = source.match(new RegExp(`\\.${name}\\s*=\\s*([0-9.]+(?:\\s*/\\s*[0-9.]+)?)`));
  if (!match?.[1]) throw new Error(`Missing Objective-C config value ${name}`);
  const factors = match[1].split("/").map((part) => Number(part.trim()));
  return factors.slice(1).reduce((value, divisor) => value / divisor, factors[0]!);
}

describe("macOS/Web render parity source contract", () => {
  it("locks atlas resolution, HDR formats, bloom levels, and blur spread", () => {
    expect(numericConstant(webApp, "ATLAS_CELL_PX")).toBe(64);
    expect(numericConstant(nativeRenderer, "MatrixCodeAtlasCellPixels")).toBe(64);
    expect(numericConstant(webRenderer, "BLUR_SPREAD")).toBe(1.8);
    expect(numericConstant(nativeRenderer, "MatrixCodeBloomSpread")).toBe(1.8);

    expect(webRenderer).toContain("{ low: 1, med: 2, high: 3 }");
    expect(nativeRenderer).toContain("if ([quality isEqualToString:@\"low\"]) return 1;");
    expect(nativeRenderer).toContain("if ([quality isEqualToString:@\"med\"]) return 2;");
    expect(webRenderer).toContain("gl.RGBA16F");
    expect(webRenderer).toContain("gl.R11F_G11F_B10F");
    expect(nativeRenderer).toContain("MTLPixelFormatRGBA16Float");
    expect(nativeRenderer).toContain("MTLPixelFormatRG11B10Float");
  });

  it("keeps the collapsed Gaussian kernel byte-for-byte equivalent", () => {
    for (const name of ["w0", "w12", "w34", "o12", "o34"]) {
      expect(numericConstant(nativeShaders, name)).toBe(numericConstant(webBlur, name));
    }
  });

  it("keeps ACES, scanline, and vignette constants aligned", () => {
    for (const name of ["a", "b", "c", "d", "e"]) {
      expect(numericConstant(nativeShaders, name)).toBe(numericConstant(webComposite, name));
    }
    for (const value of ["0.15", "0.95", "0.42", "2.8"]) {
      expect(webComposite).toContain(value);
      expect(nativeShaders).toContain(value);
    }
    expect(webRenderer).toContain("params.scanlines ? 0.12 : 0");
    expect(nativeShaders).toContain("1.0 - 0.12 * (1.0 - lines)");
  });

  it("keeps every five-stop color preset identical", () => {
    for (const name of PRESET_NAMES) {
      const match = nativeRenderer.match(
        new RegExp(`@\"${name}\"\\s*:\\s*@\\[([^\\]]+)\\]`),
      );
      expect(match?.[1], `native ${name} palette`).toBeDefined();
      const nativeColors = [...(match?.[1]?.matchAll(/0x([0-9A-Fa-f]{6})/g) ?? [])]
        .map((entry) => Number.parseInt(entry[1]!, 16));
      const preset = getPreset(name);
      const webColors = [preset.background, preset.tail, preset.body, preset.bright, preset.head]
        .map(hex);
      expect(nativeColors, `${name} palette`).toEqual(webColors);
    }
  });

  it("requires the complete native equivalent render graph", () => {
    for (const stage of [
      "matrixSceneFragment",
      "matrixBrightPassFragment",
      "matrixBlurFragment",
      "matrixCopyFragment",
      "matrixCompositeFragment",
    ]) {
      expect(nativeShaders).toContain(stage);
    }
    for (const pipeline of [
      "brightPassPipeline",
      "blurPipeline",
      "resamplePipeline",
      "additiveCopyPipeline",
      "compositePipeline",
    ]) {
      expect(nativeRenderer).toContain(pipeline);
    }
  });

  it("keeps adaptive-resolution controller constants aligned", () => {
    const mappings = {
      targetMilliseconds: DEFAULT_ADAPTIVE_CONFIG.targetMs,
      minimumScale: DEFAULT_ADAPTIVE_CONFIG.minScale,
      step: DEFAULT_ADAPTIVE_CONFIG.step,
      emaAlpha: DEFAULT_ADAPTIVE_CONFIG.emaAlpha,
      upHeadroom: DEFAULT_ADAPTIVE_CONFIG.upHeadroom,
      downThreshold: DEFAULT_ADAPTIVE_CONFIG.downThreshold,
      cooldownFrames: DEFAULT_ADAPTIVE_CONFIG.cooldownFrames,
      warmFrames: DEFAULT_ADAPTIVE_CONFIG.warmFrames,
    };
    for (const [name, expected] of Object.entries(mappings)) {
      expect(objcConfigNumber(nativeAdaptive, name), name).toBeCloseTo(expected, 12);
    }
  });

  it("uses the same middle inked glyph for blank atlas cells", () => {
    expect(webAtlas).toContain(
      "goodFallbacks[Math.floor(goodFallbacks.length / 2)]",
    );
    expect(webAtlas).toContain("drawGlyph(chars[fallbackIndex]!, i)");
    expect(nativeRenderer).toContain(
      "inkedIndexes[inkedIndexes.count / 2].unsignedIntegerValue",
    );
    expect(nativeRenderer).toContain("drawGlyphAtIndex(glyphs[fallbackIndex], index)");
    expect(nativeRenderer).not.toContain(
      'MatrixCodeDrawReadableDigitGlyph(context, @"8", cellRect)',
    );
  });

  it("centers native glyphs with Canvas-equivalent typographic metrics", () => {
    expect(webAtlas).toContain('ctx.textAlign = "center"');
    expect(webAtlas).toContain('ctx.textBaseline = "middle"');
    expect(nativeRenderer).toContain("CTLineGetTypographicBounds");
    expect(nativeRenderer).toContain("(ascent - descent) * 0.5");
    expect(nativeRenderer).not.toContain("kCTLineBoundsUseGlyphPathBounds");
  });

  it("starts each standalone multi-monitor entry with a fresh identity", () => {
    expect(nativeApp).toContain(
      "[MatrixCodeSession freshSessionForScreen:screens.firstObject]",
    );
    expect(nativeApp).not.toContain(
      "[MatrixCodeSession sessionForScreen:screens.firstObject]",
    );
  });
});
