#pragma once

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

}  // namespace matrixcode
