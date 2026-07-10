import type { GlyphFont } from "../types.ts";

export const GLYPH_FONT_OPTIONS: [GlyphFont, string][] = [
  ["matrix", "Movie Gothic"],
  ["gothic", "Sharp Gothic"],
  ["mono", "SF Mono"],
  ["terminal", "Terminal Mono"],
  ["rounded", "Rounded"],
  ["mincho", "Mincho"],
];

export const GLYPH_FONTS: GlyphFont[] = GLYPH_FONT_OPTIONS.map(([value]) => value);

const WEB_FONT_STACKS: Record<GlyphFont, string> = {
  matrix: '"Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic Pro", "Yu Gothic", "Meiryo", "MS Gothic", "Noto Sans JP", monospace',
  gothic: '"Yu Gothic", "Meiryo", "Hiragino Kaku Gothic ProN", "MS Gothic", "Noto Sans JP", sans-serif',
  mono: '"SFMono-Regular", "Menlo", "Consolas", "Liberation Mono", "MS Gothic", monospace',
  terminal: '"Courier New", "Menlo", "Monaco", "MS Gothic", monospace',
  rounded: '"Hiragino Maru Gothic ProN", "Arial Rounded MT Bold", "Yu Gothic", "Meiryo", sans-serif',
  mincho: '"Hiragino Mincho ProN", "Yu Mincho", "MS Mincho", serif',
};

export function glyphFontFamily(font: GlyphFont): string {
  return WEB_FONT_STACKS[font] ?? WEB_FONT_STACKS.matrix;
}
