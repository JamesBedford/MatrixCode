#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "matrixcode/core/Json.h"
#include "matrixcode/core/Types.h"

namespace matrixcode {

[[nodiscard]] SettingsSnapshot DefaultSettings();
[[nodiscard]] SettingsSnapshot SanitizeSettings(const json::Value& root);
[[nodiscard]] json::Value EncodeSettings(const SettingsSnapshot& settings);
[[nodiscard]] std::optional<SettingsSnapshot> DecodeSettings(
  std::string_view utf8,
  std::string* error = nullptr);
[[nodiscard]] std::string EncodeSettingsUtf8(const SettingsSnapshot& settings, bool pretty = true);

/** A transient rendering copy; never persist it over the user's selected settings. */
[[nodiscard]] Controls EffectiveControlsForLocalDate(
  const Controls& controls,
  int localMonth,
  int localDay,
  bool fullMoonDay = false);

/**
 * Settings copy for the active calendar override, or empty on an ordinary day.
 * Fixed holidays take priority over a full moon. The saved theme is unchanged.
 */
[[nodiscard]] std::optional<std::string_view> ColorOverrideLabel(
  int localMonth,
  int localDay,
  bool fullMoonDay = false) noexcept;

/**
 * In-rain greeting for a local calendar occasion. Fixed holidays win over a full moon.
 * Empty on an ordinary day. Callers show it first without rewriting saved messages.
 */
[[nodiscard]] std::optional<std::string_view> OccasionGreeting(
  int localMonth,
  int localDay,
  bool fullMoonDay = false) noexcept;

[[nodiscard]] std::optional<std::vector<std::uint8_t>> DecodeBase64(std::string_view value);
[[nodiscard]] std::string EncodeBase64(const std::vector<std::uint8_t>& value);

}  // namespace matrixcode
