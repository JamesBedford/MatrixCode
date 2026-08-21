#pragma once

#include <cstddef>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include <windows.h>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

/** Convert straight-alpha sRGB RGBA8 pixels to the portable 96-cell luminance-mask format. */
[[nodiscard]] std::optional<ImageMask> ImageMaskFromRgba(
  std::string name,
  std::uint32_t width,
  std::uint32_t height,
  std::span<const std::uint8_t> rgba);

/** Decode, orient, and high-quality downsample one WIC-supported image file. */
[[nodiscard]] std::optional<ImageMask> ImportImageMaskWic(
  const std::filesystem::path& path,
  std::wstring* diagnostic = nullptr);

/** Show the native multi-select image picker and import up to limit masks in selection order. */
[[nodiscard]] std::vector<ImageMask> PickAndImportImageMasks(
  HWND owner,
  std::size_t limit,
  std::size_t* failedCount = nullptr);

}  // namespace matrixcode::platform
