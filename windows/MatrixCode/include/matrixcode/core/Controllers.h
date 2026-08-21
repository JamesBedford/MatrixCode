#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "matrixcode/core/Types.h"

namespace matrixcode {

struct SimulationStepPlan {
  std::size_t steps = 0;
  double deltaSeconds = 0.0;
};

[[nodiscard]] SimulationStepPlan PlanSimulationSteps(double elapsedSeconds) noexcept;
[[nodiscard]] double RainRampEase(double progress, double edge = 0.2) noexcept;

enum class PresentationMode { Synchronized, NonBlocking };
[[nodiscard]] PresentationMode PresentationModeForWindowCount(std::size_t windows) noexcept;

struct RainLane {
  std::size_t index = 0;
  double offsetCells = 0.0;
  double density = 0.0;
  double weight = 1.0;
};

[[nodiscard]] double VanDerCorput(std::size_t index) noexcept;
[[nodiscard]] std::uint32_t SeedForLane(std::uint32_t base, std::size_t index) noexcept;
[[nodiscard]] std::size_t TierLaneCap(QualityTier tier) noexcept;
[[nodiscard]] std::vector<RainLane> ComputeRainLanes(
  double density, bool allowOverlap, std::size_t cap);

struct AdaptiveResolutionConfig {
  double targetMilliseconds = 1000.0 / 60.0;
  double minimumScale = 0.5;
  double step = 0.1;
  double emaAlpha = 0.15;
  double upHeadroom = 0.6;
  double downThreshold = 1.15;
  std::size_t cooldownFrames = 30;
  std::size_t warmFrames = 20;
};

class AdaptiveResolution final {
 public:
  explicit AdaptiveResolution(AdaptiveResolutionConfig config = {});
  void Reset() noexcept;
  [[nodiscard]] double Update(double frameMilliseconds) noexcept;
  [[nodiscard]] double Scale() const noexcept { return scale_; }
  [[nodiscard]] double SmoothedMilliseconds() const noexcept { return smoothedMilliseconds_; }

 private:
  AdaptiveResolutionConfig config_;
  double scale_ = 1.0;
  double smoothedMilliseconds_ = 0.0;
  std::size_t frames_ = 0;
  std::size_t cooldown_ = 0;
};

}  // namespace matrixcode
