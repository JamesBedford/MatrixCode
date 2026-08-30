#include <array>
#include <cmath>
#include <ctime>
#include <string>

#include "TestHarness.h"
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
}
