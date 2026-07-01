import { describe, it, expect } from "vitest";
import { westernEaster, nthWeekdayOfMonth, holidayTargetMs } from "../src/sim/holidays.ts";

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

  it("uses the Diwali table (extended) and returns null beyond it", () => {
    expect(holidayTargetMs("diwali", AT(2026, 1, 1))).toBe(AT(2026, 11, 8, 7)); // Nov 8, 2026
    expect(holidayTargetMs("diwali", AT(2033, 1, 1))).toBe(AT(2033, 10, 22, 7)); // Oct 22, 2033
    expect(holidayTargetMs("diwali", AT(2050, 1, 1))).toBe(null); // beyond the table
  });
});
