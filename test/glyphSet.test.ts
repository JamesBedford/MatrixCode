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

describe("glyphSet — message glyphs", () => {
  it("appends lowercase and punctuation after the original set, keeping indices stable", () => {
    const gs = createGlyphSet();
    expect(gs.ranges.katakana.start).toBe(0);
    expect(gs.ranges.digits.start).toBe(56);
    expect(gs.ranges.latin.start).toBe(66);
    expect(gs.ranges.symbols.start).toBe(92);
    expect(gs.ranges.lower.start).toBe(99);
    expect(gs.ranges.lower.count).toBe(26);
    expect(gs.ranges.punct.start).toBe(125);
    expect(gs.ranges.punct.count).toBe(5);
    expect(gs.count).toBe(130);
    expect(gs.count).toBeLessThanOrEqual(MAX_GLYPHS);
    expect(gs.chars.length).toBe(gs.count);
  });

  it("maps characters to glyph indices without case folding", () => {
    const gs = createGlyphSet();
    expect(gs.charToGlyphIndex("A")).toBe(66);
    expect(gs.charToGlyphIndex("Z")).toBe(91);
    expect(gs.charToGlyphIndex("a")).toBe(99);
    expect(gs.charToGlyphIndex("z")).toBe(124);
    expect(gs.charToGlyphIndex("a")).not.toBe(gs.charToGlyphIndex("A"));
    expect(gs.charToGlyphIndex("0")).toBe(56);
    expect(gs.charToGlyphIndex("9")).toBe(65);
    expect(gs.charToGlyphIndex("-")).toBe(94); // existing symbol, not duplicated into punct
    expect(gs.charToGlyphIndex(".")).toBe(125);
    expect(gs.charToGlyphIndex("'")).toBe(129);
  });

  it("returns null for spaces and unsupported characters", () => {
    const gs = createGlyphSet();
    expect(gs.charToGlyphIndex(" ")).toBeNull();
    expect(gs.charToGlyphIndex("#")).toBeNull();
    expect(gs.charToGlyphIndex("€")).toBeNull();
  });

  it("round-trips every supported character to the glyph at its index", () => {
    const gs = createGlyphSet();
    for (const ch of "ABZaz09-.!?',") {
      const idx = gs.charToGlyphIndex(ch);
      expect(idx).not.toBeNull();
      expect(gs.chars[idx!]).toBe(ch);
    }
  });

  it("never picks message-only glyphs (lowercase/punct) for the random rain", () => {
    const gs = createGlyphSet();
    const rng = createRng(12345);
    for (let i = 0; i < 50000; i++) {
      expect(gs.randomGlyphIndex(rng)).toBeLessThan(gs.ranges.lower.start);
    }
  });
});
