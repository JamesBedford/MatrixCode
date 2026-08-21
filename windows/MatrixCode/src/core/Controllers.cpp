#include "matrixcode/core/Controllers.h"

#include <algorithm>
#include <cmath>

namespace matrixcode {

SimulationStepPlan PlanSimulationSteps(const double elapsedSeconds) noexcept {
  if (!std::isfinite(elapsedSeconds) || elapsedSeconds <= 0.0) return {};
  constexpr double maximumStep = 1.0 / 15.0;
  constexpr double maximumCatchup = 0.25;
  const double elapsed = std::min(elapsedSeconds, maximumCatchup);
  const auto steps = static_cast<std::size_t>(std::ceil(elapsed / maximumStep));
  return {steps, elapsed / static_cast<double>(steps)};
}

double RainRampEase(const double progress, const double edge) noexcept {
  if (!std::isfinite(progress) || progress <= 0.0) return 0.0;
  if (progress >= 1.0) return 1.0;
  const double clampedEdge = std::clamp(edge, 0.0, 0.5);
  if (clampedEdge <= 0.0) return progress;
  const double peakRate = 1.0 / (1.0 - clampedEdge);
  if (progress < clampedEdge) {
    return peakRate * progress * progress / (2.0 * clampedEdge);
  }
  if (progress > 1.0 - clampedEdge) {
    const double remaining = 1.0 - progress;
    return 1.0 - peakRate * remaining * remaining / (2.0 * clampedEdge);
  }
  return peakRate * clampedEdge / 2.0 + peakRate * (progress - clampedEdge);
}

PresentationMode PresentationModeForWindowCount(const std::size_t windows) noexcept {
  return windows > 1 ? PresentationMode::NonBlocking : PresentationMode::Synchronized;
}

double VanDerCorput(std::size_t index) noexcept {
  double result = 0.0;
  double denominator = 1.0;
  while (index > 0) {
    denominator *= 2.0;
    result += static_cast<double>(index % 2) / denominator;
    index /= 2;
  }
  return result;
}

std::uint32_t SeedForLane(const std::uint32_t base, const std::size_t index) noexcept {
  return base ^ (static_cast<std::uint32_t>(index) * 0x9e3779b9u);
}

std::size_t TierLaneCap(const QualityTier tier) noexcept {
  if (tier == QualityTier::Low) return 2;
  if (tier == QualityTier::Medium) return 4;
  return 8;
}

std::vector<RainLane> ComputeRainLanes(
    const double density, const bool allowOverlap, const std::size_t cap) {
  constexpr double onset = 20.0;
  constexpr double maximumDensity = 100.0;
  constexpr std::size_t maximumLanes = 8;
  std::vector<RainLane> result{{0, 0.0, density, 1.0}};
  if (!allowOverlap || density <= onset || cap <= 1) return result;

  result[0].density = onset;
  const double maximumLevel = std::log2(static_cast<double>(maximumLanes));
  const double level = std::clamp(
    maximumLevel * (density - onset) / (maximumDensity - onset), 0.0, maximumLevel);
  const auto full = static_cast<std::size_t>(std::pow(2.0, std::floor(level)));
  const double fade = level - std::floor(level);
  for (std::size_t index = 1; index < full; ++index) {
    result.push_back({index, VanDerCorput(index), onset, 1.0});
  }
  if (fade > 1e-6 && full < maximumLanes) {
    for (std::size_t index = full; index < full * 2; ++index) {
      result.push_back({index, VanDerCorput(index), onset, fade});
    }
  }
  if (result.size() > cap) result.resize(cap);
  return result;
}

AdaptiveResolution::AdaptiveResolution(AdaptiveResolutionConfig config) : config_(config) {
  Reset();
}

void AdaptiveResolution::Reset() noexcept {
  scale_ = 1.0;
  smoothedMilliseconds_ = 0.0;
  frames_ = 0;
  cooldown_ = 0;
}

double AdaptiveResolution::Update(const double frameMilliseconds) noexcept {
  if (!std::isfinite(frameMilliseconds) || frameMilliseconds <= 0.0) return scale_;
  smoothedMilliseconds_ = frames_ == 0
    ? frameMilliseconds
    : smoothedMilliseconds_ + config_.emaAlpha * (frameMilliseconds - smoothedMilliseconds_);
  ++frames_;
  if (cooldown_ > 0) {
    --cooldown_;
    return scale_;
  }
  if (frames_ <= config_.warmFrames) return scale_;

  if (smoothedMilliseconds_ > config_.targetMilliseconds * config_.downThreshold) {
    scale_ = std::max(config_.minimumScale, scale_ - config_.step);
    cooldown_ = config_.cooldownFrames;
  } else if (smoothedMilliseconds_ < config_.targetMilliseconds * config_.upHeadroom) {
    scale_ = std::min(1.0, scale_ + config_.step);
    cooldown_ = config_.cooldownFrames;
  }
  return scale_;
}

}  // namespace matrixcode
