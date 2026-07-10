import { describe, expect, it } from "vitest";
import { atlasDisplayCharForGlyphMode } from "../src/gl/glyphAtlas.ts";

describe("glyph atlas display characters", () => {
  it("remaps ambient rain cells for digit-only modes", () => {
    const rainGlyphCount = 99;
    const digitStart = 56;

    expect(atlasDisplayCharForGlyphMode("ｦ", 0, rainGlyphCount, "binary", digitStart)).toBe("0");
    expect(atlasDisplayCharForGlyphMode("M", 57, rainGlyphCount, "binary", digitStart)).toBe("1");
    expect(atlasDisplayCharForGlyphMode("ｦ", 64, rainGlyphCount, "digits", digitStart)).toBe("8");
    expect(atlasDisplayCharForGlyphMode("M", 57, rainGlyphCount)).toBe("M");
    expect(atlasDisplayCharForGlyphMode("M", -1, rainGlyphCount, "binary", digitStart)).toBe("M");
    expect(atlasDisplayCharForGlyphMode("M", rainGlyphCount, rainGlyphCount, "binary", digitStart)).toBe("M");
  });
});
