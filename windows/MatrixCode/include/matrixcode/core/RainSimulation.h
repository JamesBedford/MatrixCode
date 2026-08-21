#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <utility>
#include <vector>

#include "matrixcode/core/GlyphSet.h"
#include "matrixcode/core/Types.h"

namespace matrixcode {

class RainSimulation final {
 public:
  RainSimulation(
    std::size_t columns,
    std::size_t rows,
    std::uint32_t seed = 0x9e3779b9u,
    SimConfig config = {},
    GlyphMode glyphMode = GlyphMode::Matrix);

  [[nodiscard]] std::size_t Columns() const noexcept { return columns_; }
  [[nodiscard]] std::size_t Rows() const noexcept { return rows_; }
  [[nodiscard]] double Time() const noexcept { return time_; }
  [[nodiscard]] std::span<const std::uint8_t> State() const noexcept { return state_; }
  [[nodiscard]] std::size_t ActiveStreamCount(std::size_t column) const noexcept;

  void SetSpawnRateScale(double value) noexcept { spawnRateScale_ = value; }
  [[nodiscard]] double SpawnRateScale() const noexcept { return spawnRateScale_; }
  void SetGlyphMode(GlyphMode mode) noexcept { glyphs_.SetMode(mode); }
  void Resize(std::size_t columns, std::size_t rows);
  void Reset();
  void WarmUp(const Controls& controls, double seconds = 2.0, double step = 1.0 / 60.0);
  void WarmUpDistributed(const Controls& controls, double seconds = 2.0, double step = 1.0 / 60.0);
  void AdvanceElapsed(double elapsedSeconds, const Controls& controls);
  void Update(double deltaSeconds, const Controls& controls);

  void SetMessageTargets(std::span<const std::pair<std::size_t, std::uint8_t>> targets);
  void UpdateMessageTargets(std::span<const std::pair<std::size_t, std::uint8_t>> targets);
  void ClearMessageTargets();
  void SetMessageIntensity(double intensity) noexcept;
  void SetMessageScramble(double probability) noexcept;
  [[nodiscard]] bool HasMessageTargets() const noexcept { return messageActive_; }

 private:
  struct Stream {
    double y = 0.0;
    double speed = 0.0;
    std::uint8_t white = 0;
  };

  void Allocate(std::size_t columns, std::size_t rows);
  void SeedColumns(std::size_t first, std::size_t last);
  void SpawnStream(std::size_t column);
  void LightHeadCell(std::size_t column, std::size_t row, double trailSpeed);

  std::size_t columns_;
  std::size_t rows_;
  SimConfig config_;
  GlyphSet glyphs_;
  std::uint32_t seed_;
  Mulberry32 rng_;
  Mulberry32 messageRng_;
  double time_ = 0.0;
  double spawnRateScale_ = 1.0;

  std::vector<std::vector<Stream>> streams_;
  std::vector<float> respawnTimer_;
  std::vector<float> columnGate_;
  std::vector<float> brightness_;
  std::vector<float> trailSpeed_;
  std::vector<std::uint8_t> glyphNew_;
  std::vector<std::uint8_t> glyphOld_;
  std::vector<float> phase_;
  std::vector<std::uint8_t> headMark_;
  std::vector<std::uint8_t> state_;

  bool messageActive_ = false;
  std::vector<std::int16_t> messageTargets_;
  std::vector<std::uint8_t> claimed_;
  double messageIntensity_ = 1.0;
  double messageScramble_ = 0.0;
};

[[nodiscard]] double DecayBrightness(double value, double decayPerSecond, double deltaSeconds) noexcept;
[[nodiscard]] double EffectiveTrailLength(const Controls& controls, std::size_t rows, const SimConfig& config) noexcept;
[[nodiscard]] double EffectiveTrailSpeed(
  double streamSpeed, double speedControl, double variation, const SimConfig& config) noexcept;
[[nodiscard]] PackedCell PackCell(
  std::uint8_t newGlyph,
  double brightness,
  bool isHead,
  bool whiteHead,
  double phase,
  std::uint8_t oldGlyph) noexcept;

}  // namespace matrixcode
