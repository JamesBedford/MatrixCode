import { describe, it, expect } from "vitest";
import {
  westernEaster,
  nthWeekdayOfMonth,
  holidayTargetMs,
  computeDiwali,
  nextNewMoonMs,
  nextFullMoonMs,
} from "../src/sim/holidays.ts";

// Local epoch-ms; mo is 1-indexed (human-friendly).
const AT = (y: number, mo: number, d: number, h = 0, mi = 0, s = 0): number =>
  new Date(y, mo - 1, d, h, mi, s).getTime();

describe("westernEaster", () => {
  it("computes known Gregorian Easter Sundays (month 0-indexed)", () => {
    expect(westernEaster(2024)).toEqual({ month: 2, day: 31 }); // Mar 31, 2024
    expect(westernEaster(2025)).toEqual({ month: 3, day: 20 }); // Apr 20, 2025
    expect(westernEaster(2026)).toEqual({ month: 3, day: 5 }); // Apr 5, 2026
    expect(westernEaster(2027)).toEqual({ month: 2, day: 28 }); // Mar 28, 2027
  });
});

describe("nthWeekdayOfMonth", () => {
  it("finds the 4th Thursday of November (US Thanksgiving)", () => {
    expect(nthWeekdayOfMonth(2026, 10, 4, 4)).toBe(26); // Nov 26, 2026
    expect(nthWeekdayOfMonth(2024, 10, 4, 4)).toBe(28); // Nov 28, 2024
  });
});

describe("holidayTargetMs", () => {
  it("returns null for a name that is not a holiday", () => {
    expect(holidayTargetMs("nope", AT(2026, 7, 1))).toBe(null);
  });

  it("counts down to this year's Christmas 07:00 before it arrives", () => {
    expect(holidayTargetMs("christmas", AT(2026, 12, 1, 12))).toBe(AT(2026, 12, 25, 7));
  });

  it("holds this year's Christmas until midnight, then rolls to next year", () => {
    // Afternoon of Dec 25 → target is still this year's 07:00 (already past ⇒ caller shows 00:00).
    expect(holidayTargetMs("christmas", AT(2026, 12, 25, 15))).toBe(AT(2026, 12, 25, 7));
    // Just after midnight ending Dec 25 → next year's Christmas.
    expect(holidayTargetMs("christmas", AT(2026, 12, 26, 0, 0, 1))).toBe(AT(2027, 12, 25, 7));
  });

  it("targets New Year at midnight Jan 1 and holds through Jan 1", () => {
    expect(holidayTargetMs("newyear", AT(2026, 12, 31, 23))).toBe(AT(2027, 1, 1, 0));
    expect(holidayTargetMs("newyear", AT(2027, 1, 1, 12))).toBe(AT(2027, 1, 1, 0)); // holds all day
    expect(holidayTargetMs("newyear", AT(2027, 1, 2, 0, 0, 1))).toBe(AT(2028, 1, 1, 0));
  });

  it("resolves aliases and computed dates (Easter, July 4th, Thanksgiving)", () => {
    const now = AT(2026, 6, 1);
    expect(holidayTargetMs("july4th", now)).toBe(holidayTargetMs("july4", now));
    expect(holidayTargetMs("july4", now)).toBe(AT(2026, 7, 4, 7));
    expect(holidayTargetMs("easter", AT(2026, 1, 1))).toBe(AT(2026, 4, 5, 7)); // Easter 2026 = Apr 5
    expect(holidayTargetMs("thanksgiving", AT(2026, 1, 1))).toBe(AT(2026, 11, 26, 7)); // Nov 26, 2026
  });

  it("normalizes whitespace and case like the native token resolver", () => {
    const now = AT(2026, 12, 1, 12);
    expect(holidayTargetMs(" Christmas ", now)).toBe(holidayTargetMs("christmas", now));
    expect(holidayTargetMs("XMAS", now)).toBe(holidayTargetMs("christmas", now));
  });

  it("uses the Diwali table for verified years and computes beyond it", () => {
    expect(holidayTargetMs("diwali", AT(2026, 1, 1))).toBe(AT(2026, 11, 8, 7)); // table: Nov 8, 2026
    expect(holidayTargetMs("diwali", AT(2033, 1, 1))).toBe(AT(2033, 10, 22, 7)); // table: Oct 22, 2033
    // Beyond the table it is computed (never null) and lands on a plausible Oct/Nov 07:00 date.
    const far = holidayTargetMs("diwali", AT(2099, 6, 1));
    expect(far).not.toBe(null);
    const d = new Date(far!);
    expect(d.getFullYear()).toBe(2099);
    expect([9, 10]).toContain(d.getMonth()); // October or November
    expect(d.getHours()).toBe(7);
  });
});

