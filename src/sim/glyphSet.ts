import type { Rng } from "../util/rng.ts";
import { weightedPick } from "../util/math.ts";
import { MAX_GLYPHS } from "../types.ts";

// The authentic Matrix glyph mix, in canonical index order. Katakana dominate;
// digits are common; Latin and symbols are a deliberate minority (over-using
// Latin makes the rain read as generic "hacker" code rather than Matrix code).
//
// The ORDER here is the glyph index order the simulation and atlas both rely on.
// (The atlas may substitute a visible fallback for any glyph the chosen font
//  cannot render, but it never changes the count or order, so indices stay valid.)

function charRange(start: number, end: number): string[] {
  const out: string[] = [];
  for (let cp = start; cp <= end; cp++) out.push(String.fromCodePoint(cp));
  return out;
}

// Half-width (hankaku) katakana, U+FF66..U+FF9D — the core falling glyphs.
const KATAKANA = charRange(0xff66, 0xff9d); // 56 glyphs
const DIGITS = "0123456789".split(""); // 10
const LATIN = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split(""); // 26
const SYMBOLS = "=+-*<>:".split(""); // 7

interface GroupRange {
  start: number;
  count: number;
}

export interface GlyphSet {
  /** Ordered characters; index = glyph index. */
  chars: string[];
  count: number;
  ranges: {
    katakana: GroupRange;
    digits: GroupRange;
    latin: GroupRange;
    symbols: GroupRange;
  };
  /** Pick a glyph index, weighted so katakana dominate. */
  randomGlyphIndex(rng: Rng): number;
}

// Group selection weights — katakana ~80%, digits ~11%, latin ~5%, symbols ~4%.
const GROUP_WEIGHTS = [0.8, 0.11, 0.05, 0.04] as const;

export function createGlyphSet(): GlyphSet {
  const chars = [...KATAKANA, ...DIGITS, ...LATIN, ...SYMBOLS];
  if (chars.length > MAX_GLYPHS) {
    chars.length = MAX_GLYPHS; // hard cap so an index fits in one byte
  }
  const ranges = {
    katakana: { start: 0, count: KATAKANA.length },
    digits: { start: KATAKANA.length, count: DIGITS.length },
    latin: { start: KATAKANA.length + DIGITS.length, count: LATIN.length },
    symbols: { start: KATAKANA.length + DIGITS.length + LATIN.length, count: SYMBOLS.length },
  };
  const groups = [ranges.katakana, ranges.digits, ranges.latin, ranges.symbols];

  return {
    chars,
    count: chars.length,
    ranges,
    randomGlyphIndex(rng: Rng): number {
      const g = weightedPick(GROUP_WEIGHTS as unknown as number[], rng);
      const range = groups[g]!;
      return range.start + Math.floor(rng() * range.count);
    },
  };
}
