#pragma once

#include <array>
#include <cstdint>
#include <string_view>
#include <vector>

namespace matrixcode::render {

struct IntroOverlayBitmap {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  float originX = 0.0f;
  float originY = 0.0f;
  std::vector<std::uint8_t> bgra;
};

/** Rasterize the web/macOS intro typography and two glow shadows as premultiplied BGRA. */
[[nodiscard]] IntroOverlayBitmap BuildIntroOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale,
  const std::array<float, 3>& accent);

/** Rasterize the persisted FPS/resolution HUD using the web app's geometry and colours. */
[[nodiscard]] IntroOverlayBitmap BuildHudOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale);

/** Rasterize the short-lived, theme-coloured shortcut state toast. */
[[nodiscard]] IntroOverlayBitmap BuildToastOverlayBitmap(
  std::string_view utf8,
  std::uint32_t outputWidth,
  std::uint32_t outputHeight,
  float dpiScale,
  const std::array<float, 3>& accent);

}  // namespace matrixcode::render