describe("nextNewMoonMs", () => {
  it("finds the next new moon after a given instant (2024-11-01 ~12:47 UTC)", () => {
    const d = new Date(nextNewMoonMs(Date.UTC(2024, 9, 20))); // from Oct 20, 2024
    expect(d.getUTCFullYear()).toBe(2024);
    expect(d.getUTCMonth()).toBe(10); // November
    expect(d.getUTCDate()).toBe(1);
  });

  it("returns a time strictly after now and within one synodic month", () => {
    const now = Date.UTC(2030, 2, 15, 9, 30);
    const nm = nextNewMoonMs(now);
    expect(nm).toBeGreaterThan(now);
    expect(nm - now).toBeLessThanOrEqual(29.6 * 86_400_000);
  });

  it("advances to the following new moon once one passes (~29.5-day gap)", () => {
    const nm1 = nextNewMoonMs(Date.UTC(2024, 9, 20)); // → Nov 1, 2024
    const nm2 = nextNewMoonMs(nm1 + 1000); // just after → Dec 1, 2024
    const gapDays = (nm2 - nm1) / 86_400_000;
    expect(gapDays).toBeGreaterThan(29);
    expect(gapDays).toBeLessThan(30.5);
  });

  it("holidayTargetMs('newmoon', now) returns the next new moon", () => {
    const now = Date.UTC(2026, 6, 1);
    expect(holidayTargetMs("newmoon", now)).toBe(nextNewMoonMs(now));
  });
});

describe("nextFullMoonMs", () => {
  it("finds the next full moon after a given instant (2024-11-15 ~21:28 UTC)", () => {
    const d = new Date(nextFullMoonMs(Date.UTC(2024, 10, 1))); // from Nov 1, 2024
    expect(d.getUTCFullYear()).toBe(2024);
    expect(d.getUTCMonth()).toBe(10); // November
    expect(d.getUTCDate()).toBe(15);
  });

  it("returns a time strictly after now and within one synodic month", () => {
    const now = Date.UTC(2031, 5, 3, 4, 15);
    const fm = nextFullMoonMs(now);
    expect(fm).toBeGreaterThan(now);
    expect(fm - now).toBeLessThanOrEqual(29.6 * 86_400_000);
  });

  it("falls roughly midway between the surrounding new moons (~14.75 days after one)", () => {
    const now = Date.UTC(2026, 6, 1);
    const nm = nextNewMoonMs(now);
    const fm = nextFullMoonMs(nm); // the full moon after that new moon
    const gapDays = (fm - nm) / 86_400_000;
    expect(gapDays).toBeGreaterThan(13);
    expect(gapDays).toBeLessThan(16);
  });

  it("holidayTargetMs('fullmoon', now) returns the next full moon", () => {
    const now = Date.UTC(2026, 6, 1);
    expect(holidayTargetMs("fullmoon", now)).toBe(nextFullMoonMs(now));
  });
});

describe("computeDiwali", () => {
  // The published dates for these years are authoritative; the astronomical computation must
  // reproduce them within a day, which validates the new-moon algorithm end to end.
  const PUBLISHED: Array<[number, number, number]> = [
    [2024, 9, 31], [2026, 10, 8], [2028, 9, 17], [2030, 9, 26],
    [2033, 9, 22], [2037, 10, 7], [2040, 10, 4],
  ];
  it("reproduces the published Diwali dates within one day", () => {
    for (const [year, mo, day] of PUBLISHED) {
      const got = computeDiwali(year);
      const diffDays = Math.abs(new Date(year, got[0], got[1]).getTime() - new Date(year, mo, day).getTime()) / 86_400_000;
      expect(diffDays, `Diwali ${year}: computed [${got}], published [${mo},${day}]`).toBeLessThanOrEqual(1);
    }
  });
});
