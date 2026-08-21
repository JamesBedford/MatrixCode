#include "matrixcode/core/IntroTimeline.h"

#include <algorithm>
#include <cmath>

#include "matrixcode/core/Utf8.h"

namespace matrixcode {

IntroTimelineState ComputeIntroTimeline(
    const std::span<const IntroLine> lines,
    const double characterMilliseconds,
    const double startDelayMilliseconds,
    const double fadeOutMilliseconds,
    const double elapsedMilliseconds) {
  if (lines.empty()) return {0, {}, 0.0, true};
  const double characterTime = std::max(1.0, characterMilliseconds);
  double remaining = elapsedMilliseconds - std::max(0.0, startDelayMilliseconds);
  if (remaining < 0.0) return {0, {}, 1.0, false};

  const std::size_t last = lines.size() - 1;
  for (std::size_t index = 0; index < lines.size(); ++index) {
    const auto& line = lines[index];
    const double typeDuration = static_cast<double>(Utf16LengthOfUtf8(line.text)) * characterTime;
    if (remaining < typeDuration) {
      const auto count = static_cast<std::size_t>(std::floor(remaining / characterTime));
      return {index, TruncateUtf8(line.text, count), 1.0, false};
    }
    remaining -= typeDuration;
    if (remaining < line.holdMilliseconds) return {index, line.text, 1.0, false};
    remaining -= line.holdMilliseconds;
    if (index < last) {
      if (remaining < line.pauseMilliseconds) return {index, {}, 1.0, false};
      remaining -= line.pauseMilliseconds;
    }
  }

  if (fadeOutMilliseconds > 0.0 && remaining < fadeOutMilliseconds) {
    return {last, lines[last].text, 1.0 - remaining / fadeOutMilliseconds, false};
  }
  return {lines.size(), {}, 0.0, true};
}

double IntroTotalDurationMilliseconds(const IntroDocument& document) noexcept {
  double total = document.startDelayMilliseconds + document.fadeOutMilliseconds;
  for (std::size_t index = 0; index < document.lines.size(); ++index) {
    const auto& line = document.lines[index];
    total += static_cast<double>(Utf16LengthOfUtf8(line.text)) * document.charMilliseconds +
      line.holdMilliseconds;
    if (index + 1 < document.lines.size()) total += line.pauseMilliseconds;
  }
  return total;
}

bool IntroCursorVisible(
    const double elapsedMilliseconds, const double blinkMilliseconds) noexcept {
  if (!std::isfinite(elapsedMilliseconds) || !std::isfinite(blinkMilliseconds) ||
      blinkMilliseconds <= 0.0) return false;
  return static_cast<long long>(std::floor(elapsedMilliseconds / blinkMilliseconds)) % 2 == 0;
}

double RainStartAfterIntro(
    const double currentRainStartSeconds,
    const double nowSeconds,
    const bool rainDuringIntro,
    const double postIntroDelayMilliseconds) noexcept {
  return rainDuringIntro
    ? currentRainStartSeconds
    : nowSeconds + std::max(0.0, postIntroDelayMilliseconds) / 1000.0;
}

}  // namespace matrixcode
