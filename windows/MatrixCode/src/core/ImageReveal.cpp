#include "matrixcode/core/ImageReveal.h"

#include <algorithm>
#include <array>
#include <cmath>

#include "matrixcode/core/Rng.h"

namespace matrixcode {
namespace {

[[nodiscard]] double SmoothStep(const double edge0, const double edge1, const double value) noexcept {
  if (edge0 == edge1) return value < edge0 ? 0.0 : 1.0;
  const double t = std::clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

[[nodiscard]] double PositiveModulo(const double value, const double divisor) noexcept {
  double result = std::fmod(value, divisor);
  if (result < 0.0) result += divisor;
  return result;
}

[[nodiscard]] std::uint8_t ImageGlyph(
    const GlyphMode mode, const double luminance, const std::uint32_t key) noexcept {
  constexpr std::uint8_t katakanaStart = 0;
  constexpr std::uint8_t katakanaCount = 56;
  constexpr std::uint8_t digitStart = 56;
  constexpr std::uint8_t latinStart = 66;
  constexpr std::uint8_t symbolStart = 92;
  const auto band = static_cast<std::size_t>(std::clamp(std::floor(luminance * 7.0), 0.0, 6.0));
  constexpr std::array<std::uint8_t, 7> digitOffsets{1, 7, 4, 2, 5, 8, 0};
  constexpr std::array<std::uint8_t, 7> latinOffsets{8, 11, 19, 0, 13, 12, 22};  // I L T A N M W
  constexpr std::array<std::uint8_t, 7> symbolOffsets{1, 6, 4, 5, 2, 3, 0};
  switch (mode) {
    case GlyphMode::Binary: return static_cast<std::uint8_t>(digitStart + (luminance >= 0.58 ? 0 : 1));
    case GlyphMode::Digits: return static_cast<std::uint8_t>(digitStart + digitOffsets[band]);
    case GlyphMode::Latin: return static_cast<std::uint8_t>(latinStart + latinOffsets[band]);
    case GlyphMode::Symbols: return static_cast<std::uint8_t>(symbolStart + symbolOffsets[band]);
    case GlyphMode::Katakana:
      return static_cast<std::uint8_t>(katakanaStart + static_cast<std::uint8_t>(std::floor(
        HashUnit(key ^ static_cast<std::uint32_t>(band) * 0x045d9f3bu) * katakanaCount)));
    case GlyphMode::Matrix:
      if (luminance < 0.16) return symbolStart + 1;  // +
      if (luminance < 0.32) return digitStart + 1;  // 1
      if (luminance < 0.48) return latinStart + 8;  // I
      if (luminance < 0.64) return latinStart + 12; // M
      return static_cast<std::uint8_t>(katakanaStart + static_cast<std::uint8_t>(std::floor(
        HashUnit(key ^ static_cast<std::uint32_t>(band) * 0x045d9f3bu) * katakanaCount)));
  }
  return katakanaStart;
}

[[nodiscard]] std::uint8_t RandomRainGlyph(
    const GlyphMode mode, const std::uint32_t key) noexcept {
  constexpr std::uint8_t katakanaStart = 0;
  constexpr std::uint8_t katakanaCount = 56;
  constexpr std::uint8_t digitStart = 56;
  constexpr std::uint8_t digitCount = 10;
  constexpr std::uint8_t latinStart = 66;
  constexpr std::uint8_t latinCount = 26;
  constexpr std::uint8_t symbolStart = 92;
  constexpr std::uint8_t symbolCount = 7;
  const double pick = HashUnit(key ^ 0x68e31da4u);
  switch (mode) {
    case GlyphMode::Binary:
      return static_cast<std::uint8_t>(digitStart + static_cast<std::uint8_t>(pick * 2.0));
    case GlyphMode::Katakana:
      return static_cast<std::uint8_t>(katakanaStart + static_cast<std::uint8_t>(pick * katakanaCount));
    case GlyphMode::Digits:
      return static_cast<std::uint8_t>(digitStart + static_cast<std::uint8_t>(pick * digitCount));
    case GlyphMode::Latin:
      return static_cast<std::uint8_t>(latinStart + static_cast<std::uint8_t>(pick * latinCount));
    case GlyphMode::Symbols:
      return static_cast<std::uint8_t>(symbolStart + static_cast<std::uint8_t>(pick * symbolCount));
    case GlyphMode::Matrix: {
      const double group = HashUnit(key ^ 0xb5297a4du);
      std::uint8_t start = katakanaStart;
      std::uint8_t count = katakanaCount;
      if (group >= 0.96) { start = symbolStart; count = symbolCount; }
      else if (group >= 0.91) { start = latinStart; count = latinCount; }
      else if (group >= 0.80) { start = digitStart; count = digitCount; }
      return static_cast<std::uint8_t>(start + static_cast<std::uint8_t>(pick * count));
    }
  }
  return katakanaStart;
}

}  // namespace

void ImageScheduler::Configure(
    ImagesDocument document,
    const std::uint32_t seed,
    const double epochSeconds,
    const double nowSeconds,
    const bool synchronizedTimeline) {
  document_ = std::move(document);
  seed_ = seed;
  epochSeconds_ = epochSeconds;
  synchronizedTimeline_ = synchronizedTimeline;
  active_.reset();
  const double base = synchronizedTimeline_ ? epochSeconds_ : nowSeconds;
  nextFireSeconds_ = base + std::max(0.001, document_.frequencyMilliseconds / 1000.0) *
    (0.75 + 0.5 * HashUnit(seed_ ^ 0x6d2b79f5u));
}

void ImageScheduler::ArmAfter(const double anchorSeconds) {
  const auto cycle = static_cast<std::uint32_t>(std::floor(anchorSeconds - epochSeconds_));
  nextFireSeconds_ = anchorSeconds + std::max(0.001, document_.frequencyMilliseconds / 1000.0) *
    (0.75 + 0.5 * HashUnit(seed_ ^ cycle ^ 0x6d2b79f5u));
}

const std::optional<ActiveImageState>& ImageScheduler::Update(const double nowSeconds) {
  if (!document_.enabled || document_.images.empty()) {
    active_.reset();
    return active_;
  }
  // A synchronized consumer may join or reload long after the shared epoch. Advance every expired
  // deterministic activation in this call so it never replays a stale backlog one frame at a time.
  constexpr std::size_t kMaximumSynchronizedFastForwardSteps = 65536;
  std::size_t fastForwardSteps = 0;
  while (true) {
    if (active_.has_value() && nowSeconds >= active_->endSeconds) {
      const double anchor = synchronizedTimeline_ ? active_->endSeconds : nowSeconds;
      active_.reset();
      ArmAfter(anchor);
      if (!synchronizedTimeline_) break;
      continue;
    }
    if (!active_.has_value() && nowSeconds >= nextFireSeconds_) {
      if (synchronizedTimeline_ &&
          fastForwardSteps++ >= kMaximumSynchronizedFastForwardSteps) {
        double anchor = epochSeconds_ + std::floor(std::max(0.0, nowSeconds - epochSeconds_));
        ArmAfter(anchor);
        if (nextFireSeconds_ <= nowSeconds) {
          anchor += 1.0;
          ArmAfter(anchor);
        }
        break;
      }
      const double activationTime = synchronizedTimeline_ ? nextFireSeconds_ : nowSeconds;
      const auto activation = static_cast<std::uint32_t>(
        std::floor((activationTime - epochSeconds_) * 10.0));
      const auto selected = static_cast<std::size_t>(
        Hash32(seed_ ^ activation ^ 0x3f4d1c23u) % document_.images.size());
      const double totalDuration = (document_.appearMilliseconds +
        document_.persistenceMilliseconds + document_.disappearMilliseconds) / 1000.0;
      active_ = ActiveImageState{
        selected,
        activationTime,
        activationTime + totalDuration,
        HashUnit(seed_ ^ activation ^ 0x731f4a7du),
        HashUnit(seed_ ^ activation ^ 0x4c2d65bfu),
        1.0,
        0.0,
        0.0,
        0u,
      };
      if (synchronizedTimeline_ && nowSeconds >= active_->endSeconds) continue;
    }
    break;
  }
  if (active_.has_value()) {
    const double appear = document_.appearMilliseconds / 1000.0;
    const double disappear = document_.disappearMilliseconds / 1000.0;
    const double elapsed = nowSeconds - active_->startSeconds;
    const double remaining = active_->endSeconds - nowSeconds;
    double fade = 1.0;
    double flicker = 0.0;
    if (appear > 0.0 && elapsed < appear) {
      fade = std::max(0.0, elapsed / appear);
      flicker = 1.0 - fade;
    } else if (disappear > 0.0 && remaining < disappear) {
      fade = std::max(0.0, remaining / disappear);
      flicker = 1.0 - fade;
    }
    active_->intensity = document_.brightnessFade ? fade : 1.0;
    active_->scramble = document_.flickerOut ? flicker : 0.0;
    active_->rainElapsedSeconds = nowSeconds - epochSeconds_;
    active_->animationBucket = static_cast<std::uint32_t>(
      std::floor(active_->rainElapsedSeconds * 18.0));
  }
  return active_;
}

void ImageScheduler::ShiftTimelineBy(const double deltaSeconds) noexcept {
  if (!(deltaSeconds > 0.0) || synchronizedTimeline_) return;
  epochSeconds_ += deltaSeconds;
  nextFireSeconds_ += deltaSeconds;
  if (active_.has_value()) {
    active_->startSeconds += deltaSeconds;
    active_->endSeconds += deltaSeconds;
  }
}

const ImageMask* ImageScheduler::ActiveMask() const noexcept {
  if (!active_.has_value() || active_->imageIndex >= document_.images.size()) return nullptr;
  return &document_.images[active_->imageIndex];
}

ImagePlacement ComputeImagePlacement(
    const ImageMask& image,
    const ImagesDocument& document,
    const ActiveImageState& state,
    const std::size_t virtualColumns,
    const std::size_t virtualRows) noexcept {
  if (image.width == 0 || image.height == 0 || virtualColumns == 0 || virtualRows == 0) return {};
  const double targetColumns = std::max(1.0, static_cast<double>(virtualColumns) * document.imageScale);
  const double aspect = static_cast<double>(image.width) / std::max(1.0, static_cast<double>(image.height));
  double columns = std::min(static_cast<double>(virtualColumns), targetColumns);
  double rows = columns / std::max(0.001, aspect);
  if (rows > static_cast<double>(virtualRows)) {
    rows = static_cast<double>(virtualRows);
    columns = std::min(static_cast<double>(virtualColumns), rows * aspect);
  }
  const double remainingColumns = std::max(0.0, static_cast<double>(virtualColumns) - columns);
  const double remainingRows = std::max(0.0, static_cast<double>(virtualRows) - rows);
  const double jitter = document.imageScale >= 0.999 ? 0.0 : document.placementJitter;
  const double placementX = 0.5 + (state.placementX - 0.5) * jitter;
  const double placementY = 0.5 + (state.placementY - 0.5) * jitter;
  return {
    columns,
    rows,
    remainingColumns * std::clamp(placementX, 0.0, 1.0),
    remainingRows * std::clamp(placementY, 0.0, 1.0),
    std::min(4.0, std::max(1.0, columns * 0.04)) / std::max(1.0, columns),
    std::min(4.0, std::max(1.0, rows * 0.04)) / std::max(1.0, rows),
  };
}

double SampleImageMask(const ImageMask& image, const double u, const double v) noexcept {
  if (image.width == 0 || image.height == 0 ||
      image.luminance.size() != static_cast<std::size_t>(image.width) * image.height ||
      u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) return 0.0;
  const double x = std::clamp(u * static_cast<double>(image.width - 1), 0.0, static_cast<double>(image.width - 1));
  const double y = std::clamp(v * static_cast<double>(image.height - 1), 0.0, static_cast<double>(image.height - 1));
  const auto x0 = static_cast<std::uint32_t>(std::floor(x));
  const auto y0 = static_cast<std::uint32_t>(std::floor(y));
  const auto x1 = std::min(image.width - 1, x0 + 1);
  const auto y1 = std::min(image.height - 1, y0 + 1);
  const double tx = x - x0;
  const double ty = y - y0;
  const auto at = [&image](const std::uint32_t column, const std::uint32_t row) {
    return static_cast<double>(image.luminance[static_cast<std::size_t>(row) * image.width + column]) / 255.0;
  };
  const double a = at(x0, y0);
  const double b = at(x1, y0);
  const double c = at(x0, y1);
  const double d = at(x1, y1);
  const double top = a + (b - a) * tx;
  const double bottom = c + (d - c) * tx;
  return top + (bottom - top) * ty;
}

double ImageSignal(const double luminance) noexcept {
  const double value = std::clamp(luminance, 0.0, 1.0);
  const double nonEmpty = SmoothStep(0.035, 0.12, value);
  const double contrast = std::abs(value - 0.5) * 2.0 * nonEmpty;
  const double bright = value * 0.72;
  return std::max(contrast, bright) * nonEmpty;
}

double ImageEdgeFeather(
    const double u, const double v, const double featherU, const double featherV) noexcept {
  const double horizontal = std::min(SmoothStep(0.0, featherU, u), SmoothStep(0.0, featherU, 1.0 - u));
  const double vertical = std::min(SmoothStep(0.0, featherV, v), SmoothStep(0.0, featherV, 1.0 - v));
  return horizontal * vertical;
}

double ImageFallingGate(
    const std::int32_t globalColumn,
    const std::int32_t globalRow,
    const double rainElapsedSeconds,
    const std::uint32_t seed) noexcept {
  const auto columnKey = seed ^ static_cast<std::uint32_t>(globalColumn) * 0x9e3779b9u ^ 0x748f4a15u;
  const double speed = 4.5 + HashUnit(columnKey ^ 0x85ebca6bu) * 8.0;
  const double span = 9.0 + HashUnit(columnKey ^ 0x27d4eb2du) * 12.0;
  const double offset = HashUnit(columnKey ^ 0xd3a2646cu) * span;
  const double phase = PositiveModulo(static_cast<double>(globalRow) - rainElapsedSeconds * speed + offset, span);
  const double head = std::exp(-phase * 0.55);
  const double afterglow = phase < span * 0.42
    ? std::pow(1.0 - phase / (span * 0.42), 2.0)
    : 0.0;
  return std::min(1.0, std::max(head, afterglow * 0.65));
}

ImageCellResult ApplyImageReveal(
    const double packedBrightness,
    const std::uint8_t currentGlyph,
    const GlyphMode mode,
    const double luminance,
    const double edgeFeather,
    const double fallingGate,
    const double intensity,
    const double scramble,
    const std::uint32_t cellIdentity,
    const std::uint32_t animationBucket) noexcept {
  const double signal = ImageSignal(luminance) * std::clamp(edgeFeather, 0.0, 1.0);
  const double trailGate = std::clamp((packedBrightness - 0.028) / 0.42, 0.0, 1.0);
  const double revealGate = std::max(trailGate, fallingGate * 0.48);
  const double roll = HashUnit(
    cellIdentity ^ animationBucket * 0x9e3779b9u ^ 0xb4b82e39u);
  const double dissolve = scramble > 0.0 && roll < scramble ? 0.0 : 1.0;
  const double influence = std::min(
    1.0, signal * revealGate * std::clamp(intensity, 0.0, 1.0) * dissolve);
  if (influence <= 0.001) return {packedBrightness, currentGlyph, influence};
  const double bright = std::max(0.0, (luminance - 0.38) / 0.62);
  const double dark = std::max(0.0, (0.58 - luminance) / 0.58);
  double brightness = packedBrightness * (1.0 - 0.46 * dark * influence);
  brightness = std::max(brightness, bright * influence * (0.12 + 0.48 * fallingGate));
  brightness = std::min(
    1.45, brightness + bright * influence * std::max(packedBrightness, 0.08) * 0.58);

  std::uint8_t glyph = currentGlyph;
  constexpr std::uint8_t ambientGlyphCount = 99;
  const double glyphChance = std::min(0.96, 0.18 + influence * 0.78);
  const double glyphRoll = HashUnit(
    cellIdentity ^ animationBucket * 0x27d4eb2du ^ 0x68e31da4u);
  if (glyph < ambientGlyphCount && glyphRoll < glyphChance) {
    const auto levelValue = static_cast<std::uint32_t>(
      std::floor(std::clamp(luminance, 0.0, 1.0) * 255.0));
    const auto imageKey = cellIdentity ^ levelValue * 0x85ebca6bu;
    glyph = ImageGlyph(mode, std::clamp(luminance, 0.0, 1.0), imageKey);
    const double scrambleRoll = HashUnit(
      cellIdentity ^ animationBucket * 0x85ebca6bu ^ 0xd3a2646cu);
    if (scramble > 0.0 && scrambleRoll < scramble * 0.75) {
      glyph = RandomRainGlyph(mode, cellIdentity ^ animationBucket ^ 0x3c6ef372u);
    }
  }
  return {brightness, glyph, influence};
}

}  // namespace matrixcode
