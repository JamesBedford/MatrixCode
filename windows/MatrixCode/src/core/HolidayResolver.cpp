#include "matrixcode/core/HolidayResolver.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <ctime>
#include <limits>
#include <optional>
#include <string>
#include <utility>

#include "matrixcode/core/Utf8.h"

namespace matrixcode {
namespace {

constexpr double kMillisecondsPerDay = 86'400'000.0;
constexpr double kUnixEpochJulianDate = 2'440'587.5;
constexpr double kPhaseEpochJulianDate = 2'451'550.09766;
constexpr double kIndianStandardTimeOffsetMilliseconds = 5.5 * 3'600'000.0;
constexpr double kPi = 3.141592653589793238462643383279502884;

struct PhaseTerm {
  double newMoonCoefficient;
  double fullMoonCoefficient;
  int powerOfE;
  int moonAnomaly;
  int sunAnomaly;
  int latitudeArgument;
  int ascendingNode;
};

constexpr std::array<PhaseTerm, 25> kPhaseTerms{{
  {-0.40720, -0.40614, 0, 1, 0, 0, 0},
  { 0.17241,  0.17302, 1, 0, 1, 0, 0},
  { 0.01608,  0.01614, 0, 2, 0, 0, 0},
  { 0.01039,  0.01043, 0, 0, 0, 2, 0},
  { 0.00739,  0.00734, 1, 1, -1, 0, 0},
  {-0.00514, -0.00515, 1, 1, 1, 0, 0},
  { 0.00208,  0.00209, 2, 0, 2, 0, 0},
  {-0.00111, -0.00111, 0, 1, 0, -2, 0},
  {-0.00057, -0.00057, 0, 1, 0, 2, 0},
  { 0.00056,  0.00056, 1, 2, 1, 0, 0},
  {-0.00042, -0.00042, 0, 3, 0, 0, 0},
  { 0.00042,  0.00042, 1, 0, 1, 2, 0},
  { 0.00038,  0.00038, 1, 0, 1, -2, 0},
  {-0.00024, -0.00024, 1, 2, -1, 0, 0},
  {-0.00017, -0.00017, 0, 0, 0, 0, 1},
  {-0.00007, -0.00007, 0, 1, 2, 0, 0},
  { 0.00004,  0.00004, 0, 2, 0, -2, 0},
  { 0.00004,  0.00004, 0, 0, 3, 0, 0},
  { 0.00003,  0.00003, 0, 1, 1, -2, 0},
  { 0.00003,  0.00003, 0, 2, 0, 2, 0},
  {-0.00003, -0.00003, 0, 1, 1, 2, 0},
  { 0.00003,  0.00003, 0, 1, -1, 2, 0},
  {-0.00002, -0.00002, 0, 1, -1, -2, 0},
  {-0.00002, -0.00002, 0, 3, 1, 0, 0},
  { 0.00002,  0.00002, 0, 4, 0, 0, 0},
}};

struct EventDate {
  int month = 0;  // zero-indexed
  int day = 1;
  int hour = 7;
};

constexpr EventDate kValentinesDate{1, 14};
constexpr EventDate kStPatricksDate{2, 17};

[[nodiscard]] std::tm LocalTime(const double epochMilliseconds) noexcept {
  const double seconds = std::floor(epochMilliseconds / 1000.0);
  const double minimum = static_cast<double>(std::numeric_limits<std::time_t>::lowest());
  const double maximum = static_cast<double>(std::numeric_limits<std::time_t>::max());
  const std::time_t raw = static_cast<std::time_t>(std::clamp(seconds, minimum, maximum));
  std::tm result{};
#if defined(_WIN32)
  if (localtime_s(&result, &raw) != 0) result = {};
#else
  if (localtime_r(&raw, &result) == nullptr) result = {};
#endif
  return result;
}

[[nodiscard]] std::tm UtcTime(const double epochMilliseconds) noexcept {
  const double seconds = std::floor(epochMilliseconds / 1000.0);
  const double minimum = static_cast<double>(std::numeric_limits<std::time_t>::lowest());
  const double maximum = static_cast<double>(std::numeric_limits<std::time_t>::max());
  const std::time_t raw = static_cast<std::time_t>(std::clamp(seconds, minimum, maximum));
  std::tm result{};
#if defined(_WIN32)
  if (gmtime_s(&result, &raw) != 0) result = {};
#else
  if (gmtime_r(&raw, &result) == nullptr) result = {};
#endif
  return result;
}

[[nodiscard]] double LocalDateMilliseconds(
    const int year, const int month, const int day, const int hour) noexcept {
  std::tm local{};
  local.tm_year = year - 1900;
  local.tm_mon = month;
  local.tm_mday = day;
  local.tm_hour = hour;
  local.tm_isdst = -1;
  return static_cast<double>(std::mktime(&local)) * 1000.0;
}

[[nodiscard]] std::pair<int, int> WesternEaster(const int year) noexcept {
  const int a = year % 19;
  const int b = year / 100;
  const int c = year % 100;
  const int d = b / 4;
  const int e = b % 4;
  const int f = (b + 8) / 25;
  const int g = (b - f + 1) / 3;
  const int h = (19 * a + b - d - g + 15) % 30;
  const int i = c / 4;
  const int k = c % 4;
  const int l = (32 + 2 * e + 2 * i - h - k) % 7;
  const int m = (a + 11 * h + 22 * l) / 451;
  const int value = h + l - 7 * m + 114;
  return {value / 31 - 1, value % 31 + 1};
}

[[nodiscard]] int NthWeekdayOfMonth(
    const int year, const int month, const int weekday, const int occurrence) noexcept {
  std::tm first{};
  first.tm_year = year - 1900;
  first.tm_mon = month;
  first.tm_mday = 1;
  first.tm_isdst = -1;
  (void)std::mktime(&first);
  const int offset = (weekday - first.tm_wday + 7) % 7;
  return 1 + offset + (occurrence - 1) * 7;
}

[[nodiscard]] double PhaseJulianDate(const double k, const bool fullMoon) noexcept {
  const double t = k / 1236.85;
  const double t2 = t * t;
  const double t3 = t2 * t;
  const double t4 = t3 * t;
  const double julianDate = kPhaseEpochJulianDate + 29.530588861 * k +
    0.00015437 * t2 - 0.000000150 * t3 + 0.00000000073 * t4;
  const double eccentricity = 1.0 - 0.002516 * t - 0.0000074 * t2;
  const double radians = kPi / 180.0;
  const double sunAnomaly =
    (2.5534 + 29.10535670 * k - 0.0000014 * t2 - 0.00000011 * t3) * radians;
  const double moonAnomaly =
    (201.5643 + 385.81693528 * k + 0.0107582 * t2 + 0.00001238 * t3 -
      0.000000058 * t4) * radians;
  const double latitudeArgument =
    (160.7108 + 390.67050284 * k - 0.0016118 * t2 - 0.00000227 * t3 +
      0.000000011 * t4) * radians;
  const double ascendingNode =
    (124.7746 - 1.56375588 * k + 0.0020672 * t2 + 0.00000215 * t3) * radians;
  double correction = 0.0;
  for (const auto& term : kPhaseTerms) {
    const double coefficient = fullMoon
      ? term.fullMoonCoefficient
      : term.newMoonCoefficient;
    correction += coefficient * std::pow(eccentricity, term.powerOfE) * std::sin(
      term.moonAnomaly * moonAnomaly + term.sunAnomaly * sunAnomaly +
      term.latitudeArgument * latitudeArgument + term.ascendingNode * ascendingNode);
  }
  return julianDate + correction;
}

[[nodiscard]] double NewMoonJulianDate(const double k) noexcept {
  return PhaseJulianDate(k, false);
}

[[nodiscard]] double FullMoonJulianDate(const double k) noexcept {
  return PhaseJulianDate(k + 0.5, true);
}

[[nodiscard]] double NormalizeDegrees(const double value) noexcept {
  const double remainder = std::fmod(value, 360.0);
  return remainder < 0.0 ? remainder + 360.0 : remainder;
}

[[nodiscard]] double SunLongitude(const double julianDate) noexcept {
  const double t = (julianDate - 2'451'545.0) / 36525.0;
  const double radians = kPi / 180.0;
  const double meanLongitude = 280.46646 + 36000.76983 * t + 0.0003032 * t * t;
  const double meanAnomaly =
    (357.52911 + 35999.05029 * t - 0.0001537 * t * t) * radians;
  const double correction =
    (1.914602 - 0.004817 * t - 0.000014 * t * t) * std::sin(meanAnomaly) +
    (0.019993 - 0.000101 * t) * std::sin(2.0 * meanAnomaly) +
    0.000289 * std::sin(3.0 * meanAnomaly);
  return NormalizeDegrees(meanLongitude + correction);
}

[[nodiscard]] std::pair<int, int> DiwaliDate(const int year) noexcept {
  constexpr std::array<std::pair<int, EventDate>, 17> known{{
    {2024, {9, 31}}, {2025, {9, 20}}, {2026, {10, 8}}, {2027, {9, 29}},
    {2028, {9, 17}}, {2029, {10, 5}}, {2030, {9, 26}}, {2031, {10, 14}},
    {2032, {10, 2}}, {2033, {9, 22}}, {2034, {10, 10}}, {2035, {9, 30}},
    {2036, {9, 19}}, {2037, {10, 7}}, {2038, {9, 27}}, {2039, {9, 17}},
    {2040, {10, 4}},
  }};
  for (const auto& [knownYear, date] : known) {
    if (knownYear == year) return {date.month, date.day};
  }

  const int estimatedIndex = static_cast<int>(
    std::floor((year - 2000.0 + 0.83) * 12.3685 + 0.5));
  const double ayanamsa = 24.1 + (year - 2024.0) * 0.0139;
  for (int index = estimatedIndex - 2; index <= estimatedIndex + 2; ++index) {
    const double julianDate = NewMoonJulianDate(index);
    const double siderealSun = NormalizeDegrees(SunLongitude(julianDate) - ayanamsa);
    if (siderealSun >= 180.0 && siderealSun < 210.0) {
      const double istMilliseconds =
        (julianDate - kUnixEpochJulianDate) * kMillisecondsPerDay +
        kIndianStandardTimeOffsetMilliseconds - kMillisecondsPerDay;
      const std::tm diwali = UtcTime(istMilliseconds);
      return {diwali.tm_mon, diwali.tm_mday};
    }
  }
  const double fallbackMilliseconds =
    (NewMoonJulianDate(estimatedIndex) - kUnixEpochJulianDate) * kMillisecondsPerDay +
    kIndianStandardTimeOffsetMilliseconds - kMillisecondsPerDay;
  const std::tm fallback = UtcTime(fallbackMilliseconds);
  return {fallback.tm_mon, fallback.tm_mday};
}

template <typename PhaseFunction>
[[nodiscard]] double NextPhaseMilliseconds(
    const double nowMilliseconds,
    PhaseFunction phase,
    const double indexOffset) noexcept {
  const double julianDateNow = nowMilliseconds / kMillisecondsPerDay + kUnixEpochJulianDate;
  int index = static_cast<int>(std::floor(
    (julianDateNow - kPhaseEpochJulianDate) / 29.530588861 - indexOffset)) - 1;
  for (int guard = 0; guard < 6; ++guard, ++index) {
    const double candidate =
      (phase(index) - kUnixEpochJulianDate) * kMillisecondsPerDay;
    if (candidate > nowMilliseconds) return candidate;
  }
  return (phase(index) - kUnixEpochJulianDate) * kMillisecondsPerDay;
}

[[nodiscard]] std::string NormalizeName(const std::string_view name) {
  std::string normalized(TrimUtf8(name));
  std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](const unsigned char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c + ('a' - 'A')) : static_cast<char>(c);
  });
  if (normalized == "xmas") return "christmas";
  if (normalized == "newyears" || normalized == "newyearseve") return "newyear";
  if (normalized == "valentine" || normalized == "valentinesday") return "valentines";
  if (normalized == "stpatrick" || normalized == "stpatricksday" || normalized == "stpaddys") {
    return "stpatricks";
  }
  if (normalized == "july4th" || normalized == "fourthofjuly" ||
      normalized == "independenceday") return "july4";
  if (normalized == "turkeyday") return "thanksgiving";
  return normalized;
}

