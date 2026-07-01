// Built-in, dynamically-computed holiday targets for {countdown:NAME} / {countup:NAME}.
// Pure and DOM-free (the clock is injected as nowMs) so it is deterministic and unit-testable.
//
// Each holiday resolves to the epoch-ms of its currently-relevant occurrence. Before the event's
// moment it counts down; from that moment until local midnight the target is in the past (so
// formatCountdown clamps the display to 00:00 for the rest of the day); at midnight the search
// rolls over to the following year's occurrence. See holidayTargetMs.

/** Western (Gregorian) Easter Sunday via the Anonymous Gregorian algorithm (Computus). Month 0-indexed. */
export function westernEaster(year: number): { month: number; day: number } {
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31); // 3 = March, 4 = April
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return { month: month - 1, day };
}

/** Day-of-month (1..31) of the `n`-th `weekday` (0=Sun..6=Sat) in `month0` (0-indexed) of `year`. */
export function nthWeekdayOfMonth(year: number, month0: number, weekday: number, n: number): number {
  const firstDow = new Date(year, month0, 1).getDay();
  const offset = (weekday - firstDow + 7) % 7;
  return 1 + offset + (n - 1) * 7;
}

// Diwali (Lakshmi Puja) main-day dates are lunisolar and region-dependent — there is no simple
// formula, so we table the published dates ([month0, day]). Approximate; extend as needed. Years
// outside the table resolve to null (⇒ {countdown:diwali} shows 00:00).
const DIWALI: Record<number, [number, number]> = {
  2024: [9, 31], // Oct 31, 2024
  2025: [9, 20], // Oct 20, 2025
  2026: [10, 8], // Nov 8, 2026
  2027: [9, 29], // Oct 29, 2027
  2028: [9, 17], // Oct 17, 2028
  2029: [10, 5], // Nov 5, 2029
  2030: [9, 26], // Oct 26, 2030
  2031: [10, 14], // Nov 14, 2031
  2032: [10, 2], // Nov 2, 2032
  2033: [9, 22], // Oct 22, 2033
  2034: [10, 10], // Nov 10, 2034
  2035: [9, 30], // Oct 30, 2035
  2036: [9, 19], // Oct 19, 2036
  2037: [10, 7], // Nov 7, 2037
  2038: [9, 27], // Oct 27, 2038
  2039: [9, 17], // Oct 17, 2039
  2040: [10, 4], // Nov 4, 2040
};

/** Returns the event's local Date (with time-of-day) for a calendar year, or null if unknown. */
type YearToDate = (year: number) => Date | null;

// Most holidays fire at 07:00 local (New Year is midnight). The exact time only sets when the
// countdown first reaches 00:00 that morning — it then holds 00:00 for the rest of the day.
const H = 7;

const HOLIDAYS: Record<string, YearToDate> = {
  newyear: (y) => new Date(y, 0, 1, 0, 0, 0),
  valentines: (y) => new Date(y, 1, 14, H, 0, 0),
  stpatricks: (y) => new Date(y, 2, 17, H, 0, 0),
  aprilfools: (y) => new Date(y, 3, 1, H, 0, 0),
  easter: (y) => { const e = westernEaster(y); return new Date(y, e.month, e.day, H, 0, 0); },
  july4: (y) => new Date(y, 6, 4, H, 0, 0),
  halloween: (y) => new Date(y, 9, 31, H, 0, 0),
  diwali: (y) => { const md = DIWALI[y]; return md ? new Date(y, md[0], md[1], H, 0, 0) : null; },
  thanksgiving: (y) => new Date(y, 10, nthWeekdayOfMonth(y, 10, 4, 4), H, 0, 0), // 4th Thursday of Nov (US)
  christmaseve: (y) => new Date(y, 11, 24, H, 0, 0),
  christmas: (y) => new Date(y, 11, 25, H, 0, 0),
};

// Alternate spellings → canonical key.
const ALIASES: Record<string, string> = {
  xmas: "christmas",
  newyears: "newyear",
  newyearseve: "newyear",
  valentine: "valentines",
  valentinesday: "valentines",
  stpatrick: "stpatricks",
  stpatricksday: "stpatricks",
  stpaddys: "stpatricks",
  july4th: "july4",
  fourthofjuly: "july4",
  independenceday: "july4",
  turkeyday: "thanksgiving",
};

/** Canonical holiday token names (in calendar order, excluding aliases) — for the editor hover. */
export const HOLIDAY_TOKENS: string[] = Object.keys(HOLIDAYS);

/**
 * Epoch-ms of the holiday's currently-relevant occurrence, or null when `name` is not a holiday
 * (or its date is unknown, e.g. Diwali beyond the table). "Currently-relevant" = the first
 * occurrence whose calendar day has not fully passed: before the event time it counts down; from
 * the event time until local midnight the target sits in the past (⇒ 00:00); at midnight the next
 * lookup rolls over to the following year.
 */
export function holidayTargetMs(name: string, nowMs: number): number | null {
  const key = ALIASES[name] ?? name;
  const dateForYear = HOLIDAYS[key];
  if (!dateForYear) return null;
  const year0 = new Date(nowMs).getFullYear();
  for (let i = 0; i <= 3; i++) {
    const d = dateForYear(year0 + i);
    if (!d) continue; // unknown year (e.g. a Diwali table gap) — try the next
    // Local midnight ending the event's calendar day; Date normalises day+1 across month/year ends.
    const endOfEventDay = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0).getTime();
    if (endOfEventDay > nowMs) return d.getTime();
  }
  return null;
}
