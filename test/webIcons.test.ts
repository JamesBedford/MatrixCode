import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { getPreset } from "../src/config/colorPresets.ts";

const ROOT = fileURLToPath(new URL("../", import.meta.url));
const read = (rel: string): Buffer => readFileSync(ROOT + rel);

/** Normalized [0..1] RGB tuple -> #rrggbb. */
function toHex(rgb: readonly [number, number, number]): string {
  const c = (n: number): string =>
    Math.round(Math.max(0, Math.min(1, n)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${c(rgb[0])}${c(rgb[1])}${c(rgb[2])}`;
}

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Read a PNG's pixel dimensions from its IHDR chunk. */
function pngSize(buf: Buffer): { width: number; height: number } {
  expect(buf.subarray(0, 8).equals(PNG_MAGIC)).toBe(true);
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

interface ManifestIcon {
  src: string;
  sizes: string;
  type: string;
  purpose?: string;
}
interface Manifest {
  name: string;
  short_name: string;
  start_url: string;
  display: string;
  background_color: string;
  theme_color: string;
  icons: ManifestIcon[];
}

const manifest: Manifest = JSON.parse(read("public/manifest.webmanifest").toString("utf8"));

describe("web app manifest", () => {
  it("declares the required top-level fields", () => {
    expect(manifest.name).toBe("MatrixCode");
    expect(manifest.short_name).toBe("Matrix");
    expect(typeof manifest.start_url).toBe("string");
    expect(manifest.display).toBe("standalone");
    expect(Array.isArray(manifest.icons)).toBe(true);
  });

  it("uses the classic preset background for theme and background colors", () => {
    const bg = toHex(getPreset("classic").background);
    expect(manifest.theme_color.toLowerCase()).toBe(bg);
    expect(manifest.background_color.toLowerCase()).toBe(bg);
  });

  it("covers 192 and 512 in both any and maskable purposes", () => {
    const has = (sizes: string, purpose: string): boolean =>
      manifest.icons.some(
        (i) => i.sizes === sizes && (i.purpose ?? "any").split(" ").includes(purpose),
      );
    expect(has("192x192", "any")).toBe(true);
    expect(has("512x512", "any")).toBe(true);
    expect(has("192x192", "maskable")).toBe(true);
    expect(has("512x512", "maskable")).toBe(true);
  });

  it("points every icon at a real PNG whose pixels match its declared size", () => {
    for (const icon of manifest.icons) {
      expect(icon.type).toBe("image/png");
      const [w, h] = icon.sizes.split("x").map(Number);
      const actual = pngSize(read(`public/${icon.src}`));
      expect({ src: icon.src, ...actual }).toEqual({ src: icon.src, width: w, height: h });
    }
  });
});

describe("apple-touch-icon", () => {
  it("is a 180x180 PNG", () => {
    expect(pngSize(read("public/icons/apple-touch-icon.png"))).toEqual({
      width: 180,
      height: 180,
    });
  });
});

describe("index.html icon wiring", () => {
  const html = read("index.html").toString("utf8");

  it("links the manifest and apple-touch-icon and keeps the svg favicon", () => {
    expect(html).toContain('rel="manifest"');
    expect(html).toContain("manifest.webmanifest");
    expect(html).toContain('rel="apple-touch-icon"');
    expect(html).toContain("icons/apple-touch-icon.png");
    expect(html).toContain('rel="icon"');
    expect(html).toContain("favicon.svg");
  });

  it("declares the app is installable / web-app capable", () => {
    expect(html).toContain('name="mobile-web-app-capable"');
    expect(html).toContain('name="apple-mobile-web-app-capable"');
  });
});
