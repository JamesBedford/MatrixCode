#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "matrixcode/core/Types.h"

namespace matrixcode::render {

struct GlyphAtlasBitmap {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t columns = 0;
  std::uint32_t rows = 0;
  std::uint32_t cellPixels = 64;
  std::size_t blankCellCount = 0;
  std::string resolvedFontFamily;
  std::vector<std::uint8_t> coverage;
};

/** Builds the canonical 64-pixel R8 atlas using Qt's native font rasterizer. */
[[nodiscard]] GlyphAtlasBitmap BuildGlyphAtlas(const Controls& controls);

}  // namespace matrixcode::render
