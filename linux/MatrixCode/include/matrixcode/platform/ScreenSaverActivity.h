#pragma once

#include <cmath>
#include <cstdint>
#include <optional>

namespace matrixcode::platform {

inline constexpr std::int64_t kScreenSaverStartupGraceMilliseconds = 300;
inline constexpr double kScreenSaverMovementThreshold = 4.0;

/** Screen-saver dismissal using local logical coordinates and application focus. */
class ScreenSaverActivity final {
 public:
  [[nodiscard]] bool ObservePointer(
      const void* surface,
      const double x,
      const double y,
      const std::int64_t elapsedMilliseconds) {
    if (!std::isfinite(x) || !std::isfinite(y)) return false;
    if (!pointerOrigin_.has_value() ||
        elapsedMilliseconds <= kScreenSaverStartupGraceMilliseconds) {
      pointerOrigin_ = PointerPosition{surface, x, y};
      return false;
    }
    // Local coordinates are comparable only within the same surface.
    return surface != pointerOrigin_->surface ||
      std::abs(x - pointerOrigin_->x) >= kScreenSaverMovementThreshold ||
      std::abs(y - pointerOrigin_->y) >= kScreenSaverMovementThreshold;
  }

  void ObserveApplicationFocus(const bool active) noexcept {
    hasBeenActive_ = hasBeenActive_ || active;
  }

  [[nodiscard]] bool ShouldDismissForInactivity(
      const bool active,
      const std::int64_t elapsedMilliseconds) const noexcept {
    return hasBeenActive_ && !active &&
      elapsedMilliseconds > kScreenSaverStartupGraceMilliseconds;
  }

 private:
  struct PointerPosition {
    const void* surface;
    double x;
    double y;
  };
  std::optional<PointerPosition> pointerOrigin_;
  bool hasBeenActive_ = false;
};

}  // namespace matrixcode::platform
