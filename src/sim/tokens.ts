// Dynamic text tokens shared by the typed intro and the in-rain messages. Pure and DOM-free:
// the clock and countdown target are injected via a TokenContext so this whole module is
// deterministic and unit-testable. `{name}` is resolved here too (it used to live in
// messageOverlay.ts) so every surface substitutes tokens through one code path.

import { holidayTargetMs, HOLIDAY_TOKENS } from "./holidays.ts";

/** Name used when the viewer's own name can't be determined. */
export const DEFAULT_USER_NAME = "Neo";

/** Token in line text replaced with the resolved viewer name at play time. */
export const NAME_TOKEN = "{name}";

/** Everything the token resolver needs; injected so tests control the clock. */
export interface TokenContext {
  /** Viewer name for `{name}` (blank falls back to DEFAULT_USER_NAME). */
  name: string;
  /** Current wall-clock, epoch ms — drives `{time}`/`{countdown}`/`{countup}`. */
  nowMs: number;
  /** Default target for bare `{countdown}`/`{countup}`, epoch ms, or null when unset. */
  countdownTargetMs: number | null;
  /** Named moments, name → target epoch ms (null = unset). Omitted ⇒ no named moments. */
  moments?: Record<string, number | null>;
  /** When this run began, epoch ms. Bare `{countup}` counts up from here when no default target is set. Omitted ⇒ bare `{countup}` with no target shows 00:00. */
  runStartMs?: number;
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];
const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const pad2 = (n: number): string => String(n).padStart(2, "0");

/** Day of the year, 1..366, in local time. */
function dayOfYear(d: Date): number {
  const start = new Date(d.getFullYear(), 0, 0);
  const diff = d.getTime() - start.getTime();
  return Math.floor(diff / 86_400_000);
}

/**
 * A minimal strftime over LOCAL time — just the directives a clock/date placeholder needs.
 * Supported: %H %I %M %S %p %Y %y %m %d %e %A %a %B %b %j %%. Any unknown %x passes through verbatim.
 */
export function strftime(date: Date, format: string): string {
  const hours24 = date.getHours();
  const hours12 = hours24 % 12 === 0 ? 12 : hours24 % 12;
  return format.replace(/%(.)/g, (whole, code: string) => {
    switch (code) {
      case "H": return pad2(hours24);
      case "I": return pad2(hours12);
      case "M": return pad2(date.getMinutes());
      case "S": return pad2(date.getSeconds());
      case "p": return hours24 < 12 ? "AM" : "PM";
      case "Y": return String(date.getFullYear());
      case "y": return pad2(date.getFullYear() % 100);
      case "m": return pad2(date.getMonth() + 1);
      case "d": return pad2(date.getDate());
      case "e": return String(date.getDate()).padStart(2, " ");
      case "A": return WEEKDAYS[date.getDay()]!;
      case "a": return WEEKDAYS_SHORT[date.getDay()]!;
      case "B": return MONTHS[date.getMonth()]!;
      case "b": return MONTHS_SHORT[date.getMonth()]!;
      case "j": return String(dayOfYear(date)).padStart(3, "0");
      case "%": return "%";
      default: return whole; // unknown directive: leave untouched
    }
  });
}

/**
 * Format a remaining duration, clamped to ≥ 0, adaptively:
 *   DD:HH:MM:SS when a day or more remains, HH:MM:SS when under a day, MM:SS when under an hour.
 */
export function formatCountdown(remainingMs: number): string {
  let total = Math.floor(Math.max(0, remainingMs) / 1000);
  const days = Math.floor(total / 86_400);
  total -= days * 86_400;
  const hours = Math.floor(total / 3_600);
  total -= hours * 3_600;
  const minutes = Math.floor(total / 60);
  const seconds = total - minutes * 60;
  if (days > 0) return `${pad2(days)}:${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
  if (hours > 0) return `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
  return `${pad2(minutes)}:${pad2(seconds)}`;
}

// One pass over the text: {name}, {time[:FORMAT]}, {countdown[:NAME]}, {countup[:NAME]}.
// Group 1 = kind, group 2 = optional argument (a strftime format for time, a moment name otherwise).
// Unknown {foo} is left as-is.
const TOKEN_RE = /\{(name|time|countdown|countup)(?::([^}]*))?\}/g;

/** Substitute all supported tokens in `text` using `ctx`. Pure — unknown tokens pass through. */
export function resolveTokens(text: string, ctx: TokenContext): string {
  const moments = ctx.moments ?? {};
  return text.replace(TOKEN_RE, (_whole, kind: string, arg: string | undefined) => {
    if (kind === "name") return ctx.name.trim() || DEFAULT_USER_NAME;
    if (kind === "time") return strftime(new Date(ctx.nowMs), arg !== undefined ? arg : "%H:%M");
    // kind === "countdown" | "countup"
    const target = countTarget(kind, arg, ctx, moments);
    if (target === null) return formatCountdown(0);
    return formatCountdown(kind === "countup" ? ctx.nowMs - target : target - ctx.nowMs);
  });
}

/**
 * The instant a {countdown}/{countup} measures to/from:
 *   - `{…:NAME}` → a user moment of that name if defined, else a built-in holiday, else null (⇒ 00:00).
 *   - bare `{…}` → the user's default target; and for `{countup}` with no default target, the
 *     run-start time so it counts up from when the animation began.
 */
function countTarget(
  kind: string,
  arg: string | undefined,
  ctx: TokenContext,
  moments: Record<string, number | null>,
): number | null {
  if (arg !== undefined) {
    const key = arg.trim();
    if (Object.prototype.hasOwnProperty.call(moments, key)) return moments[key] ?? null;
    return holidayTargetMs(key, ctx.nowMs);
  }
  if (ctx.countdownTargetMs !== null) return ctx.countdownTargetMs;
  return kind === "countup" ? ctx.runStartMs ?? null : null;
}

/** UI copy for the editors' hover: the user's named moments plus the built-in holidays, as ready-to-type tokens. */
export function momentHint(names: string[]): string {
  const yours = names.length
    ? `Your moments: ${names.map((n) => `{countdown:${n}}`).join(", ")}`
    : "No named moments yet.";
  const builtins = `Built-in (use {countdown:NAME}): ${HOLIDAY_TOKENS.join(", ")}`;
  return `${yours}\n${builtins}\nAlso {countup:…} for any of these.`;
}
