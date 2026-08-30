#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string_view>

namespace matrixcode {

/**
 * Resolve a built-in annual holiday or recurring lunar phase to its currently
 * relevant epoch-millisecond target. Annual dates use the process's local
 * timezone and remain current until local midnight at the end of the event day.
 */
[[nodiscard]] std::optional<double> HolidayTargetMilliseconds(
  std::string_view name,
  double nowMilliseconds);

/** Annual full-day colour overrides, using one-based local Gregorian month/day. */
[[nodiscard]] std::optional<std::string_view> HolidayPresetForLocalDate(
  int localMonth,
  int localDay) noexcept;

/** First UTC millisecond whose local Gregorian day reaches the requested day.
 * Day indices count calendar days from 1970-01-01. UTC-to-local conversion avoids
 * ambiguous/nonexistent midnight; a skipped date shares the following boundary.
 */
[[nodiscard]] std::optional<double> LocalDayBoundaryMilliseconds(
  std::int64_t dayIndex,
  const std::function<std::optional<std::int64_t>(double)>& localDayAt);

/** One-entry cache keyed by actual local-calendar-day epoch boundaries, not month/day. */
class FullMoonDayCache final {
 public:
  using Resolver = std::function<std::optional<double>(double)>;

  explicit FullMoonDayCache(Resolver resolver = {});
  [[nodiscard]] bool ContainsFullMoon(double localDayStartMs, double localDayEndMs);

 private:
  Resolver resolver_;
  bool cached_ = false;
  double startMs_ = 0.0;
  double endMs_ = 0.0;
  bool fullMoonDay_ = false;
};

}  // namespace matrixcode
