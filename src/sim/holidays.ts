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

// Diwali (Lakshmi Puja) is lunisolar and region-dependent. Verified published dates ([month0, day],
// IST) are tabled as authoritative overrides; any year outside the table is computed astronomically
// (see computeDiwali), so {countdown:diwali} works indefinitely.
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

// Beyond the verified table, Diwali is computed: it is the Amavasya (new moon) of Kartik, so we
// find the new moon in the mid-Oct..mid-Nov window and take the day before it (Lakshmi Puja is
// observed at that evening's pradosh). Reckoned in Indian Standard Time. ~±1 day vs. Panchang.
const IST_OFFSET_MS = 5.5 * 3_600_000;

/** Julian Ephemeris Day of the k-th new moon after 2000, via Meeus's algorithm (accurate to minutes). */
function newMoonJDE(k: number): number {
  const T = k / 1236.85;
  const T2 = T * T, T3 = T2 * T, T4 = T3 * T;
  const JDE = 2451550.09766 + 29.530588861 * k + 0.00015437 * T2 - 0.000000150 * T3 + 0.00000000073 * T4;
  const E = 1 - 0.002516 * T - 0.0000074 * T2;
  const rad = Math.PI / 180;
  const M = (2.5534 + 29.10535670 * k - 0.0000014 * T2 - 0.00000011 * T3) * rad; // Sun's mean anomaly
  const Mp = (201.5643 + 385.81693528 * k + 0.0107582 * T2 + 0.00001238 * T3 - 0.000000058 * T4) * rad; // Moon's
  const F = (160.7108 + 390.67050284 * k - 0.0016118 * T2 - 0.00000227 * T3 + 0.000000011 * T4) * rad; // arg. latitude
  const Om = (124.7746 - 1.56375588 * k + 0.0020672 * T2 + 0.00000215 * T3) * rad; // ascending node
  const c =
      -0.40720 * Math.sin(Mp)
    + 0.17241 * E * Math.sin(M)
    + 0.01608 * Math.sin(2 * Mp)
    + 0.01039 * Math.sin(2 * F)
    + 0.00739 * E * Math.sin(Mp - M)
    - 0.00514 * E * Math.sin(Mp + M)
    + 0.00208 * E * E * Math.sin(2 * M)
    - 0.00111 * Math.sin(Mp - 2 * F)
    - 0.00057 * Math.sin(Mp + 2 * F)
    + 0.00056 * E * Math.sin(2 * Mp + M)
    - 0.00042 * Math.sin(3 * Mp)
    + 0.00042 * E * Math.sin(M + 2 * F)
    + 0.00038 * E * Math.sin(M - 2 * F)
    - 0.00024 * E * Math.sin(2 * Mp - M)
    - 0.00017 * Math.sin(Om)
    - 0.00007 * Math.sin(Mp + 2 * M)
    + 0.00004 * Math.sin(2 * Mp - 2 * F)
    + 0.00004 * Math.sin(3 * M)
    + 0.00003 * Math.sin(Mp + M - 2 * F)
    + 0.00003 * Math.sin(2 * Mp + 2 * F)
    - 0.00003 * Math.sin(Mp + M + 2 * F)
    + 0.00003 * Math.sin(Mp - M + 2 * F)
    - 0.00002 * Math.sin(Mp - M - 2 * F)
    - 0.00002 * Math.sin(3 * Mp + M)
    + 0.00002 * Math.sin(4 * Mp);
  return JDE + c;
}

/** Sun's apparent tropical longitude (degrees) at `jde`, low-accuracy (Meeus ch. 25) — ample here. */
function sunLongitude(jde: number): number {
  const T = (jde - 2451545) / 36525;
  const rad = Math.PI / 180;
  const L0 = 280.46646 + 36000.76983 * T + 0.0003032 * T * T;
  const M = (357.52911 + 35999.05029 * T - 0.0001537 * T * T) * rad;
  const C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * Math.sin(M)
    + (0.019993 - 0.000101 * T) * Math.sin(2 * M)
    + 0.000289 * Math.sin(3 * M);
  return (((L0 + C) % 360) + 360) % 360;
}

/**
 * IST calendar [month0, day] of Diwali (Lakshmi Puja) for `year`. Diwali is the Kartik Amavasya —
 * the new moon while the Sun is in sidereal Libra — observed on the evening before that new moon.
 * The solar-longitude test uniquely picks the right lunation (a date window cannot, since Diwali's
 * new moon spans nearly a full month across years).
 */
export function computeDiwali(year: number): [number, number] {
  const kEst = Math.round((year - 2000 + 0.83) * 12.3685); // ≈ a new moon in late Oct / early Nov
  const ayanamsa = 24.1 + (year - 2024) * 0.0139; // Lahiri ayanamsa (approx): tropical → sidereal
  for (let k = kEst - 2; k <= kEst + 2; k++) {
    const jde = newMoonJDE(k);
    const siderealSun = (((sunLongitude(jde) - ayanamsa) % 360) + 360) % 360;
    if (siderealSun >= 180 && siderealSun < 210) {
      // Baking the IST offset into the epoch lets getUTC* read the IST wall-clock directly.
      const nmIst = new Date((jde - 2440587.5) * 86_400_000 + IST_OFFSET_MS);
      const diwali = new Date(nmIst.getTime() - 86_400_000); // the evening before the new moon
      return [diwali.getUTCMonth(), diwali.getUTCDate()];
    }
  }
  // Fallback (not expected): the estimated new moon's eve.
  const diwali = new Date((newMoonJDE(kEst) - 2440587.5) * 86_400_000 + IST_OFFSET_MS - 86_400_000);
  return [diwali.getUTCMonth(), diwali.getUTCDate()];
}

/** Epoch-ms (UTC) of the next new moon strictly after `nowMs` — for the recurring {countdown:newmoon}. */
export function nextNewMoonMs(nowMs: number): number {
  const jdNow = nowMs / 86_400_000 + 2440587.5;
  let k = Math.floor((jdNow - 2451550.09766) / 29.530588861) - 1; // start ~one lunation before now
  for (let guard = 0; guard < 6; guard++, k++) {
    const ms = (newMoonJDE(k) - 2440587.5) * 86_400_000;
    if (ms > nowMs) return ms;
  }
  return (newMoonJDE(k) - 2440587.5) * 86_400_000; // fallback (not expected)
}

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
  diwali: (y) => { const md = DIWALI[y] ?? computeDiwali(y); return new Date(y, md[0], md[1], H, 0, 0); },
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

/** Canonical built-in token names (annual holidays in calendar order, then the recurring new moon) — for the editor hover. */
export const HOLIDAY_TOKENS: string[] = [...Object.keys(HOLIDAYS), "newmoon"];

/**
 * Epoch-ms of the holiday's currently-relevant occurrence, or null when `name` is not a holiday
 * (or its date is unknown, e.g. Diwali beyond the table). "Currently-relevant" = the first
 * occurrence whose calendar day has not fully passed: before the event time it counts down; from
 * the event time until local midnight the target sits in the past (⇒ 00:00); at midnight the next
 * lookup rolls over to the following year.
 */
export function holidayTargetMs(name: string, nowMs: number): number | null {
  const key = ALIASES[name] ?? name;
  if (key === "newmoon") return nextNewMoonMs(nowMs); // recurring (~monthly), not a fixed annual date
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
