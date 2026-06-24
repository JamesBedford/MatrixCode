import { describe, it, expect } from "vitest";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { createRng } from "../src/util/rng.ts";
import { MAX_GLYPHS } from "../src/types.ts";

describe("glyphSet", () => {
  it("starts with half-width katakana and stays under the byte cap", () => {
    const gs = createGlyphSet();
    expect(gs.count).toBeLessThanOrEqual(MAX_GLYPHS);
    // U+FF66 is the first half-width katakana (ｦ).
    expect(gs.chars[0]).toBe(String.fromCodePoint(0xff66));
    expect(gs.ranges.katakana.count).toBe(56);
    expect(gs.ranges.digits.count).toBe(10);
  });

  it("includes the digits group mapped to 0-9", () => {
    const gs = createGlyphSet();
    const d = gs.ranges.digits;
    expect(gs.chars[d.start]).toBe("0");
    expect(gs.chars[d.start + 9]).toBe("9");
  });

  it("is katakana-dominant with Latin a small minority", () => {
    const gs = createGlyphSet();
    const rng = createRng(777);
    const N = 40000;
    let kana = 0;
    let latin = 0;
    const k = gs.ranges.katakana;
    const l = gs.ranges.latin;
    for (let i = 0; i < N; i++) {
      const idx = gs.randomGlyphIndex(rng);
      if (idx >= k.start && idx < k.start + k.count) kana++;
      if (idx >= l.start && idx < l.start + l.count) latin++;
    }
    expect(kana / N).toBeGreaterThan(0.75);
    expect(kana / N).toBeLessThan(0.85);
    expect(latin / N).toBeLessThan(0.08);
  });

  it("only ever returns in-range indices", () => {
    const gs = createGlyphSet();
    const rng = createRng(5);
    for (let i = 0; i < 5000; i++) {
      const idx = gs.randomGlyphIndex(rng);
      expect(idx).toBeGreaterThanOrEqual(0);
      expect(idx).toBeLessThan(gs.count);
    }
  });
});