[[nodiscard]] std::optional<EventDate> EventForYear(
    const std::string_view key, const int year) noexcept {
  if (key == "newyear") return EventDate{0, 1, 0};
  if (key == "valentines") return kValentinesDate;
  if (key == "stpatricks") return kStPatricksDate;
  if (key == "aprilfools") return EventDate{3, 1};
  if (key == "easter") {
    const auto [month, day] = WesternEaster(year);
    return EventDate{month, day};
  }
  if (key == "july4") return EventDate{6, 4};
  if (key == "halloween") return EventDate{9, 31};
  if (key == "diwali") {
    const auto [month, day] = DiwaliDate(year);
    return EventDate{month, day};
  }
  if (key == "thanksgiving") {
    return EventDate{10, NthWeekdayOfMonth(year, 10, 4, 4)};
  }
  if (key == "christmaseve") return EventDate{11, 24};
  if (key == "christmas") return EventDate{11, 25};
  return std::nullopt;
}

}  // namespace

std::optional<double> LocalDayBoundaryMilliseconds(
    const std::int64_t dayIndex,
    const std::function<std::optional<std::int64_t>(double)>& localDayAt) {
  constexpr std::int64_t millisecondsPerDay = 86'400'000;
  constexpr std::int64_t maximumExactMilliseconds = 9'007'199'254'740'991;
  if (!localDayAt || dayIndex < -maximumExactMilliseconds / millisecondsPerDay + 2 ||
      dayIndex > maximumExactMilliseconds / millisecondsPerDay - 2) return std::nullopt;
  std::int64_t before = (dayIndex - 2) * millisecondsPerDay;
  std::int64_t after = (dayIndex + 2) * millisecondsPerDay;
  const auto beforeDay = localDayAt(static_cast<double>(before));
  const auto afterDay = localDayAt(static_cast<double>(after));
  if (!beforeDay || !afterDay || *beforeDay >= dayIndex || *afterDay < dayIndex) {
    return std::nullopt;
  }
  while (after - before > 1) {
    const std::int64_t middle = before + (after - before) / 2;
    const auto middleDay = localDayAt(static_cast<double>(middle));
    if (!middleDay) return std::nullopt;
    if (*middleDay < dayIndex) before = middle;
    else after = middle;
  }
  return static_cast<double>(after);
}

