import type { GlyphMode } from "../types.ts";

export function preferredMirrorForGlyphMode(mode: GlyphMode): boolean {
  return mode === "matrix" || mode === "katakana";
}
