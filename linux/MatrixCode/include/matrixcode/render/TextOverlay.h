#pragma once

#include <array>
#include <cstdint>
#include <string_view>
#include <vector>

namespace matrixcode::render {

struct TextOverlayBitmap {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  float originX = 0.0f;
  float originY = 0.0f;
  /** Premultiplied RGBA8 in top-left row order. */
  std::vector<std::uint8_t> rgba;
};

[[nodiscard]] TextOverlayBitmap BuildIntroOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale,
  const std::array<float, 3>& accent);

[[nodiscard]] TextOverlayBitmap BuildHudOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale);

[[nodiscard]] TextOverlayBitmap BuildToastOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale,
  const std::array<float, 3>& accent);

}  // namespace matrixcode::render
