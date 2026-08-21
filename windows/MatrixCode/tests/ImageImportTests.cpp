#include <array>
#include <cstdint>

#include "TestHarness.h"
#include "matrixcode/platform/ImageImportWin32.h"

void RunImageImportTests() {
  using matrixcode::platform::ImageMaskFromRgba;
  const std::array<std::uint8_t, 8> range{
    0, 0, 0, 0,
    255, 255, 255, 255,
  };
  const auto normalized = ImageMaskFromRgba("range", 2, 1, range);
  MX_EXPECT(normalized.has_value());
  MX_EXPECT_EQ(normalized->luminance[0], static_cast<std::uint8_t>(0));
  MX_EXPECT_EQ(normalized->luminance[1], static_cast<std::uint8_t>(255));

  const std::array<std::uint8_t, 4> halfAlpha{255, 255, 255, 128};
  const auto alphaSquared = ImageMaskFromRgba("alpha", 1, 1, halfAlpha);
  MX_EXPECT(alphaSquared.has_value());
  MX_EXPECT_EQ(alphaSquared->luminance[0], static_cast<std::uint8_t>(82));
  MX_EXPECT(!ImageMaskFromRgba("bad", 97, 1, halfAlpha).has_value());
}