FullMoonDayCache::FullMoonDayCache(Resolver resolver) : resolver_(std::move(resolver)) {}

bool FullMoonDayCache::ContainsFullMoon(const double localDayStartMs, const double localDayEndMs) {
  if (!std::isfinite(localDayStartMs) || !std::isfinite(localDayEndMs) ||
      localDayEndMs <= localDayStartMs) return false;
  if (cached_ && startMs_ == localDayStartMs && endMs_ == localDayEndMs) return fullMoonDay_;
  const double searchFrom = localDayStartMs - 1.0;
  const auto fullMoon = resolver_
    ? resolver_(searchFrom)
    : HolidayTargetMilliseconds("fullmoon", searchFrom);
  startMs_ = localDayStartMs;
  endMs_ = localDayEndMs;
  cached_ = true;
  fullMoonDay_ = fullMoon.has_value() && std::isfinite(*fullMoon) &&
    *fullMoon >= localDayStartMs && *fullMoon < localDayEndMs;
  return fullMoonDay_;
}

std::optional<std::string_view> HolidayPresetForLocalDate(
    const int localMonth, const int localDay) noexcept {
  if (localMonth == kValentinesDate.month + 1 && localDay == kValentinesDate.day) {
    return "red";
  }
  if (localMonth == kStPatricksDate.month + 1 && localDay == kStPatricksDate.day) {
    return "classic";
  }
  return std::nullopt;
}

std::optional<double> HolidayTargetMilliseconds(
    const std::string_view name, const double nowMilliseconds) {
  if (!std::isfinite(nowMilliseconds)) return std::nullopt;
  const std::string key = NormalizeName(name);
  if (key == "newmoon") {
    return NextPhaseMilliseconds(nowMilliseconds, NewMoonJulianDate, 0.0);
  }
  if (key == "fullmoon") {
    return NextPhaseMilliseconds(nowMilliseconds, FullMoonJulianDate, 0.5);
  }
  if (!EventForYear(key, 2000).has_value()) return std::nullopt;

  const int firstYear = LocalTime(nowMilliseconds).tm_year + 1900;
  for (int offset = 0; offset <= 3; ++offset) {
    const int year = firstYear + offset;
    const auto event = EventForYear(key, year);
    if (!event.has_value()) continue;
    const double target = LocalDateMilliseconds(year, event->month, event->day, event->hour);
    const double endOfEventDay = LocalDateMilliseconds(year, event->month, event->day + 1, 0);
    if (endOfEventDay > nowMilliseconds) return target;
  }
  return std::nullopt;
}

}  // namespace matrixcode
