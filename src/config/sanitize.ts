// Shared helpers for coercing arbitrary parsed JSON (localStorage, URL, user input)
// into valid, range-checked values. Used by the persisted config stores.

import { clamp } from "../util/math.ts";

/** A finite number clamped into [min, max], or `fallback` for anything else. */
export function num(v: unknown, min: number, max: number, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? clamp(v, min, max) : fallback;
}

/** A string sliced to `maxLen`, or `fallback` for non-strings. */
export function text(v: unknown, maxLen: number, fallback = ""): string {
  return typeof v === "string" ? v.slice(0, maxLen) : fallback;
}

/** A boolean passed through, or `fallback` for non-booleans. */
export function bool(v: unknown, fallback: boolean): boolean {
  return typeof v === "boolean" ? v : fallback;
}

/** An array sliced to at most `max` items, or [] for non-arrays. */
export function capArray(v: unknown, max: number): unknown[] {
  return Array.isArray(v) ? v.slice(0, max) : [];
}
