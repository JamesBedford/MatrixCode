#include "matrixcode/core/DisplayTopology.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <tuple>
#include <vector>

namespace matrixcode {
namespace {

constexpr double kTouchTolerancePixels = 0.5;

[[nodiscard]] std::size_t ReferenceDisplay(
    const std::span<const PhysicalDisplay> displays) noexcept {
  for (std::size_t index = 0; index < displays.size(); ++index) {
    const auto& display = displays[index];
    if (display.left <= 0.0 && display.top <= 0.0 &&
        display.left + display.width > 0.0 && display.top + display.height > 0.0) {
      return index;
    }
  }
  return 0;
}

[[nodiscard]] double Right(const PhysicalDisplay& display) noexcept {
  return display.left + std::max(0.0, display.width);
}

[[nodiscard]] double Bottom(const PhysicalDisplay& display) noexcept {
  return display.top + std::max(0.0, display.height);
}

[[nodiscard]] bool Touches(const double a, const double b) noexcept {
  return std::abs(a - b) <= kTouchTolerancePixels;
}

/**
 * Place `target` from an already-placed adjacent display. The leading edge of
 * the physical seam overlap is the deterministic tangential anchor. Different
 * DPI scales cannot agree at every point along a seam, but this preserves each
 * monitor's true logical size and makes the shared grid exact at that anchor.
 */
[[nodiscard]] bool PlaceAdjacent(
    const PhysicalDisplay& sourcePhysical,
    const LogicalDisplay& sourceLogical,
    const PhysicalDisplay& targetPhysical,
    LogicalDisplay& targetLogical) noexcept {
  const double overlapTop = std::max(sourcePhysical.top, targetPhysical.top);
  const double overlapBottom = std::min(Bottom(sourcePhysical), Bottom(targetPhysical));
  if (overlapBottom > overlapTop) {
    const double sourceAnchor = sourceLogical.top +
      (overlapTop - sourcePhysical.top) * sourceLogical.logicalPerPixelY;
    const double targetTop = sourceAnchor -
      (overlapTop - targetPhysical.top) * targetLogical.logicalPerPixelY;
    if (Touches(Right(sourcePhysical), targetPhysical.left)) {
      targetLogical.left = sourceLogical.left + sourceLogical.width;
      targetLogical.top = targetTop;
      return true;
    }
    if (Touches(sourcePhysical.left, Right(targetPhysical))) {
      targetLogical.left = sourceLogical.left - targetLogical.width;
      targetLogical.top = targetTop;
      return true;
    }
  }

  const double overlapLeft = std::max(sourcePhysical.left, targetPhysical.left);
  const double overlapRight = std::min(Right(sourcePhysical), Right(targetPhysical));
  if (overlapRight > overlapLeft) {
    const double sourceAnchor = sourceLogical.left +
      (overlapLeft - sourcePhysical.left) * sourceLogical.logicalPerPixelX;
    const double targetLeft = sourceAnchor -
      (overlapLeft - targetPhysical.left) * targetLogical.logicalPerPixelX;
    if (Touches(Bottom(sourcePhysical), targetPhysical.top)) {
      targetLogical.left = targetLeft;
      targetLogical.top = sourceLogical.top + sourceLogical.height;
      return true;
    }
    if (Touches(sourcePhysical.top, Bottom(targetPhysical))) {
      targetLogical.left = targetLeft;
      targetLogical.top = sourceLogical.top - targetLogical.height;
      return true;
    }
  }
  return false;
}

[[nodiscard]] double CenterDistanceSquared(
    const PhysicalDisplay& left, const PhysicalDisplay& right) noexcept {
  const double dx = left.left + left.width * 0.5 - right.left - right.width * 0.5;
  const double dy = left.top + left.height * 0.5 - right.top - right.height * 0.5;
  return dx * dx + dy * dy;
}

}  // namespace

DisplayTopology SolveDisplayTopology(const std::span<const PhysicalDisplay> displays) noexcept {
  DisplayTopology topology;
  if (displays.empty()) return topology;

  topology.displays.reserve(displays.size());
  for (const auto& source : displays) {
    const double scaleX = std::max(0.01, source.logicalPerPixelX);
    const double scaleY = std::max(0.01, source.logicalPerPixelY);
    topology.displays.push_back({
      0.0,
      0.0,
      std::max(0.0, source.width) * scaleX,
      std::max(0.0, source.height) * scaleY,
      scaleX,
      scaleY,
    });
  }

  const std::size_t referenceIndex = ReferenceDisplay(displays);
  std::vector<bool> placed(displays.size(), false);
  placed[referenceIndex] = true;
  std::size_t placedCount = 1;
  while (placedCount < displays.size()) {
    bool found = false;
    std::size_t bestSource = 0;
    std::size_t bestTarget = 0;
    LogicalDisplay bestPlacement{};
    auto bestKey = std::tuple{
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<std::size_t>::max(),
      std::numeric_limits<std::size_t>::max(),
    };
    for (std::size_t source = 0; source < displays.size(); ++source) {
      if (!placed[source]) continue;
      for (std::size_t target = 0; target < displays.size(); ++target) {
        if (placed[target]) continue;
        auto candidate = topology.displays[target];
        if (!PlaceAdjacent(
              displays[source], topology.displays[source], displays[target], candidate)) continue;
        const auto key = std::tuple{
          CenterDistanceSquared(displays[source], displays[target]),
          displays[target].top,
          displays[target].left,
          displays[source].top,
          displays[source].left,
          source,
          target,
        };
        if (!found || key < bestKey) {
          found = true;
          bestKey = key;
          bestSource = source;
          bestTarget = target;
          bestPlacement = candidate;
        }
      }
    }
    if (found) {
      (void)bestSource;
      topology.displays[bestTarget] = bestPlacement;
      placed[bestTarget] = true;
      ++placedCount;
      continue;
    }

    // A gap in the Windows virtual arrangement leaves no physical seam to
    // constrain. Anchor the lexicographically first remaining monitor to the
    // reference coordinate system while retaining its own logical size/scale.
    std::size_t target = displays.size();
    for (std::size_t index = 0; index < displays.size(); ++index) {
      if (placed[index]) continue;
      if (target == displays.size() ||
          std::tie(displays[index].top, displays[index].left, index) <
            std::tie(displays[target].top, displays[target].left, target)) target = index;
    }
    const auto& referencePhysical = displays[referenceIndex];
    const auto& referenceLogical = topology.displays[referenceIndex];
    topology.displays[target].left = referenceLogical.left +
      (displays[target].left - referencePhysical.left) * referenceLogical.logicalPerPixelX;
    topology.displays[target].top = referenceLogical.top +
      (displays[target].top - referencePhysical.top) * referenceLogical.logicalPerPixelY;
    placed[target] = true;
    ++placedCount;
  }

  double minimumLeft = std::numeric_limits<double>::infinity();
  double minimumTop = std::numeric_limits<double>::infinity();
  double maximumRight = -std::numeric_limits<double>::infinity();
  double maximumBottom = -std::numeric_limits<double>::infinity();
  for (const auto& display : topology.displays) {
    minimumLeft = std::min(minimumLeft, display.left);
    minimumTop = std::min(minimumTop, display.top);
    maximumRight = std::max(maximumRight, display.left + display.width);
    maximumBottom = std::max(maximumBottom, display.top + display.height);
  }
  for (auto& display : topology.displays) {
    display.left -= minimumLeft;
    display.top -= minimumTop;
  }
  topology.width = std::max(0.0, maximumRight - minimumLeft);
  topology.height = std::max(0.0, maximumBottom - minimumTop);
  return topology;
}

}  // namespace matrixcode
