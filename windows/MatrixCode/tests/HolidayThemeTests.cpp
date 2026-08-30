#include <array>
#include <chrono>
#include <cmath>
#include <ctime>
#include <limits>
#include <string>

#include "TestHarness.h"
#include "matrixcode/core/HolidayResolver.h"
#include "matrixcode/core/Settings.h"

namespace {

double LocalMilliseconds(const int year, const int month, const int day) {
  std::tm local{};
  local.tm_year = year - 1900;
  local.tm_mon = month - 1;
  local.tm_mday = day;
  local.tm_isdst = -1;
  return static_cast<double>(std::mktime(&local)) * 1000.0;
}

double UtcMilliseconds(
    const int year, const unsigned month, const unsigned day,
    const int hour = 0, const int minute = 0) {
  const auto instant = std::chrono::sys_days{
    std::chrono::year{year} / std::chrono::month{month} / std::chrono::day{day}} +
    std::chrono::hours{hour} + std::chrono::minutes{minute};
  return std::chrono::duration<double, std::milli>(instant.time_since_epoch()).count();
}

matrixcode::Controls EffectiveControlsAtOffset(
    const matrixcode::Controls& controls, const double nowMilliseconds,
    const int offsetHours, matrixcode::FullMoonDayCache& cache) {
  const auto instant = std::chrono::sys_time<std::chrono::milliseconds>{
    std::chrono::milliseconds{static_cast<std::int64_t>(std::floor(nowMilliseconds))}};
  const auto localStart = std::chrono::floor<std::chrono::days>(instant +
    std::chrono::hours{offsetHours});
  const auto localEnd = localStart + std::chrono::days{1};
  const auto startMs = std::chrono::duration<double, std::milli>(
    (localStart - std::chrono::hours{offsetHours}).time_since_epoch()).count();
  const auto endMs = std::chrono::duration<double, std::milli>(
    (localEnd - std::chrono::hours{offsetHours}).time_since_epoch()).count();
  const std::chrono::year_month_day date{localStart};
  return matrixcode::EffectiveControlsForLocalDate(
    controls, static_cast<int>(static_cast<unsigned>(date.month())),
    static_cast<int>(static_cast<unsigned>(date.day())), cache.ContainsFullMoon(startMs, endMs));
}

matrixcode::Controls EffectiveControlsAt(
    const matrixcode::Controls& controls, const double nowMilliseconds) {
  const auto seconds = static_cast<std::time_t>(std::floor(nowMilliseconds / 1000.0));
  std::tm local{};
#if defined(_WIN32)
  MX_EXPECT_EQ(localtime_s(&local, &seconds), 0);
#else
  MX_EXPECT(localtime_r(&seconds, &local) != nullptr);
#endif
  return matrixcode::EffectiveControlsForLocalDate(controls, local.tm_mon + 1, local.tm_mday);
}

void ExpectPaletteEqual(
    const matrixcode::ColorPalette& actual, const matrixcode::ColorPalette& expected) {
  MX_EXPECT_EQ(actual.background, expected.background);
  MX_EXPECT_EQ(actual.tail, expected.tail);
  MX_EXPECT_EQ(actual.body, expected.body);
  MX_EXPECT_EQ(actual.bright, expected.bright);
  MX_EXPECT_EQ(actual.head, expected.head);
}

}  // namespace

