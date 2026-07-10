import type { ColorPreset } from "../types.ts";

// A live, theme-coloured favicon: three staggered columns of katakana rain whose glyphs fade from
// a dim body shade up to the bright white-green head, recoloured to match the active preset.
//
// The layout/glyphs here are the single source of truth; public/favicon.svg is a static placeholder
// shown before this script runs and is kept visually in sync with the "classic" preset output.

type Rgb = readonly [number, number, number];

interface Cell {
  x: number;
  /** Vertical centre of the glyph. */
  y: number;
  glyph: string;
  /** Index into the brightness ramp (0 = deep trail … 4 = bright head). */
  level: number;
}

// Three staggered columns, head (level 4) leading at the bottom of each — matching the rain's
// stationary-grid look where a wave of illumination sweeps down and decays up the trail.
const CELLS: readonly Cell[] = [
  // column 1
  { x: 14, y: 10.5, glyph: "ﾊ", level: 1 },
  { x: 14, y: 22.5, glyph: "ｼ", level: 2 },
  { x: 14, y: 34.5, glyph: "ﾘ", level: 3 },
  { x: 14, y: 46.5, glyph: "ﾂ", level: 4 },
  // column 2 — a deep-trail glyph up top hints at the decayed wake above the run
  { x: 32, y: 22.5, glyph: "ｸ", level: 0 },
  { x: 32, y: 34.5, glyph: "ｦ", level: 1 },
  { x: 32, y: 46.5, glyph: "ﾐ", level: 2 },
  { x: 32, y: 58.5, glyph: "ﾝ", level: 4 },
  // column 3
  { x: 50, y: 10.5, glyph: "ﾅ", level: 2 },
  { x: 50, y: 22.5, glyph: "ｴ", level: 3 },
  { x: 50, y: 34.5, glyph: "ｱ", level: 4 },
];

const FONT_STACK = "'Hiragino Kaku Gothic Pro', 'MS Gothic', 'Noto Sans JP', 'Yu Gothic', monospace";

function toHex(c: Rgb): string {
  const channel = (n: number): string =>
    Math.round(Math.max(0, Math.min(1, n)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(c[0])}${channel(c[1])}${channel(c[2])}`;
}

function mix(a: Rgb, b: Rgb, t: number): Rgb {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

/** Build the favicon SVG markup for a preset. The ramp runs from a deep trail shade (halfway to
 *  the near-black tail, so it stays visible) up to the white-green head, so every theme reads as
 *  glowing rain. */
export function buildFaviconSvg(preset: ColorPreset): string {
  const ramp: Rgb[] = [
    mix(preset.tail, preset.body, 0.5),
    preset.body,
    preset.bright,
    mix(preset.bright, preset.head, 0.45),
    preset.head,
  ];
  const glyphs = CELLS.map((c) => {
    const filter = c.level === 4 ? ' filter="url(#head-glow)"' : "";
    return `<text x="${c.x}" y="${c.y}" fill="${toHex(ramp[c.level]!)}"${filter}>${c.glyph}</text>`;
  }).join("");
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` +
    `<rect width="64" height="64" rx="13" fill="${toHex(preset.background)}"/>` +
    `<defs><filter id="head-glow" x="-60%" y="-60%" width="220%" height="220%">` +
    `<feGaussianBlur stdDeviation="1.1" result="blur"/>` +
    `<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>` +
    `</filter></defs>` +
    `<g font-family="${FONT_STACK}" font-size="13" font-weight="bold" ` +
    `text-anchor="middle" dominant-baseline="central">${glyphs}</g>` +
    `</svg>`
  );
}

/** Recolour the page favicon to match the active preset, reusing the existing <link> if present. */
export function applyFavicon(preset: ColorPreset): void {
  if (typeof document === "undefined") return;
  const href = `data:image/svg+xml,${encodeURIComponent(buildFaviconSvg(preset))}`;
  let link = document.querySelector<HTMLLinkElement>('link[rel~="icon"]');
  if (!link) {
    link = document.createElement("link");
    link.rel = "icon";
    document.head.appendChild(link);
  }
  link.type = "image/svg+xml";
  link.href = href;
}
