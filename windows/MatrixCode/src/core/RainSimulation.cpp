#include "matrixcode/core/RainSimulation.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "matrixcode/core/Controllers.h"

namespace matrixcode {
namespace {

constexpr double kTwoPi = 6.283185307179586476925286766559;
constexpr double kMinimumBrightness = 0.004;
constexpr double kTrailControlMinimum = 0.01;
constexpr double kTrailControlMaximum = 0.5;
constexpr double kMaximumTrailViewports = 3.0;
constexpr double kDensityScale = 0.5;

[[nodiscard]] float Float32(const double value) noexcept {
  return static_cast<float>(value);
}

[[nodiscard]] double VisibleTrailRows(
    const double trailLength, const double speedRowsPerSecond, const double scale) noexcept {
  return speedRowsPerSecond * scale * std::log(kMinimumBrightness) / std::log(trailLength);
}

[[nodiscard]] double TrailLengthForVisibleRows(
    const double rows, const double speedRowsPerSecond, const double scale) noexcept {
  return std::exp(std::log(kMinimumBrightness) * scale * speedRowsPerSecond / std::max(1.0, rows));
}

[[nodiscard]] std::uint8_t ByteRound(const double value) noexcept {
  return static_cast<std::uint8_t>(std::floor(value + 0.5));
}

}  // namespace

RainSimulation::RainSimulation(
    const std::size_t columns,
    const std::size_t rows,
    const std::uint32_t seed,
    SimConfig config,
    const GlyphMode glyphMode)
    : columns_(std::max<std::size_t>(1, columns)),
      rows_(std::max<std::size_t>(1, rows)),
      config_(config),
      glyphs_(glyphMode),
      seed_(seed),
      rng_(seed),
      messageRng_(seed ^ 0x27d4eb2du) {
  Allocate(columns_, rows_);
  SeedColumns(0, columns_);
}

void RainSimulation::Allocate(const std::size_t columns, const std::size_t rows) {
  streams_.assign(columns, {});
  respawnTimer_.assign(columns, 0.0f);
  headMark_.assign(rows, 0);
  const auto cells = columns * rows;
  brightness_.assign(cells, 0.0f);
  trailSpeed_.assign(cells, 0.0f);
  glyphNew_.assign(cells, 0);
  glyphOld_.assign(cells, 0);
  phase_.assign(cells, 0.0f);
  claimed_.assign(cells, 0);
  state_.assign(cells * 4, 0);
  messageTargets_.assign(cells, -1);

  Mulberry32 gateRng(seed_ ^ 0x85ebca6bu);
  columnGate_.resize(columns);
  for (std::size_t column = 0; column < columns; ++column) {
    columnGate_[column] = Float32(gateRng.Next());
  }
}

void RainSimulation::SeedColumns(const std::size_t first, const std::size_t last) {
  for (std::size_t column = first; column < last; ++column) {
    streams_[column].clear();
    respawnTimer_[column] = Float32(rng_.Next() * config_.respawnDelayJitter);
  }
}

void RainSimulation::SpawnStream(const std::size_t column) {
  streams_[column].push_back({
    -rng_.Next() * config_.startRowsAbove,
    config_.minSpeed + rng_.Next() * config_.speedRange,
    static_cast<std::uint8_t>(rng_.Next() < config_.whiteHeadFraction ? 1 : 0),
  });
}

void RainSimulation::LightHeadCell(
    const std::size_t column, const std::size_t row, const double trailSpeed) {
  const std::size_t index = row * columns_ + column;
  const std::uint8_t randomGlyph = glyphs_.RandomGlyphIndex(rng_);
  const std::int16_t target = messageActive_ ? messageTargets_[index] : -1;
  brightness_[index] = 1.0f;
  trailSpeed_[index] = Float32(trailSpeed);
  glyphOld_[index] = glyphNew_[index];
  glyphNew_[index] = target < 0
    ? randomGlyph
    : (messageScramble_ > 0.0 && messageRng_.Next() < messageScramble_)
      ? randomGlyph
      : static_cast<std::uint8_t>(target);
  phase_[index] = 1.0f;
  if (target >= 0) claimed_[index] = 1;
}

std::size_t RainSimulation::ActiveStreamCount(const std::size_t column) const noexcept {
  return column < streams_.size() ? streams_[column].size() : 0;
}

void RainSimulation::Resize(std::size_t columns, std::size_t rows) {
  columns = std::max<std::size_t>(1, columns);
  rows = std::max<std::size_t>(1, rows);
  if (columns == columns_ && rows == rows_) return;

  auto oldStreams = std::move(streams_);
  auto oldTimers = std::move(respawnTimer_);
  const auto oldColumns = columns_;
  Allocate(columns, rows);
  const auto kept = std::min(oldColumns, columns);
  for (std::size_t column = 0; column < kept; ++column) {
    streams_[column] = std::move(oldStreams[column]);
    respawnTimer_[column] = oldTimers[column];
  }
  if (columns > oldColumns) SeedColumns(oldColumns, columns);
  columns_ = columns;
  rows_ = rows;
  messageActive_ = false;
  messageIntensity_ = 1.0;
  messageScramble_ = 0.0;
}

void RainSimulation::WarmUp(const Controls& controls, const double seconds, const double step) {
  if (!std::isfinite(seconds) || !std::isfinite(step) || seconds <= 0.0 || step <= 0.0) return;
  const auto count = static_cast<std::size_t>(std::floor(seconds / step));
  for (std::size_t index = 0; index < count; ++index) Update(step, controls);
}

void RainSimulation::WarmUpDistributed(
    const Controls& controls, const double seconds, const double step) {
  const double density = controls.density * kDensityScale;
  const auto streamCount = static_cast<std::size_t>(std::max(1.0, std::floor(density + 0.5)));
  const double activeChance = std::clamp(density / (density + 0.6), 0.1, 1.0);
  const double minimumY = -config_.startRowsAbove;
  const double spanY = static_cast<double>(rows_) + config_.tailMargin - minimumY;
  const double speedMultiplier = std::max(controls.speed, 0.1);
  const double trailLength = EffectiveTrailLength(controls, rows_, config_);

  for (std::size_t column = 0; column < columns_; ++column) {
    if (rng_.Next() > activeChance) continue;
    for (std::size_t streamIndex = 0; streamIndex < streamCount; ++streamIndex) {
      Stream stream{
        minimumY + rng_.Next() * spanY,
        config_.minSpeed + rng_.Next() * config_.speedRange,
        static_cast<std::uint8_t>(rng_.Next() < config_.whiteHeadFraction ? 1 : 0),
      };
      streams_[column].push_back(stream);
      const auto headRow = std::min(
        static_cast<long long>(std::floor(stream.y)), static_cast<long long>(rows_) - 1);
      for (long long row = headRow; row >= 0; --row) {
        const double variedSpeed = EffectiveTrailSpeed(
          stream.speed * speedMultiplier, speedMultiplier, controls.trailVariation, config_);
        const double ageSeconds = (stream.y - static_cast<double>(row)) / variedSpeed;
        const double cellBrightness = std::pow(trailLength, ageSeconds / config_.trailLengthScale);
        if (cellBrightness < kMinimumBrightness) break;
        const std::size_t index = static_cast<std::size_t>(row) * columns_ + column;
        const float previous = brightness_[index];
        const float previousTrailSpeed = trailSpeed_[index];
        LightHeadCell(column, static_cast<std::size_t>(row), stream.speed);
        brightness_[index] = Float32(std::max(static_cast<double>(previous), cellBrightness));
        if (static_cast<double>(previous) > cellBrightness) trailSpeed_[index] = previousTrailSpeed;
      }
    }
  }

  Update(0.0, controls);
  WarmUp(controls, seconds, step);
}

void RainSimulation::Reset() {
  std::fill(brightness_.begin(), brightness_.end(), 0.0f);
  std::fill(trailSpeed_.begin(), trailSpeed_.end(), 0.0f);
  std::fill(glyphNew_.begin(), glyphNew_.end(), 0);
  std::fill(glyphOld_.begin(), glyphOld_.end(), 0);
  std::fill(phase_.begin(), phase_.end(), 0.0f);
  std::fill(state_.begin(), state_.end(), 0);
  time_ = 0.0;
  SeedColumns(0, columns_);
  messageActive_ = false;
  std::fill(claimed_.begin(), claimed_.end(), 0);
  messageIntensity_ = 1.0;
  messageScramble_ = 0.0;
}

void RainSimulation::SetMessageTargets(
    const std::span<const std::pair<std::size_t, std::uint8_t>> targets) {
  std::fill(messageTargets_.begin(), messageTargets_.end(), -1);
  for (const auto& [index, glyph] : targets) {
    if (index < messageTargets_.size()) messageTargets_[index] = glyph;
  }
  messageActive_ = true;
  std::fill(claimed_.begin(), claimed_.end(), 0);
  messageIntensity_ = 1.0;
  messageScramble_ = 0.0;
}

void RainSimulation::UpdateMessageTargets(
    const std::span<const std::pair<std::size_t, std::uint8_t>> targets) {
  if (!messageActive_) {
    SetMessageTargets(targets);
    return;
  }
  std::vector<std::int16_t> next(messageTargets_.size(), -1);
  for (const auto& [index, glyph] : targets) {
    if (index < next.size()) next[index] = glyph;
  }
  for (std::size_t index = 0; index < next.size(); ++index) {
    if (next[index] != messageTargets_[index]) claimed_[index] = 0;
  }
  messageTargets_ = std::move(next);
}

void RainSimulation::ClearMessageTargets() {
  if (messageActive_) {
    for (std::size_t index = 0; index < claimed_.size(); ++index) {
      if (claimed_[index] != 0) {
        brightness_[index] = Float32(
          std::max(static_cast<double>(brightness_[index]), config_.messageBrightFloor) * messageIntensity_);
      }
    }
  }
  messageActive_ = false;
  std::fill(claimed_.begin(), claimed_.end(), 0);
  messageIntensity_ = 1.0;
  messageScramble_ = 0.0;
}

void RainSimulation::SetMessageIntensity(const double intensity) noexcept {
  messageIntensity_ = std::clamp(intensity, 0.0, 1.0);
}

void RainSimulation::SetMessageScramble(const double probability) noexcept {
  messageScramble_ = std::clamp(probability, 0.0, 1.0);
}

void RainSimulation::AdvanceElapsed(const double elapsedSeconds, const Controls& controls) {
  const auto plan = PlanSimulationSteps(elapsedSeconds);
  for (std::size_t step = 0; step < plan.steps; ++step) Update(plan.deltaSeconds, controls);
}

void RainSimulation::Update(double deltaSeconds, const Controls& controls) {
  deltaSeconds = std::clamp(deltaSeconds, 0.0, 1.0 / 15.0);
  time_ += deltaSeconds;

  const double trailLength = EffectiveTrailLength(controls, rows_, config_);
  const double decayMultiplier = std::pow(trailLength, deltaSeconds / config_.trailLengthScale);
  const double trailVariation = std::clamp(controls.trailVariation, 0.0, 1.0);
  const double averageSpeed = config_.minSpeed + config_.speedRange * 0.5;
  const double crossfadeStep = deltaSeconds / config_.crossfadeDuration;
  const double synchronization = std::max(
    0.0, 1.0 + config_.globalSyncAmount * std::sin(time_ * config_.globalSyncHz * kTwoPi));
  const double mutationChance = 1.0 - std::exp(
    -config_.mutationRate * controls.glyphRate * synchronization * deltaSeconds);
  const double density = controls.density * kDensityScale;
  const double respawnProbability = 1.0 - std::exp(-config_.respawnChance * density * deltaSeconds);
  const double speedMultiplier = controls.speed;
  const auto maximumStreams = static_cast<std::size_t>(std::max(1.0, std::floor(density + 0.5)));
  const double gapScale = 1.0 / density;

  for (std::size_t column = 0; column < columns_; ++column) {
    auto& streams = streams_[column];
    respawnTimer_[column] = Float32(static_cast<double>(respawnTimer_[column]) - deltaSeconds);
    if (respawnTimer_[column] <= 0.0f && streams.size() < maximumStreams) {
      if (rng_.Next() < respawnProbability && spawnRateScale_ > columnGate_[column]) {
        SpawnStream(column);
        respawnTimer_[column] = Float32(
          (config_.respawnDelayMin + rng_.Next() * config_.respawnDelayJitter) * gapScale);
      }
    }

    for (std::size_t position = streams.size(); position > 0; --position) {
      auto& stream = streams[position - 1];
      const auto previousRow = static_cast<long long>(std::floor(stream.y));
      stream.y += stream.speed * speedMultiplier * deltaSeconds;
      const auto nextRow = static_cast<long long>(std::floor(stream.y));
      for (long long row = std::max(previousRow + 1, 0LL); row <= nextRow; ++row) {
        if (row < static_cast<long long>(rows_)) {
          LightHeadCell(column, static_cast<std::size_t>(row), stream.speed);
        }
      }
      if (stream.y - config_.tailMargin > static_cast<double>(rows_)) {
        streams.erase(streams.begin() + static_cast<std::ptrdiff_t>(position - 1));
      }
    }

    for (const auto& stream : streams) {
      const auto row = static_cast<long long>(std::floor(stream.y));
      if (row >= 0 && row < static_cast<long long>(rows_)) {
        headMark_[static_cast<std::size_t>(row)] |= stream.white != 0 ? 0x03 : 0x01;
      }
    }

    for (std::size_t row = 0; row < rows_; ++row) {
      const std::size_t index = row * columns_ + column;
      const std::int16_t target = messageActive_ ? messageTargets_[index] : -1;
      double value = brightness_[index];
      if (value > kMinimumBrightness) {
        if (trailVariation == 1.0) {
          value *= decayMultiplier;
        } else {
          const double streamSpeed =
            (trailSpeed_[index] != 0.0f ? trailSpeed_[index] : averageSpeed) * speedMultiplier;
          const double variedSpeed = EffectiveTrailSpeed(
            streamSpeed, speedMultiplier, trailVariation, config_);
          value *= std::pow(
            trailLength,
            deltaSeconds * streamSpeed / variedSpeed / config_.trailLengthScale);
        }
        if (value < kMinimumBrightness) value = 0.0;
        brightness_[index] = Float32(value);
      } else if (value != 0.0) {
        brightness_[index] = 0.0f;
        value = 0.0;
      }

      if (phase_[index] < 1.0f) {
        phase_[index] = Float32(std::min(1.0, static_cast<double>(phase_[index]) + crossfadeStep));
      }

      const std::uint8_t mark = headMark_[row];
      headMark_[row] = 0;
      const bool isHead = (mark & 0x01) != 0;
      const bool white = (mark & 0x02) != 0;
      if (!isHead && value > 0.05 && rng_.Next() < mutationChance) {
        const std::uint8_t randomGlyph = glyphs_.RandomGlyphIndex(rng_);
        if (target >= 0) {
          claimed_[index] = 1;
          const std::uint8_t next = messageScramble_ > 0.0 && messageRng_.Next() < messageScramble_
            ? randomGlyph
            : static_cast<std::uint8_t>(target);
          if (next != glyphNew_[index]) {
            glyphOld_[index] = glyphNew_[index];
            glyphNew_[index] = next;
            phase_[index] = 0.0f;
          }
        } else {
          glyphOld_[index] = glyphNew_[index];
          glyphNew_[index] = randomGlyph;
          phase_[index] = 0.0f;
        }
      }

      const double packedBrightness = target >= 0 && claimed_[index] != 0
        ? std::max(value, config_.messageBrightFloor) * messageIntensity_
        : value;
      const auto packed = PackCell(
        glyphNew_[index], packedBrightness, isHead, white, phase_[index], glyphOld_[index]);
      const auto output = index * 4;
      state_[output] = packed.newGlyph;
      state_[output + 1] = packed.brightness;
      state_[output + 2] = packed.flagsAndPhase;
      state_[output + 3] = packed.oldGlyph;
    }
  }
}

double DecayBrightness(
    const double value, const double decayPerSecond, const double deltaSeconds) noexcept {
  return value * std::pow(decayPerSecond, deltaSeconds);
}

double EffectiveTrailLength(
    const Controls& controls, const std::size_t rows, const SimConfig& config) noexcept {
  const double percentage = std::clamp(
    (controls.trailLength - kTrailControlMinimum) /
      (kTrailControlMaximum - kTrailControlMinimum),
    0.0,
    1.0);
  const double averageSpeed =
    (config.minSpeed + config.speedRange * 0.5) * std::max(controls.speed, 0.1);
  const double viewportRows = std::max(1.0, static_cast<double>(rows));
  const double previousMaximumRows = VisibleTrailRows(
    kTrailControlMaximum, averageSpeed, config.trailLengthScale);
  const double minimumRows = viewportRows;
  const double maximumRows = std::max({
    viewportRows * kMaximumTrailViewports, previousMaximumRows, minimumRows + 1.0});
  const double targetRows = minimumRows * std::pow(maximumRows / minimumRows, percentage);
  return TrailLengthForVisibleRows(targetRows, averageSpeed, config.trailLengthScale);
}

double EffectiveTrailSpeed(
    const double streamSpeed,
    const double speedControl,
    const double variation,
    const SimConfig& config) noexcept {
  const double averageSpeed =
    (config.minSpeed + config.speedRange * 0.5) * std::max(speedControl, 0.1);
  return averageSpeed + (streamSpeed - averageSpeed) * std::clamp(variation, 0.0, 1.0);
}

PackedCell PackCell(
    const std::uint8_t newGlyph,
    const double brightness,
    const bool isHead,
    const bool whiteHead,
    const double phase,
    const std::uint8_t oldGlyph) noexcept {
  const auto brightnessByte = ByteRound(std::clamp(brightness, 0.0, 1.0) * 255.0);
  const auto phaseByte = static_cast<std::uint8_t>(
    ByteRound(std::clamp(phase, 0.0, 1.0) * static_cast<double>(kPhaseMask)) & kPhaseMask);
  return {
    newGlyph,
    brightnessByte,
    static_cast<std::uint8_t>(
      (isHead ? kFlagIsHead : 0) | (whiteHead ? kFlagWhiteHead : 0) | phaseByte),
    oldGlyph,
  };
}

}  // namespace matrixcode
