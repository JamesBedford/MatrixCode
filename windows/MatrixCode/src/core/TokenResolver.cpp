#include "matrixcode/core/TokenResolver.h"

#include "matrixcode/core/HolidayResolver.h"
#include "matrixcode/core/Utf8.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <ctime>
#include <iomanip>
#include <limits>
#include <sstream>

namespace matrixcode {
namespace {

constexpr std::array<std::string_view, 7> kWeekdays{
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
constexpr std::array<std::string_view, 7> kWeekdaysShort{
  "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
constexpr std::array<std::string_view, 12> kMonths{
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"};
constexpr std::array<std::string_view, 12> kMonthsShort{
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

[[nodiscard]] std::string Pad(const long long value, const std::size_t width, const char fill = '0') {
  std::string result = std::to_string(value);
  if (result.size() < width) result.insert(result.begin(), width - result.size(), fill);
  return result;
}

[[nodiscard]] bool IsLeapYear(const int year) noexcept {
  return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

[[nodiscard]] int DayOfYear(const std::tm& time) noexcept {
  constexpr std::array<int, 12> daysBeforeMonth{
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
  const int year = time.tm_year + 1900;
  const int month = std::clamp(time.tm_mon, 0, 11);
  return daysBeforeMonth[static_cast<std::size_t>(month)] + time.tm_mday +
    (month > 1 && IsLeapYear(year) ? 1 : 0);
}

[[nodiscard]] std::tm LocalTime(const double epochMilliseconds) noexcept {
  const double finiteMilliseconds = std::isfinite(epochMilliseconds) ? epochMilliseconds : 0.0;
  const double seconds = std::floor(finiteMilliseconds / 1000.0);
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

[[nodiscard]] bool SupportedKind(const std::string_view kind) noexcept {
  return kind == "name" || kind == "greeting" || kind == "uptime" ||
    kind == "fps" || kind == "time" || kind == "countdown" || kind == "countup";
}

[[nodiscard]] std::optional<double> CountTarget(
    const std::string_view kind,
    const std::optional<std::string_view> argument,
    const TokenContext& context) {
  if (argument.has_value()) {
    const std::string_view key = TrimUtf8(*argument);
    const auto moment = context.moments.find(key);
    if (moment != context.moments.end()) return moment->second;
    return HolidayTargetMilliseconds(key, context.nowMilliseconds);
  }
  if (context.countdownTargetMilliseconds.has_value()) {
    return context.countdownTargetMilliseconds;
  }
  return kind == "countup" ? context.runStartMilliseconds : std::nullopt;
}

[[nodiscard]] std::string ResolveOne(
    const std::string_view kind,
    const std::optional<std::string_view> argument,
    const TokenContext& context) {
  if (kind == "name") {
    const std::string_view name = TrimUtf8(context.name);
    return name.empty() ? std::string(kDefaultUserName) : std::string(name);
  }
  if (kind == "greeting") {
    return GreetingForLocalHour(LocalTime(context.nowMilliseconds).tm_hour);
  }
  if (kind == "uptime") {
    const double elapsed = context.runStartMilliseconds.has_value()
      ? context.nowMilliseconds - *context.runStartMilliseconds
      : 0.0;
    return FormatCountdown(elapsed);
  }
  if (kind == "fps") {
    const double fps = context.framesPerSecond.has_value() &&
        std::isfinite(*context.framesPerSecond)
      ? std::max(0.0, *context.framesPerSecond)
      : 0.0;
    const double rounded = std::floor(fps + 0.5);
    std::ostringstream output;
    output << std::fixed << std::setprecision(0) << rounded << " FPS";
    return output.str();
  }
  if (kind == "time") {
    return StrftimeLocal(
      context.nowMilliseconds,
      argument.has_value() ? *argument : std::string_view("%H:%M"));
  }

  const auto target = CountTarget(kind, argument, context);
  if (!target.has_value()) return FormatCountdown(0.0);
  return FormatCountdown(kind == "countup"
    ? context.nowMilliseconds - *target
    : *target - context.nowMilliseconds);
}

}  // namespace

std::string GreetingForLocalHour(const int hour) {
  if (hour < 4) return "PARTY ON";
  if (hour < 12) return "GOOD MORNING";
  if (hour < 18) return "GOOD AFTERNOON";
  if (hour < 23) return "GOOD EVENING";
  return "GOOD NIGHT";
}

std::string StrftimeLocal(
    const double epochMilliseconds, const std::string_view format) {
  const std::tm time = LocalTime(epochMilliseconds);
  const int hours24 = time.tm_hour;
  const int hours12 = hours24 % 12 == 0 ? 12 : hours24 % 12;
  std::string output;
  output.reserve(format.size() + 16);
  for (std::size_t index = 0; index < format.size(); ++index) {
    if (format[index] != '%' || index + 1 >= format.size()) {
      output.push_back(format[index]);
      continue;
    }
    const char code = format[++index];
    switch (code) {
      case 'H': output += Pad(hours24, 2); break;
      case 'I': output += Pad(hours12, 2); break;
      case 'M': output += Pad(time.tm_min, 2); break;
      case 'S': output += Pad(time.tm_sec, 2); break;
      case 'p': output += hours24 < 12 ? "AM" : "PM"; break;
      case 'Y': output += std::to_string(time.tm_year + 1900); break;
      case 'y': output += Pad((time.tm_year + 1900) % 100, 2); break;
      case 'm': output += Pad(time.tm_mon + 1, 2); break;
      case 'd': output += Pad(time.tm_mday, 2); break;
      case 'e': output += Pad(time.tm_mday, 2, ' '); break;
      case 'A': output += kWeekdays[static_cast<std::size_t>(std::clamp(time.tm_wday, 0, 6))]; break;
      case 'a': output += kWeekdaysShort[static_cast<std::size_t>(std::clamp(time.tm_wday, 0, 6))]; break;
      case 'B': output += kMonths[static_cast<std::size_t>(std::clamp(time.tm_mon, 0, 11))]; break;
      case 'b': output += kMonthsShort[static_cast<std::size_t>(std::clamp(time.tm_mon, 0, 11))]; break;
      case 'j': output += Pad(DayOfYear(time), 3); break;
      case '%': output.push_back('%'); break;
      default:
        output.push_back('%');
        output.push_back(code);
        break;
    }
  }
  return output;
}

std::string FormatCountdown(const double remainingMilliseconds) {
  const double valid = std::isfinite(remainingMilliseconds)
    ? std::max(0.0, remainingMilliseconds)
    : 0.0;
  const double rawSeconds = std::floor(valid / 1000.0);
  const double maximum = static_cast<double>(std::numeric_limits<long long>::max());
  long long total = static_cast<long long>(std::min(rawSeconds, maximum));
  const long long days = total / 86400;
  total -= days * 86400;
  const long long hours = total / 3600;
  total -= hours * 3600;
  const long long minutes = total / 60;
  const long long seconds = total - minutes * 60;
  if (days > 0) {
    return Pad(days, 2) + ':' + Pad(hours, 2) + ':' +
      Pad(minutes, 2) + ':' + Pad(seconds, 2);
  }
  if (hours > 0) return Pad(hours, 2) + ':' + Pad(minutes, 2) + ':' + Pad(seconds, 2);
  return Pad(minutes, 2) + ':' + Pad(seconds, 2);
}

std::string ResolveTokens(const std::string_view text, const TokenContext& context) {
  std::string output;
  output.reserve(text.size());
  std::size_t cursor = 0;
  while (cursor < text.size()) {
    if (text[cursor] != '{') {
      output.push_back(text[cursor++]);
      continue;
    }
    const std::size_t close = text.find('}', cursor + 1);
    if (close == std::string_view::npos) {
      output.append(text.substr(cursor));
      break;
    }
    const std::string_view body = text.substr(cursor + 1, close - cursor - 1);
    const std::size_t colon = body.find(':');
    const std::string_view kind = body.substr(0, colon);
    if (!SupportedKind(kind)) {
      // Advance one byte, as the JavaScript global regular expression does, so
      // a supported token nested after this brace can still match.
      output.push_back(text[cursor++]);
      continue;
    }
    std::optional<std::string_view> argument;
    if (colon != std::string_view::npos) argument.emplace(body.substr(colon + 1));
    output += ResolveOne(kind, argument, context);
    cursor = close + 1;
  }
  return output;
}

}  // namespace matrixcode
