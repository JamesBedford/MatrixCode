#include <cmath>
#include <limits>

#include "TestHarness.h"
#include "matrixcode/core/Controllers.h"

void RunControllersTests() {
  using namespace matrixcode;
  MX_EXPECT(PresentationModeForWindowCount(1) == PresentationMode::Synchronized);
  MX_EXPECT(PresentationModeForWindowCount(2) == PresentationMode::NonBlocking);
  const auto empty = PlanSimulationSteps(-1.0);
  MX_EXPECT_EQ(empty.steps, static_cast<std::size_t>(0));
  const auto normal = PlanSimulationSteps(1.0 / 60.0);
  MX_EXPECT_EQ(normal.steps, static_cast<std::size_t>(1));
  MX_EXPECT(std::abs(normal.deltaSeconds - 1.0 / 60.0) < 1e-12);
  const auto catchup = PlanSimulationSteps(1.0);
  MX_EXPECT_EQ(catchup.steps, static_cast<std::size_t>(4));
  MX_EXPECT(std::abs(catchup.deltaSeconds - 0.0625) < 1e-12);

  MX_EXPECT_EQ(RainRampEase(-1.0), 0.0);
  MX_EXPECT_EQ(RainRampEase(0.0), 0.0);
  MX_EXPECT(std::abs(RainRampEase(0.1) - 0.03125) < 1e-12);
  MX_EXPECT(std::abs(RainRampEase(0.2) - 0.125) < 1e-12);
  MX_EXPECT(std::abs(RainRampEase(0.5) - 0.5) < 1e-12);
  MX_EXPECT(std::abs(RainRampEase(0.9) - 0.96875) < 1e-12);
  MX_EXPECT_EQ(RainRampEase(1.0), 1.0);
  MX_EXPECT(std::abs(RainRampEase(0.25, 0.0) - 0.25) < 1e-12);

  // Both synchronized single-window presentation and nonblocking multi-window presentation use
  // this budget, keeping startup on high-refresh displays at the same cadence as settled rain.
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(0.0), std::uint32_t{17});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(1.0 / 120.0), std::uint32_t{9});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(1.0 / 60.0), std::uint32_t{0});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(1.0 / 30.0), std::uint32_t{0});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(0.005, 100.0), std::uint32_t{5});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(-0.001), std::uint32_t{0});
  MX_EXPECT_EQ(FramePacingWaitMilliseconds(
    std::numeric_limits<double>::quiet_NaN()), std::uint32_t{0});

  MX_EXPECT(std::abs(VanDerCorput(0) - 0.0) < 1e-12);
  MX_EXPECT(std::abs(VanDerCorput(1) - 0.5) < 1e-12);
  MX_EXPECT(std::abs(VanDerCorput(2) - 0.25) < 1e-12);
  MX_EXPECT(std::abs(VanDerCorput(3) - 0.75) < 1e-12);
  MX_EXPECT_EQ(SeedForLane(0x12345678u, 0), 0x12345678u);
  MX_EXPECT_EQ(TierLaneCap(QualityTier::Low), static_cast<std::size_t>(2));
  MX_EXPECT_EQ(TierLaneCap(QualityTier::Medium), static_cast<std::size_t>(4));
  MX_EXPECT_EQ(TierLaneCap(QualityTier::High), static_cast<std::size_t>(8));

  const auto lowDensity = ComputeRainLanes(20.0, true, 8);
  MX_EXPECT_EQ(lowDensity.size(), static_cast<std::size_t>(1));
  const auto maximum = ComputeRainLanes(100.0, true, 8);
  MX_EXPECT_EQ(maximum.size(), static_cast<std::size_t>(8));
  MX_EXPECT(std::abs(maximum[1].offsetCells - 0.5) < 1e-12);

  AdaptiveResolution adaptive;
  for (int index = 0; index < 21; ++index) {
    const auto scale = adaptive.Update(30.0);
    MX_EXPECT(scale >= 0.5 && scale <= 1.0);
  }
  MX_EXPECT(std::abs(adaptive.Scale() - 0.9) < 1e-12);
  for (int index = 0; index < 31; ++index) {
    const auto scale = adaptive.Update(30.0);
    MX_EXPECT(scale >= 0.5 && scale <= 1.0);
  }
  MX_EXPECT(adaptive.Scale() <= 0.8 + 1e-12);
  adaptive.Reset();
  MX_EXPECT_EQ(adaptive.Scale(), 1.0);
}
