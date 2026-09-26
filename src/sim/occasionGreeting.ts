import { ST_PATRICKS_DAY, VALENTINES_DAY } from "../config/holidayDates.ts";
import { isFullMoonLocalDate } from "./fullMoon.ts";

/**
 * The in-rain greeting for a local calendar occasion, or null on an ordinary day.
 * Fixed holidays win over a full moon. Callers show it first, even when saved messages are off.
 */
export function occasionGreeting(localDate = new Date()): string | null {
  const month = localDate.getMonth() + 1;
  const day = localDate.getDate();
  if (month === VALENTINES_DAY.month && day === VALENTINES_DAY.day) return "happy valentine's day!";
  if (month === 12 && day === 25) return "happy christmas";
  if (month === ST_PATRICKS_DAY.month && day === ST_PATRICKS_DAY.day) return "happy st. patrick's day";
  if (isFullMoonLocalDate(localDate)) return "happy full moon";
  return null;
}
