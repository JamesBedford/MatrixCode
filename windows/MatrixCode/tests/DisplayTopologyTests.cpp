#include <array>
#include <cmath>

#include "TestHarness.h"
#include "matrixcode/core/DisplayTopology.h"

void RunDisplayTopologyTests() {
  using namespace matrixcode;
  const std::array<PhysicalDisplay, 2> equal{{
    {0, 0, 1920, 1080, 1, 1}, {1920, 0, 1920, 1080, 1, 1}}};
  const auto equalResult = SolveDisplayTopology(equal);
  MX_EXPECT_EQ(equalResult.displays.size(), static_cast<std::size_t>(2));
  MX_EXPECT(std::abs(equalResult.width - 3840.0) < 1e-12);
  MX_EXPECT(std::abs(equalResult.displays[0].left + equalResult.displays[0].width -
    equalResult.displays[1].left) < 1e-12);

  const std::array<PhysicalDisplay, 2> mixed{{
    {0, 0, 1920, 1080, 1, 1}, {1920, 0, 3840, 2160, 0.5, 0.5}}};
  const auto mixedResult = SolveDisplayTopology(mixed);
  MX_EXPECT(std::abs(mixedResult.width - 3840.0) < 1e-12);
  MX_EXPECT(std::abs(mixedResult.displays[1].width - 1920.0) < 1e-12);
  MX_EXPECT(std::abs(mixedResult.displays[1].height - 1080.0) < 1e-12);
  MX_EXPECT(std::abs(mixedResult.displays[1].logicalPerPixelX - 0.5) < 1e-12);
  MX_EXPECT(std::abs(mixedResult.displays[0].left + mixedResult.displays[0].width -
    mixedResult.displays[1].left) < 1e-12);

  const std::array<PhysicalDisplay, 2> offsetMixed{{
    {0, 0, 1920, 1080, 1, 1}, {1920, -360, 3840, 2160, 0.5, 0.5}}};
  const auto offsetResult = SolveDisplayTopology(offsetMixed);
  MX_EXPECT(std::abs(offsetResult.displays[1].top) < 1e-12);
  MX_EXPECT(std::abs(offsetResult.displays[0].top - 180.0) < 1e-12);
  MX_EXPECT(std::abs(offsetResult.height - 1260.0) < 1e-12);
}
