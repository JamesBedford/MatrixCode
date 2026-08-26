#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "matrixcode/core/GlyphSet.h"
#include "matrixcode/core/Rng.h"
#include "matrixcode/core/Types.h"

namespace matrixcode {

class RainSimulation;

/** The simulation surface used by MessageScheduler. */
class MessageSink {
 public:
  virtual ~MessageSink() = default;
  [[nodiscard]] virtual std::size_t Columns() const noexcept = 0;
  [[nodiscard]] virtual std::size_t Rows() const noexcept = 0;
  virtual void SetMessageTargets(
    std::span<const std::pair<std::size_t, std::uint8_t>> targets) = 0;
  virtual void UpdateMessageTargets(
    std::span<const std::pair<std::size_t, std::uint8_t>> targets) = 0;
  virtual void ClearMessageTargets() = 0;
  virtual void SetMessageIntensity(double intensity) = 0;
  virtual void SetMessageScramble(double probability) = 0;
};

/** Thin adapter that connects the scheduler to RainSimulation's message API. */
class RainSimulationMessageSink final : public MessageSink {
 public:
  explicit RainSimulationMessageSink(RainSimulation& simulation) noexcept;
  [[nodiscard]] std::size_t Columns() const noexcept override;
  [[nodiscard]] std::size_t Rows() const noexcept override;
  void SetMessageTargets(
    std::span<const std::pair<std::size_t, std::uint8_t>> targets) override;
  void UpdateMessageTargets(
    std::span<const std::pair<std::size_t, std::uint8_t>> targets) override;
  void ClearMessageTargets() override;
  void SetMessageIntensity(double intensity) override;
  void SetMessageScramble(double probability) override;

 private:
  RainSimulation& simulation_;
};

/** A (possibly fractional) grid rectangle in which one message copy is centered. */
struct MessageRegion {
  double columnStart = 0.0;
  double rowStart = 0.0;
  double columns = 0.0;
  double rows = 0.0;
};

/**
 * Deterministic port of the browser MessageScheduler. Its RNG is independent of
 * the rain RNG, and callers inject the clock through Update/PreviewOne.
 */
class MessageScheduler final {
 public:
  using TextResolver = std::function<std::string(std::string_view)>;

  explicit MessageScheduler(
    std::uint32_t seed = 1u,
    TextResolver resolver = {});

  void Configure(MessagesDocument document);
  void Update(
    double nowMilliseconds,
    MessageSink& sink,
    std::span<const MessageRegion> regions = {});
  void PreviewOne(
    double nowMilliseconds,
    MessageSink& sink,
    std::span<const MessageRegion> regions = {});
  void PreviewOne(
    double nowMilliseconds,
    MessageSink& sink,
    MessagesDocument document,
    std::span<const MessageRegion> regions = {});
  void ShiftTimelineBy(double durationMilliseconds) noexcept;

  [[nodiscard]] bool Active() const noexcept { return activeUntilMilliseconds_.has_value(); }
  [[nodiscard]] std::optional<double> NextFireMilliseconds() const noexcept {
    return nextFireMilliseconds_;
  }

 private:
  struct PlacedGlyph {
    std::size_t offset = 0;
    std::uint8_t glyph = 0;
  };
  struct Layout {
    std::vector<PlacedGlyph> glyphs;
    std::size_t width = 0;
  };
  struct NormalizedRegion {
    std::size_t columnStart = 0;
    std::size_t rowStart = 0;
    std::size_t columns = 0;
    std::size_t rows = 0;
  };
  struct ActivePlacement {
    NormalizedRegion region;
    double verticalSample = 0.0;
    double horizontalSample = 0.0;
  };

  [[nodiscard]] std::string Resolve(std::string_view raw) const;
  [[nodiscard]] double Gap();
  [[nodiscard]] static std::size_t PickAxisStart(
    std::size_t size,
    std::size_t extent,
    double position,
    double jitter,
    double sample);
  [[nodiscard]] std::vector<NormalizedRegion> NormalizeRegions(
    const MessageSink& sink,
    std::span<const MessageRegion> regions) const;
  [[nodiscard]] static std::string KeyForRegions(
    std::span<const NormalizedRegion> regions);
  void ChoosePlacements(std::span<const NormalizedRegion> regions);
  [[nodiscard]] bool ComputeHasRenderable(const MessagesDocument& document) const;
  [[nodiscard]] Layout LayOut(std::string_view message) const;
  [[nodiscard]] bool ApplyMessage(
    std::string display,
    MessageSink& sink,
    bool update);
  void Fire(
    double nowMilliseconds,
    MessageSink& sink,
    std::span<const NormalizedRegion> regions);
  [[nodiscard]] double Envelope(double nowMilliseconds) const noexcept;
  [[nodiscard]] double Scramble(double nowMilliseconds) const noexcept;

  GlyphSet glyphs_;
  Mulberry32 rng_;
  TextResolver resolver_;
  std::optional<MessagesDocument> configuration_;
  bool hasRenderable_ = false;
  std::optional<double> nextFireMilliseconds_;
  std::optional<double> activeStartMilliseconds_;
  std::optional<double> activeUntilMilliseconds_;
  bool pendingClear_ = false;
  std::size_t lastColumns_ = std::numeric_limits<std::size_t>::max();
  std::size_t lastRows_ = std::numeric_limits<std::size_t>::max();
  std::optional<std::string> activeRaw_;
  std::vector<ActivePlacement> activePlacements_;
  std::string activeDisplay_;
  std::string placementKey_;
};

}  // namespace matrixcode
