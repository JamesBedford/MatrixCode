import { describe, expect, it } from "vitest";
import { glyphAtlasFontFamily, glyphFontFamily } from "../src/config/glyphFonts.ts";

describe("glyph atlas font family", () => {
  it("keeps digit-only modes on a readable numeric face", () => {
    expect(glyphAtlasFontFamily("matrix", "binary")).toContain("SFMono");
    expect(glyphAtlasFontFamily("rounded", "digits")).toContain("SFMono");
  });

  it("preserves the selected rain font for non-digit-only modes", () => {
    expect(glyphAtlasFontFamily("matrix", "matrix")).toBe(glyphFontFamily("matrix"));
    expect(glyphAtlasFontFamily("rounded", "latin")).toBe(glyphFontFamily("rounded"));
  });
});
