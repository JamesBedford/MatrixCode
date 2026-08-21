#pragma once

#include <cstddef>
#include <span>
#include <string>

#include "matrixcode/core/Types.h"

namespace matrixcode {

struct IntroTimelineState {
  std::size_t lineIndex = 0;
  std::string visibleText;
  double opacity = 0.0;
  bool done = false;
};

[[nodiscard]] IntroTimelineState ComputeIntroTimeline(
  std::span<const IntroLine> lines,
  double characterMilliseconds,
  double startDelayMilliseconds,
  double fadeOutMilliseconds,
  double elapsedMilliseconds);
[[nodiscard]] double IntroTotalDurationMilliseconds(const IntroDocument& document) noexcept;
[[nodiscard]] bool IntroCursorVisible(
  double elapsedMilliseconds, double blinkMilliseconds = 450.0) noexcept;
[[nodiscard]] double RainStartAfterIntro(
  double currentRainStartSeconds,
  double nowSeconds,
  bool rainDuringIntro,
  double postIntroDelayMilliseconds) noexcept;

}  // namespace matrixcode
