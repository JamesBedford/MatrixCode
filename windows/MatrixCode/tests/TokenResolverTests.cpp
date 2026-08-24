#include <cmath>
#include <ctime>
#include <limits>
#include <string>

#include "TestHarness.h"
#include "matrixcode/core/HolidayResolver.h"
#include "matrixcode/core/TokenResolver.h"

namespace {

double LocalMilliseconds(
    const int year,
    const int month,
    const int day,
    const int hour = 0,
    const int minute = 0,
    const int second = 0) {
  std::tm local{};
  local.tm_year = year - 1900;
  local.tm_mon = month - 1;
  local.tm_mday = day;
  local.tm_hour = hour;
  local.tm_min = minute;
  local.tm_sec = second;
  local.tm_isdst = -1;
  return static_cast<double>(std::mktime(&local)) * 1000.0;
}

}  // namespace

void RunTokenResolverTests() {
  using namespace matrixcode;

  MX_EXPECT_EQ(GreetingForLocalHour(0), std::string("PARTY ON"));
  MX_EXPECT_EQ(GreetingForLocalHour(4), std::string("GOOD MORNING"));
  MX_EXPECT_EQ(GreetingForLocalHour(12), std::string("GOOD AFTERNOON"));
  MX_EXPECT_EQ(GreetingForLocalHour(18), std::string("GOOD EVENING"));
  MX_EXPECT_EQ(GreetingForLocalHour(23), std::string("GOOD NIGHT"));

  MX_EXPECT_EQ(FormatCountdown(0.0), std::string("00:00"));
  MX_EXPECT_EQ(FormatCountdown(-5000.0), std::string("00:00"));
  MX_EXPECT_EQ(FormatCountdown((5 * 3600 + 6 * 60 + 7) * 1000.0), std::string("05:06:07"));
  MX_EXPECT_EQ(
    FormatCountdown((2 * 86400 + 3 * 3600 + 4 * 60 + 5) * 1000.0),
    std::string("02:03:04:05"));
  MX_EXPECT_EQ(
    FormatCountdown(std::numeric_limits<double>::quiet_NaN()),
    std::string("00:00"));

  TokenContext context;
  context.name = "Trinity";
  context.nowMilliseconds = LocalMilliseconds(2026, 7, 1, 13, 45, 30);
  context.runStartMilliseconds = context.nowMilliseconds - 3661000.0;
  context.framesPerSecond = 59.6;
  MX_EXPECT_EQ(
    ResolveTokens("{greeting}, {name}. {time} / {time:%I:%M %p} / {uptime} / {fps}", context),
    std::string("GOOD AFTERNOON, Trinity. 13:45 / 01:45 PM / 01:01:01 / 60 FPS"));
  MX_EXPECT_EQ(
    ResolveTokens("{time:%Y-%m-%d %A %a %B %b %j %% %q}", context),
    std::string("2026-07-01 Wednesday Wed July Jul 182 % %q"));

  context.name = "   ";
  MX_EXPECT_EQ(ResolveTokens("{name}", context), std::string(kDefaultUserName));
  context.name = "\xC2\xA0" "Trinity" "\xEF\xBB\xBF";
  MX_EXPECT_EQ(ResolveTokens("{name}", context), std::string("Trinity"));
  MX_EXPECT_EQ(ResolveTokens("keep {foo} and {bar}", context), std::string("keep {foo} and {bar}"));
  MX_EXPECT_EQ(ResolveTokens("{{name}", context), std::string("{Trinity"));

  context.countdownTargetMilliseconds = context.nowMilliseconds + 60000.0;
  context.moments["born"] = context.nowMilliseconds - 120000.0;
  context.moments["unset"] = std::nullopt;
  MX_EXPECT_EQ(ResolveTokens("{countdown}", context), std::string("01:00"));
  MX_EXPECT_EQ(ResolveTokens("{countup: born }", context), std::string("02:00"));
  MX_EXPECT_EQ(ResolveTokens("{countdown:unset}", context), std::string("00:00"));
  MX_EXPECT_EQ(ResolveTokens("{countdown:unknown}", context), std::string("00:00"));

  context.nowMilliseconds = LocalMilliseconds(2026, 12, 24, 6, 0, 0);
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds(" xmas ", context.nowMilliseconds),
    std::optional<double>(LocalMilliseconds(2026, 12, 25, 7, 0, 0)));
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds("thanksgiving", LocalMilliseconds(2026, 11, 1)),
    std::optional<double>(LocalMilliseconds(2026, 11, 26, 7, 0, 0)));
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds("easter", LocalMilliseconds(2026, 4, 1)),
    std::optional<double>(LocalMilliseconds(2026, 4, 5, 7, 0, 0)));
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds("diwali", LocalMilliseconds(2026, 1, 1)),
    std::optional<double>(LocalMilliseconds(2026, 11, 8, 7, 0, 0)));
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds("christmas", LocalMilliseconds(2026, 12, 25, 20, 0, 0)),
    std::optional<double>(LocalMilliseconds(2026, 12, 25, 7, 0, 0)));
  MX_EXPECT_EQ(
    HolidayTargetMilliseconds("christmas", LocalMilliseconds(2026, 12, 26, 0, 0, 0)),
    std::optional<double>(LocalMilliseconds(2027, 12, 25, 7, 0, 0)));
  const auto newMoon = HolidayTargetMilliseconds("newmoon", context.nowMilliseconds);
  const auto fullMoon = HolidayTargetMilliseconds("fullmoon", context.nowMilliseconds);
  MX_EXPECT(newMoon.has_value() && *newMoon > context.nowMilliseconds &&
    *newMoon - context.nowMilliseconds < 32.0 * 86400000.0);
  MX_EXPECT(fullMoon.has_value() && *fullMoon > context.nowMilliseconds &&
    *fullMoon - context.nowMilliseconds < 32.0 * 86400000.0);

  context.nowMilliseconds = LocalMilliseconds(2026, 12, 24, 6, 0, 0);
  context.moments["christmas"] = context.nowMilliseconds + 120000.0;
  MX_EXPECT_EQ(ResolveTokens("{countdown:christmas}", context), std::string("02:00"));
  context.moments["christmas"] = std::nullopt;
  MX_EXPECT_EQ(ResolveTokens("{countdown:christmas}", context), std::string("00:00"));
  context.moments.erase("christmas");
  MX_EXPECT_EQ(ResolveTokens("{countdown:xmas}", context), std::string("01:01:00:00"));

  context.nowMilliseconds = LocalMilliseconds(2026, 7, 1, 13, 45, 30);
  context.countdownTargetMilliseconds.reset();
  MX_EXPECT_EQ(ResolveTokens("{countup}", context), std::string("01:01:01"));
  context.runStartMilliseconds.reset();
  context.framesPerSecond = -5.0;
  MX_EXPECT_EQ(ResolveTokens("{uptime} {fps} {countup}", context), std::string("00:00 0 FPS 00:00"));
}
