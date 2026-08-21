#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

#include "matrixcode/core/Types.h"

namespace matrixcode {

struct ActiveImageState {
  std::size_t imageIndex = 0;
  double startSeconds = 0.0;
  double endSeconds = 0.0;
  double placementX = 0.5;
  double placementY = 0.5;
  double intensity = 1.0;
  double scramble = 0.0;
  double rainElapsedSeconds = 0.0;
  std::uint32_t animationBucket = 0;
};

class ImageScheduler final {
 public:
  void Configure(
    ImagesDocument document,
    std::uint32_t seed,
    double epochSeconds,
    double nowSeconds,
    bool synchronizedTimeline);
  [[nodiscard]] const std::optional<ActiveImageState>& Update(double nowSeconds);
  void ShiftTimelineBy(double deltaSeconds) noexcept;
  [[nodiscard]] const ImagesDocument& Document() const noexcept { return document_; }
  [[nodiscard]] const ImageMask* ActiveMask() const noexcept;
  [[nodiscard]] double NextFireSeconds() const noexcept { return nextFireSeconds_; }

 private:
  void ArmAfter(double anchorSeconds);
  ImagesDocument document_;
  std::uint32_t seed_ = 0;
  double epochSeconds_ = 0.0;
  double nextFireSeconds_ = 0.0;
  bool synchronizedTimeline_ = false;
  std::optional<ActiveImageState> active_;
};

struct ImagePlacement {
  double columns = 0.0;
  double rows = 0.0;
  double originColumn = 0.0;
  double originRow = 0.0;
  double featherU = 0.0;
  double featherV = 0.0;
};

[[nodiscard]] ImagePlacement ComputeImagePlacement(
  const ImageMask& image,
  const ImagesDocument& document,
  const ActiveImageState& state,
  std::size_t virtualColumns,
  std::size_t virtualRows) noexcept;
[[nodiscard]] double SampleImageMask(const ImageMask& image, double u, double v) noexcept;
[[nodiscard]] double ImageSignal(double luminance) noexcept;
[[nodiscard]] double ImageEdgeFeather(
  double u, double v, double featherU, double featherV) noexcept;
[[nodiscard]] double ImageFallingGate(
  std::int32_t globalColumn,
  std::int32_t globalRow,
  double rainElapsedSeconds,
  std::uint32_t seed) noexcept;

struct ImageCellResult {
  double brightness = 0.0;
  std::uint8_t glyph = 0;
  double influence = 0.0;
};

[[nodiscard]] ImageCellResult ApplyImageReveal(
  double packedBrightness,
  std::uint8_t currentGlyph,
  GlyphMode mode,
  double luminance,
  double edgeFeather,
  double fallingGate,
  double intensity,
  double scramble,
  std::uint32_t cellIdentity,
  std::uint32_t animationBucket) noexcept;

}  // namespace matrixcode
