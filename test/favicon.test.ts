import { describe, it, expect } from "vitest";
import { buildFaviconSvg } from "../src/ui/favicon.ts";
import { getPreset } from "../src/config/colorPresets.ts";

const count = (haystack: string, needle: string): number => haystack.split(needle).length - 1;

describe("buildFaviconSvg", () => {
  it("draws eleven katakana glyphs across three columns, one glowing head each", () => {
    const svg = buildFaviconSvg(getPreset("classic"));
    expect(count(svg, "<text")).toBe(11);
    // One bright leading head per column carries the bloom filter.
    expect(count(svg, 'filter="url(#head-glow)"')).toBe(3);
    // Authentic half-width katakana, not rectangles.
    expect(svg).toContain("ﾊ");
    expect(svg).not.toContain("<rect width=\"10\"");
  });

  it("colours the rain from the preset: deep-to-body trail, bright body, white head, themed background", () => {
    const svg = buildFaviconSvg(getPreset("classic"));
    expect(svg).toContain("#006509"); // deep trail (halfway tail-to-body)
    expect(svg).toContain("#008f11"); // body (dim trail)
    expect(svg).toContain("#00ff41"); // bright
    expect(svg).toContain("#deffe4"); // head
    expect(svg).toContain('fill="#0d0208"'); // preset background tile
  });

  it("recolours to the selected preset", () => {
    const amber = buildFaviconSvg(getPreset("amber"));
    expect(amber).toContain("#ffb000"); // amber bright
    expect(amber).toContain("#a85b00"); // amber body
    expect(amber).not.toContain("#00ff41"); // no leftover green
    // Different presets yield different markup.
    expect(amber).not.toBe(buildFaviconSvg(getPreset("blue")));
  });
});