void RunHolidayThemeTests() {
  using namespace matrixcode;
  auto settings = DefaultSettings();
  settings.controls.preset = "custom";
  settings.controls.customColor = "#123ABC";
  settings.controls.speed = 2.0;
  settings.controls.density = 8.0;
  const std::string saved = EncodeSettingsUtf8(settings, false);

  struct Holiday { int month; int day; const char* preset; };
  constexpr std::array<Holiday, 2> holidays{{{2, 14, "red"}, {3, 17, "classic"}}};
  for (const int year : {2024, 2026, 2032, 2100}) {
    for (const auto& holiday : holidays) {
      const double start = LocalMilliseconds(year, holiday.month, holiday.day);
      const double end = LocalMilliseconds(year, holiday.month, holiday.day + 1);
      MX_EXPECT_EQ(EffectiveControlsAt(settings.controls, start - 1.0).preset,
        std::string("custom"));
      Controls expected = settings.controls;
      expected.preset = holiday.preset;
      for (const double instant : {start, start + 1.0, (start + end) / 2.0, end - 1.0}) {
        const auto effective = EffectiveControlsAt(settings.controls, instant);
        MX_EXPECT_EQ(effective.preset, std::string(holiday.preset));
        ExpectPaletteEqual(PaletteForControls(effective), PaletteForControls(expected));
        MX_EXPECT_EQ(effective.customColor, settings.controls.customColor);
        MX_EXPECT_EQ(effective.speed, settings.controls.speed);
        MX_EXPECT_EQ(effective.density, settings.controls.density);
      }
      const auto restored = EffectiveControlsAt(settings.controls, end);
      MX_EXPECT_EQ(restored.preset, std::string("custom"));
      ExpectPaletteEqual(PaletteForControls(restored), PaletteForControls(settings.controls));
    }
  }
  MX_EXPECT_EQ(EncodeSettingsUtf8(settings, false), saved);

  // Repeated forward/backward clock changes do not latch an override or consult
  // simulated time. A changed local date (including a timezone jump) is sufficient.
  for (const auto& date : std::array<Holiday, 6>{{
      {3, 17, "classic"}, {2, 14, "red"}, {2, 13, "custom"},
      {3, 18, "custom"}, {2, 14, "red"}, {3, 17, "classic"}}}) {
    MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, date.month, date.day).preset,
      std::string(date.preset));
  }

  settings.controls.preset = "gold";
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 2, 14).preset, std::string("red"));
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 3, 17).preset,
    std::string("classic"));
  MX_EXPECT_EQ(settings.controls.preset, std::string("gold"));
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 3, 18).preset, std::string("gold"));

  // Changes made during a holiday remain selected and become visible afterward.
  settings.controls.preset = "blue";
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 2, 14).preset, std::string("red"));
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 2, 15).preset, std::string("blue"));
  settings.controls.preset = "custom";
  settings.controls.customColor = "#987654";
  const auto customSaved = EncodeSettingsUtf8(settings, false);
  MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, 3, 17).preset,
    std::string("classic"));
  const auto customRestored = EffectiveControlsForLocalDate(settings.controls, 3, 18);
  MX_EXPECT_EQ(customRestored.preset, std::string("custom"));
  MX_EXPECT_EQ(customRestored.customColor, std::string("#987654"));
  ExpectPaletteEqual(PaletteForControls(customRestored), PaletteForControls(settings.controls));
  MX_EXPECT_EQ(EncodeSettingsUtf8(settings, false), customSaved);

  // Other dates and invalid month/day values have no special theme.
  for (const auto& date : std::array<std::array<int, 2>, 7>{{
      {{1, 14}}, {{2, 17}}, {{2, 29}}, {{3, 14}}, {{12, 25}}, {{0, 14}}, {{3, 0}}}}) {
    MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, date[0], date[1]).preset,
      std::string("custom"));
  }

  // USNO's 2026 phase table lists Aug 28 at 04:18 UT. The shared astronomical
  // approximation must place that event on the same local day, not a UTC-only day.
  // https://aa.usno.navy.mil/calculated/moon/phases?year=2026
  FullMoonDayCache moonCache;
  const auto augustMoon = HolidayTargetMilliseconds("fullmoon", UtcMilliseconds(2026, 8, 27));
  MX_EXPECT(augustMoon.has_value());
  MX_EXPECT(std::abs(*augustMoon - UtcMilliseconds(2026, 8, 28, 4, 18)) < 5.0 * 60'000.0);
  struct MoonDay { int offsetHours; double startMs; double endMs; };
  const std::array<MoonDay, 3> augustDays{{
    {-7, UtcMilliseconds(2026, 8, 27, 7), UtcMilliseconds(2026, 8, 28, 7)},
    {1, UtcMilliseconds(2026, 8, 27, 23), UtcMilliseconds(2026, 8, 28, 23)},
    {9, UtcMilliseconds(2026, 8, 27, 15), UtcMilliseconds(2026, 8, 28, 15)},
  }};
  Controls white = settings.controls;
  white.preset = "white";
  for (const auto& day : augustDays) {
    MX_EXPECT(moonCache.ContainsFullMoon(day.startMs, day.endMs));
    MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, day.startMs - 1.0,
      day.offsetHours, moonCache).preset, std::string("custom"));
    for (const double instant : {day.startMs, *augustMoon - 1.0, *augustMoon + 1.0, day.endMs - 1.0}) {
      const auto effective = EffectiveControlsAtOffset(
        settings.controls, instant, day.offsetHours, moonCache);
      MX_EXPECT_EQ(effective.preset, std::string("white"));
      ExpectPaletteEqual(PaletteForControls(effective), PaletteForControls(white));
      MX_EXPECT_EQ(effective.customColor, settings.controls.customColor);
    }
    MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, day.endMs,
      day.offsetHours, moonCache).preset, std::string("custom"));
  }

  // The same instant can belong to a full-moon date in Tokyo but not Los Angeles.
  const double timezoneChange = UtcMilliseconds(2026, 8, 28, 8);
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, timezoneChange, -7, moonCache).preset,
    std::string("custom"));
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, timezoneChange, 9, moonCache).preset,
    std::string("white"));
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, timezoneChange, -7, moonCache).preset,
    std::string("custom"));

  // Both full moons in May count; the new moon and neighbouring dates do not.
  for (const unsigned day : {1u, 31u}) {
    MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, UtcMilliseconds(2026, 5, day, 12),
      0, moonCache).preset, std::string("white"));
  }
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, UtcMilliseconds(2026, 8, 12, 12),
    0, moonCache).preset, std::string("custom"));
  for (const auto& holiday : holidays) {
    const int year = holiday.month == 2 ? 2033 : 2041;
    const auto start = UtcMilliseconds(year, static_cast<unsigned>(holiday.month),
      static_cast<unsigned>(holiday.day));
    const auto end = UtcMilliseconds(year, static_cast<unsigned>(holiday.month),
      static_cast<unsigned>(holiday.day + 1));
    MX_EXPECT(moonCache.ContainsFullMoon(start, end));
    MX_EXPECT_EQ(EffectiveControlsForLocalDate(settings.controls, holiday.month, holiday.day,
      true).preset, std::string(holiday.preset));
  }

  // Actual New York DST days have 23/25-hour epoch intervals. The 2060 event
  // occurs after the first 24 hours of its local date and must still be included.
  MX_EXPECT(moonCache.ContainsFullMoon(
    UtcMilliseconds(2017, 3, 12, 5), UtcMilliseconds(2017, 3, 13, 4)));
  MX_EXPECT(moonCache.ContainsFullMoon(
    UtcMilliseconds(2033, 11, 6, 4), UtcMilliseconds(2033, 11, 7, 5)));
  MX_EXPECT(moonCache.ContainsFullMoon(
    UtcMilliseconds(2060, 11, 7, 4), UtcMilliseconds(2060, 11, 8, 5)));
  MX_EXPECT(!moonCache.ContainsFullMoon(
    UtcMilliseconds(2060, 11, 7, 4), UtcMilliseconds(2060, 11, 8, 4)));

  const auto localDayConverter = [](const double transitionMs, const int beforeHours,
      const int afterHours) {
    return [=](const double utcMs) -> std::optional<std::int64_t> {
      const double localMs = utcMs + (utcMs < transitionMs ? beforeHours : afterHours) * 3'600'000.0;
      return static_cast<std::int64_t>(std::floor(localMs / 86'400'000.0));
    };
  };
  const auto dayIndex = [](const int year, const unsigned month, const unsigned day) {
    return std::chrono::sys_days{std::chrono::year{year} / std::chrono::month{month} /
      std::chrono::day{day}}.time_since_epoch().count();
  };

  // Santiago skips midnight on this real full-moon date. Its first valid instant
  // is 01:00, and the preceding day's end must resolve to exactly that instant.
  const auto santiago = localDayConverter(UtcMilliseconds(2025, 9, 7, 4), -4, -3);
  const auto santiagoStart = LocalDayBoundaryMilliseconds(dayIndex(2025, 9, 7), santiago);
  const auto santiagoEnd = LocalDayBoundaryMilliseconds(dayIndex(2025, 9, 8), santiago);
  MX_EXPECT_EQ(santiagoStart, std::optional<double>(UtcMilliseconds(2025, 9, 7, 4)));
  MX_EXPECT_EQ(santiagoEnd, std::optional<double>(UtcMilliseconds(2025, 9, 8, 3)));
  MX_EXPECT_EQ(*santiagoEnd - *santiagoStart, 23.0 * 3'600'000.0);
  MX_EXPECT(moonCache.ContainsFullMoon(*santiagoStart, *santiagoEnd));
  MX_EXPECT_EQ(santiago(*santiagoStart - 1.0),
    std::optional<std::int64_t>(dayIndex(2025, 9, 6)));
  MX_EXPECT_EQ(santiago(*santiagoStart), std::optional<std::int64_t>(dayIndex(2025, 9, 7)));

  // A repeated midnight begins at its earliest occurrence, not the second one.
  const auto repeatedMidnight = localDayConverter(UtcMilliseconds(2026, 11, 1, 5), -4, -5);
  const auto repeatedStart = LocalDayBoundaryMilliseconds(dayIndex(2026, 11, 1), repeatedMidnight);
  const auto repeatedEnd = LocalDayBoundaryMilliseconds(dayIndex(2026, 11, 2), repeatedMidnight);
  MX_EXPECT_EQ(repeatedStart, std::optional<double>(UtcMilliseconds(2026, 11, 1, 4)));
  MX_EXPECT_EQ(repeatedEnd, std::optional<double>(UtcMilliseconds(2026, 11, 2, 5)));
  MX_EXPECT_EQ(*repeatedEnd - *repeatedStart, 25.0 * 3'600'000.0);

  // Samoa's missing Dec 30 shares Dec 31's boundary, so Dec 29 still has an end.
  const auto skippedDate = localDayConverter(UtcMilliseconds(2011, 12, 30, 10), -10, 14);
  MX_EXPECT_EQ(LocalDayBoundaryMilliseconds(dayIndex(2011, 12, 30), skippedDate),
    std::optional<double>(UtcMilliseconds(2011, 12, 30, 10)));
  MX_EXPECT_EQ(LocalDayBoundaryMilliseconds(dayIndex(2011, 12, 30), skippedDate),
    LocalDayBoundaryMilliseconds(dayIndex(2011, 12, 31), skippedDate));
  MX_EXPECT(!LocalDayBoundaryMilliseconds(0,
    [](double) -> std::optional<std::int64_t> { return std::nullopt; }).has_value());
  MX_EXPECT(!LocalDayBoundaryMilliseconds(std::numeric_limits<std::int64_t>::max(),
    santiago).has_value());

  int calculations = 0;
  double injectedMoon = 1000.0;
  FullMoonDayCache injected([&](const double from) -> std::optional<double> {
    ++calculations;
    MX_EXPECT(from < injectedMoon);
    return injectedMoon;
  });
  MX_EXPECT(injected.ContainsFullMoon(1000.0, 2000.0));
  MX_EXPECT(injected.ContainsFullMoon(1000.0, 2000.0));
  MX_EXPECT_EQ(calculations, 1);
  MX_EXPECT(!injected.ContainsFullMoon(0.0, 1000.0)); // End midnight is exclusive.
  MX_EXPECT_EQ(calculations, 2);
  MX_EXPECT(injected.ContainsFullMoon(1000.0, 2000.0)); // Backward/forward date changes recompute.
  MX_EXPECT_EQ(calculations, 3);
  MX_EXPECT(injected.ContainsFullMoon(1000.0, 2500.0)); // Changed timezone/DST end boundary.
  MX_EXPECT_EQ(calculations, 4);
  MX_EXPECT(!injected.ContainsFullMoon(1000.0, 1000.0));
  MX_EXPECT(!injected.ContainsFullMoon(2000.0, 1000.0));
  MX_EXPECT(!injected.ContainsFullMoon(std::numeric_limits<double>::quiet_NaN(), 1000.0));
  MX_EXPECT(!injected.ContainsFullMoon(1000.0, std::numeric_limits<double>::infinity()));
  MX_EXPECT_EQ(calculations, 4);
  FullMoonDayCache invalidPhase([](double) -> std::optional<double> {
    return std::numeric_limits<double>::quiet_NaN();
  });
  MX_EXPECT(!invalidPhase.ContainsFullMoon(0.0, 1000.0));
  FullMoonDayCache missingPhase([](double) -> std::optional<double> { return std::nullopt; });
  MX_EXPECT(!missingPhase.ContainsFullMoon(0.0, 1000.0));

  MX_EXPECT_EQ(EncodeSettingsUtf8(settings, false), customSaved);
  settings.controls.preset = "blue";
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, *augustMoon, 0, moonCache).preset,
    std::string("white"));
  MX_EXPECT_EQ(EffectiveControlsAtOffset(settings.controls, UtcMilliseconds(2026, 8, 29),
    0, moonCache).preset, std::string("blue"));
  MX_EXPECT_EQ(settings.controls.preset, std::string("blue"));
  MX_EXPECT_EQ(settings.controls.customColor, std::string("#987654"));
}
