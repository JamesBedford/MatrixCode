#include "matrixcode/core/MessageScheduler.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <sstream>

#include "matrixcode/core/RainSimulation.h"
#include "matrixcode/core/Utf8.h"

namespace matrixcode {
namespace {

constexpr double kJitterMinimum = 0.75;
constexpr double kJitterSpan = 0.5;

[[nodiscard]] std::optional<std::size_t> ClampRoundedIndex(
    const double value, const double maximum, const bool roundUp) noexcept {
  if (std::isnan(value)) return std::nullopt;
  const double rounded = roundUp ? std::ceil(value) : std::floor(value);
  const double clamped = std::clamp(rounded, 0.0, maximum);
  return static_cast<std::size_t>(clamped);
}

}  // namespace

RainSimulationMessageSink::RainSimulationMessageSink(RainSimulation& simulation) noexcept
    : simulation_(simulation) {}

std::size_t RainSimulationMessageSink::Columns() const noexcept {
  return simulation_.Columns();
}

std::size_t RainSimulationMessageSink::Rows() const noexcept {
  return simulation_.Rows();
}

void RainSimulationMessageSink::SetMessageTargets(
    const std::span<const std::pair<std::size_t, std::uint8_t>> targets) {
  simulation_.SetMessageTargets(targets);
}

void RainSimulationMessageSink::UpdateMessageTargets(
    const std::span<const std::pair<std::size_t, std::uint8_t>> targets) {
  simulation_.UpdateMessageTargets(targets);
}

void RainSimulationMessageSink::ClearMessageTargets() {
  simulation_.ClearMessageTargets();
}

void RainSimulationMessageSink::SetMessageIntensity(const double intensity) {
  simulation_.SetMessageIntensity(intensity);
}

void RainSimulationMessageSink::SetMessageScramble(const double probability) {
  simulation_.SetMessageScramble(probability);
}

MessageScheduler::MessageScheduler(const std::uint32_t seed, TextResolver resolver)
    : glyphs_(GlyphMode::Matrix), rng_(seed), resolver_(std::move(resolver)) {
  if (!resolver_) {
    resolver_ = [](const std::string_view raw) { return std::string(raw); };
  }
}

void MessageScheduler::Configure(MessagesDocument document) {
  hasRenderable_ = ComputeHasRenderable(document);
  configuration_ = std::move(document);
  if (activeUntilMilliseconds_.has_value()) pendingClear_ = true;
  activeStartMilliseconds_.reset();
  activeUntilMilliseconds_.reset();
  nextFireMilliseconds_.reset();
  activePlacements_.clear();
  placementKey_.clear();
}

std::string MessageScheduler::Resolve(const std::string_view raw) const {
  return resolver_(raw);
}

double MessageScheduler::Gap() {
  return configuration_->frequencyMilliseconds *
    (kJitterMinimum + kJitterSpan * rng_.Next());
}

std::size_t MessageScheduler::PickAxisStart(
    const std::size_t size,
    const std::size_t extent,
    const double position,
    const double jitter,
    const double sample) {
  const std::size_t maximumStart = size > extent ? size - extent : 0;
  if (maximumStart == 0) return 0;
  const auto anchor = static_cast<long long>(std::floor(
    position * static_cast<double>(maximumStart) + 0.5));
  const auto halfSpan = static_cast<long long>(std::floor(
    jitter * static_cast<double>(maximumStart) / 2.0 + 0.5));
  const auto low = std::max(0LL, anchor - halfSpan);
  const auto high = std::min(static_cast<long long>(maximumStart), anchor + halfSpan);
  const auto count = static_cast<double>(high - low + 1);
  return static_cast<std::size_t>(
    low + static_cast<long long>(std::floor(sample * count)));
}

std::vector<MessageScheduler::NormalizedRegion> MessageScheduler::NormalizeRegions(
    const MessageSink& sink, const std::span<const MessageRegion> regions) const {
  const auto full = [&sink] {
    return std::vector<NormalizedRegion>{{0, 0, sink.Columns(), sink.Rows()}};
  };
  if (regions.empty()) return full();

  std::vector<NormalizedRegion> normalized;
  normalized.reserve(regions.size());
  const double maximumColumn = static_cast<double>(sink.Columns());
  const double maximumRow = static_cast<double>(sink.Rows());
  for (const auto& region : regions) {
    const auto columnStart = ClampRoundedIndex(region.columnStart, maximumColumn, false);
    const auto rowStart = ClampRoundedIndex(region.rowStart, maximumRow, false);
    const auto columnEnd = ClampRoundedIndex(
      region.columnStart + region.columns, maximumColumn, true);
    const auto rowEnd = ClampRoundedIndex(region.rowStart + region.rows, maximumRow, true);
    if (!columnStart.has_value() || !rowStart.has_value() ||
        !columnEnd.has_value() || !rowEnd.has_value()) continue;
    const auto clampedColumnEnd = std::max(*columnStart, *columnEnd);
    const auto clampedRowEnd = std::max(*rowStart, *rowEnd);
    if (clampedColumnEnd > *columnStart && clampedRowEnd > *rowStart) {
      normalized.push_back({
        *columnStart,
        *rowStart,
        clampedColumnEnd - *columnStart,
        clampedRowEnd - *rowStart,
      });
    }
  }
  return normalized.empty() ? full() : normalized;
}

std::string MessageScheduler::KeyForRegions(
    const std::span<const NormalizedRegion> regions) {
  std::ostringstream key;
  for (std::size_t index = 0; index < regions.size(); ++index) {
    if (index != 0) key << ';';
    const auto& region = regions[index];
    key << region.columnStart << ',' << region.rowStart << ','
        << region.columns << ',' << region.rows;
  }
  return key.str();
}

void MessageScheduler::ChoosePlacements(const std::span<const NormalizedRegion> regions) {
  activePlacements_.clear();
  activePlacements_.reserve(regions.size());
  for (const auto& region : regions) {
    const double verticalSample = configuration_->jitter > 0.0 ? rng_.Next() : 0.0;
    const double horizontalSample = configuration_->horizontalJitter > 0.0 ? rng_.Next() : 0.0;
    activePlacements_.push_back({region, verticalSample, horizontalSample});
  }
}

bool MessageScheduler::ComputeHasRenderable(const MessagesDocument& document) const {
  return std::any_of(document.messages.begin(), document.messages.end(), [this](const auto& raw) {
    return !LayOut(Resolve(raw)).glyphs.empty();
  });
}

MessageScheduler::Layout MessageScheduler::LayOut(const std::string_view message) const {
  const std::string_view trimmed = TrimUtf8(message);
  Layout result;
  for (std::size_t byteOffset = 0; byteOffset < trimmed.size();) {
    const Utf8CodePoint decoded = DecodeUtf8CodePoint(trimmed, byteOffset);
    if (decoded.value <= 0x7fu) {
      if (const auto glyph = glyphs_.MessageGlyph(static_cast<char>(decoded.value)); glyph.has_value()) {
        result.glyphs.push_back({result.width, *glyph});
      }
    }
    ++result.width;
    byteOffset += decoded.bytes;
  }
  return result;
}

bool MessageScheduler::ApplyMessage(
    std::string display, MessageSink& sink, const bool update) {
  const Layout layout = LayOut(display);
  const bool drop = configuration_->layout == MessageLayout::Drop;
  if (layout.glyphs.empty() || activePlacements_.empty() ||
      std::any_of(activePlacements_.begin(), activePlacements_.end(),
        [&layout, drop](const ActivePlacement& placement) {
          return layout.width > (drop ? placement.region.rows : placement.region.columns);
        })) {
    return false;
  }

  std::map<std::size_t, std::uint8_t> uniqueTargets;
  for (const auto& placement : activePlacements_) {
    if (drop) {
      const std::size_t startRow = placement.region.rowStart +
        PickAxisStart(
          placement.region.rows,
          layout.width,
          configuration_->position,
          configuration_->jitter,
          placement.verticalSample);
      const std::size_t column = placement.region.columnStart +
        PickAxisStart(
          placement.region.columns,
          1,
          configuration_->horizontalPosition,
          configuration_->horizontalJitter,
          placement.horizontalSample);
      const bool bottomToTop = configuration_->direction == MessageDirection::BottomToTop;
      for (const auto& glyph : layout.glyphs) {
        const std::size_t targetRow = bottomToTop
          ? startRow + layout.width - 1 - glyph.offset
          : startRow + glyph.offset;
        uniqueTargets[targetRow * sink.Columns() + column] = glyph.glyph;
      }
    } else {
      const std::size_t startColumn = placement.region.columnStart +
        PickAxisStart(
          placement.region.columns,
          layout.width,
          configuration_->horizontalPosition,
          configuration_->horizontalJitter,
          placement.horizontalSample);
      const std::size_t row = placement.region.rowStart +
        PickAxisStart(
          placement.region.rows,
          1,
          configuration_->position,
          configuration_->jitter,
          placement.verticalSample);
      for (const auto& glyph : layout.glyphs) {
        uniqueTargets[row * sink.Columns() + startColumn + glyph.offset] = glyph.glyph;
      }
    }
  }
  if (uniqueTargets.empty()) return false;

  std::vector<std::pair<std::size_t, std::uint8_t>> targets;
  targets.reserve(uniqueTargets.size());
  for (const auto& target : uniqueTargets) targets.push_back(target);
  if (update) sink.UpdateMessageTargets(targets);
  else sink.SetMessageTargets(targets);
  activeDisplay_ = std::move(display);
  return true;
}

void MessageScheduler::Fire(
    const double nowMilliseconds,
    MessageSink& sink,
    const std::span<const NormalizedRegion> regions) {
  std::vector<std::string> candidates;
  for (const auto& message : configuration_->messages) {
    const auto trimmed = TrimUtf8(message);
    if (!trimmed.empty()) candidates.emplace_back(trimmed);
  }
  if (candidates.empty()) {
    nextFireMilliseconds_ = nowMilliseconds + Gap();
    return;
  }

  const std::size_t selection = static_cast<std::size_t>(
    std::floor(rng_.Next() * static_cast<double>(candidates.size())));
  const std::string raw = candidates[selection];
  ChoosePlacements(regions);
  if (!ApplyMessage(Resolve(raw), sink, false)) {
    activePlacements_.clear();
    nextFireMilliseconds_ = nowMilliseconds + Gap();
    return;
  }

  activeRaw_ = raw;
  activeStartMilliseconds_ = nowMilliseconds;
  const double appear = std::max(0.0, configuration_->appearMilliseconds);
  const double disappear = std::max(0.0, configuration_->disappearMilliseconds);
  activeUntilMilliseconds_ = nowMilliseconds + appear +
    configuration_->persistenceMilliseconds + disappear;
  sink.SetMessageIntensity(configuration_->brightnessFade ? Envelope(nowMilliseconds) : 1.0);
  sink.SetMessageScramble(configuration_->flickerOut ? Scramble(nowMilliseconds) : 0.0);
}

double MessageScheduler::Envelope(const double nowMilliseconds) const noexcept {
  const double appear = std::max(0.0, configuration_->appearMilliseconds);
  const double disappear = std::max(0.0, configuration_->disappearMilliseconds);
  const double elapsed = nowMilliseconds - *activeStartMilliseconds_;
  if (appear > 0.0 && elapsed < appear) return elapsed / appear;
  const double fadeOutStart = *activeUntilMilliseconds_ - *activeStartMilliseconds_ - disappear;
  if (disappear > 0.0 && elapsed > fadeOutStart) {
    return std::max(0.0, (*activeUntilMilliseconds_ - nowMilliseconds) / disappear);
  }
  return 1.0;
}

double MessageScheduler::Scramble(const double nowMilliseconds) const noexcept {
  const double appear = std::max(0.0, configuration_->appearMilliseconds);
  const double disappear = std::max(0.0, configuration_->disappearMilliseconds);
  const double elapsed = nowMilliseconds - *activeStartMilliseconds_;
  if (appear > 0.0 && elapsed < appear) return 1.0 - elapsed / appear;
  if (disappear > 0.0) {
    const double fadeOutStart = *activeUntilMilliseconds_ - *activeStartMilliseconds_ - disappear;
    if (elapsed > fadeOutStart) return std::min(1.0, (elapsed - fadeOutStart) / disappear);
  }
  return 0.0;
}

void MessageScheduler::Update(
    const double nowMilliseconds,
    MessageSink& sink,
    const std::span<const MessageRegion> regions) {
  const auto normalized = NormalizeRegions(sink, regions);
  const std::string placementKey = KeyForRegions(normalized);
  if (pendingClear_) {
    sink.ClearMessageTargets();
    pendingClear_ = false;
  }

  if (!configuration_.has_value() || !configuration_->enabled || !hasRenderable_) {
    if (activeUntilMilliseconds_.has_value()) {
      sink.ClearMessageTargets();
      activeStartMilliseconds_.reset();
      activeUntilMilliseconds_.reset();
    }
    nextFireMilliseconds_.reset();
    lastColumns_ = sink.Columns();
    lastRows_ = sink.Rows();
    placementKey_ = placementKey;
    return;
  }

  const bool placementChanged = placementKey != placementKey_;
  if ((sink.Columns() != lastColumns_ || sink.Rows() != lastRows_ || placementChanged) &&
      activeUntilMilliseconds_.has_value()) {
    ChoosePlacements(normalized);
    const std::string display = activeRaw_.has_value() ? Resolve(*activeRaw_) : activeDisplay_;
    if (!ApplyMessage(display, sink, false)) {
      sink.ClearMessageTargets();
      activeRaw_.reset();
      activeStartMilliseconds_.reset();
      activeUntilMilliseconds_.reset();
      nextFireMilliseconds_ = nowMilliseconds + Gap();
      activePlacements_.clear();
    }
  }
  lastColumns_ = sink.Columns();
  lastRows_ = sink.Rows();
  placementKey_ = placementKey;

  if (activeUntilMilliseconds_.has_value()) {
    if (nowMilliseconds >= *activeUntilMilliseconds_) {
      sink.ClearMessageTargets();
      activeStartMilliseconds_.reset();
      activeUntilMilliseconds_.reset();
      nextFireMilliseconds_ = nowMilliseconds + Gap();
      activePlacements_.clear();
    } else {
      if (activeRaw_.has_value()) {
        const std::string display = Resolve(*activeRaw_);
        if (display != activeDisplay_) {
          if (!ApplyMessage(display, sink, true)) {
            sink.ClearMessageTargets();
            activeRaw_.reset();
            activeStartMilliseconds_.reset();
            activeUntilMilliseconds_.reset();
            nextFireMilliseconds_ = nowMilliseconds + Gap();
            activePlacements_.clear();
            return;
          }
        }
      }
      sink.SetMessageIntensity(configuration_->brightnessFade ? Envelope(nowMilliseconds) : 1.0);
      sink.SetMessageScramble(configuration_->flickerOut ? Scramble(nowMilliseconds) : 0.0);
    }
    return;
  }

  if (!nextFireMilliseconds_.has_value()) {
    nextFireMilliseconds_ = nowMilliseconds + Gap();
    return;
  }
  if (nowMilliseconds >= *nextFireMilliseconds_) Fire(nowMilliseconds, sink, normalized);
}

void MessageScheduler::PreviewOne(
    const double nowMilliseconds,
    MessageSink& sink,
    const std::span<const MessageRegion> regions) {
  if (!configuration_.has_value()) return;
  if (pendingClear_) {
    sink.ClearMessageTargets();
    pendingClear_ = false;
  }
  lastColumns_ = sink.Columns();
  lastRows_ = sink.Rows();
  const auto normalized = NormalizeRegions(sink, regions);
  placementKey_ = KeyForRegions(normalized);
  Fire(nowMilliseconds, sink, normalized);
}

void MessageScheduler::PreviewOne(
    const double nowMilliseconds,
    MessageSink& sink,
    MessagesDocument document,
    const std::span<const MessageRegion> regions) {
  Configure(std::move(document));
  PreviewOne(nowMilliseconds, sink, regions);
}

void MessageScheduler::ShiftTimelineBy(const double durationMilliseconds) noexcept {
  if (!std::isfinite(durationMilliseconds) || durationMilliseconds <= 0.0) return;
  if (nextFireMilliseconds_.has_value()) *nextFireMilliseconds_ += durationMilliseconds;
  if (activeStartMilliseconds_.has_value()) *activeStartMilliseconds_ += durationMilliseconds;
  if (activeUntilMilliseconds_.has_value()) *activeUntilMilliseconds_ += durationMilliseconds;
}

}  // namespace matrixcode
