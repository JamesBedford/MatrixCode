#pragma once

#include <cstdint>
#include <vector>

#include "matrixcode/core/Types.h"

namespace matrixcode::render {

struct GlyphAtlasBitmap {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t columns = 16;
  std::uint32_t rows = 0;
  std::uint32_t cellPixels = 64;
  std::vector<std::uint8_t> bgra;
};

[[nodiscard]] GlyphAtlasBitmap BuildGlyphAtlas(const Controls& controls);

}  // namespace matrixcode::render
