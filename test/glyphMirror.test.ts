import { describe, expect, it } from "vitest";
import { preferredMirrorForGlyphMode } from "../src/config/glyphMirror.ts";
import type { GlyphMode } from "../src/types.ts";

describe("preferredMirrorForGlyphMode", () => {
  it("mirrors film-accurate glyph sets and keeps readable code-like sets unmirrored", () => {
    const expected: Record<GlyphMode, boolean> = {
      matrix: true,
      katakana: true,
      binary: false,
      digits: false,
      latin: false,
      symbols: false,
    };

    for (const [mode, mirror] of Object.entries(expected) as [GlyphMode, boolean][]) {
      expect(preferredMirrorForGlyphMode(mode)).toBe(mirror);
    }
  });
});
