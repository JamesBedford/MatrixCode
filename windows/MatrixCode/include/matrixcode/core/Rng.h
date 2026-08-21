#pragma once

#include <cstdint>

namespace matrixcode {

class Mulberry32 final {
 public:
  explicit Mulberry32(std::uint32_t seed) noexcept : state_(seed) {}

  [[nodiscard]] double Next() noexcept {
    state_ += 0x6d2b79f5u;
    std::uint32_t t = (state_ ^ (state_ >> 15u)) * (1u | state_);
    t = (t + ((t ^ (t >> 7u)) * (61u | t))) ^ t;
    return static_cast<double>((t ^ (t >> 14u))) / 4294967296.0;
  }

  [[nodiscard]] std::uint32_t State() const noexcept { return state_; }

 private:
  std::uint32_t state_;
};

[[nodiscard]] inline std::uint32_t Hash32(std::uint32_t value) noexcept {
  value ^= value >> 16u;
  value *= 0x7feb352du;
  value ^= value >> 15u;
  value *= 0x846ca68bu;
  return value ^ (value >> 16u);
}

[[nodiscard]] inline double HashUnit(std::uint32_t value) noexcept {
  return static_cast<double>(Hash32(value) & 0x00ffffffu) / 16777216.0;
}

}  // namespace matrixcode
