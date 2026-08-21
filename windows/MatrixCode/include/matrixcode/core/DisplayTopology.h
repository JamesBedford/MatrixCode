#pragma once

#include <span>
#include <vector>

namespace matrixcode {

struct PhysicalDisplay {
  double left = 0.0;
  double top = 0.0;
  double width = 0.0;
  double height = 0.0;
  double logicalPerPixelX = 1.0;
  double logicalPerPixelY = 1.0;
};

struct LogicalDisplay {
  double left = 0.0;
  double top = 0.0;
  double width = 0.0;
  double height = 0.0;
  double logicalPerPixelX = 1.0;
  double logicalPerPixelY = 1.0;
};

struct DisplayTopology {
  std::vector<LogicalDisplay> displays;
  double width = 0.0;
  double height = 0.0;
};

/**
 * Convert a physical Windows monitor arrangement to one continuous logical grid. Each display
 * retains its local DPI scale and logical size. Adjacent displays share the normal coordinate of
 * their seam; the leading point of the overlap is the deterministic tangential anchor because
 * unequal DPI scales cannot map every point along that physical seam to one logical coordinate.
 */
[[nodiscard]] DisplayTopology SolveDisplayTopology(
  std::span<const PhysicalDisplay> displays) noexcept;

}  // namespace matrixcode
