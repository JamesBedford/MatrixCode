#pragma once

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace matrixcode {

inline constexpr std::string_view kDefaultUserName = "Neo";
inline constexpr std::string_view kNameToken = "{name}";

/** All dynamic values required to resolve intro and in-rain message tokens. */
struct TokenContext {
  std::string name;
  double nowMilliseconds = 0.0;
  std::optional<double> countdownTargetMilliseconds;
  std::map<std::string, std::optional<double>, std::less<>> moments;
  std::optional<double> runStartMilliseconds;
  std::optional<double> framesPerSecond;
};

[[nodiscard]] std::string GreetingForLocalHour(int hour);

/** Minimal, locale-independent strftime evaluated in the process's local time. */
[[nodiscard]] std::string StrftimeLocal(
  double epochMilliseconds,
  std::string_view format);

/** DD:HH:MM:SS, HH:MM:SS, or MM:SS, with negative/invalid durations clamped to zero. */
[[nodiscard]] std::string FormatCountdown(double remainingMilliseconds);

/**
 * Resolve {name}, {greeting}, {uptime}, {fps}, {time[:FORMAT]},
 * {countdown[:NAME]}, and {countup[:NAME]}. Unknown tokens pass through.
 */
[[nodiscard]] std::string ResolveTokens(
  std::string_view text,
  const TokenContext& context);

}  // namespace matrixcode
