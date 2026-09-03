#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include <QString>
#include <QStringList>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

/** Convert straight-alpha sRGB RGBA8 pixels to the portable 96-cell luminance mask. */
[[nodiscard]] std::optional<ImageMask> ImageMaskFromStraightRgba(
  std::string name,
  std::uint32_t width,
  std::uint32_t height,
  std::span<const std::uint8_t> rgba);

/** Decode, orient, and high-quality aspect-fit one Qt-supported image. */
[[nodiscard]] std::optional<ImageMask> ImportImageMaskQt(
  const QString& path,
  QString* diagnostic = nullptr);

[[nodiscard]] std::vector<ImageMask> ImportImageMasksQt(
  const QStringList& paths,
  std::size_t limit,
  std::size_t* failedCount = nullptr);

}  // namespace matrixcode::platform
