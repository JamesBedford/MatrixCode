#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <map>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "TestHarness.h"
#include "matrixcode/core/MessageScheduler.h"
#include "matrixcode/core/RainSimulation.h"

namespace {

class FakeMessageSink final : public matrixcode::MessageSink {
 public:
  FakeMessageSink(const std::size_t columns, const std::size_t rows)
      : columns_(columns), rows_(rows) {}

  [[nodiscard]] std::size_t Columns() const noexcept override { return columns_; }
  [[nodiscard]] std::size_t Rows() const noexcept override { return rows_; }
  void Resize(const std::size_t columns, const std::size_t rows) noexcept {
    columns_ = columns;
    rows_ = rows;
  }
  void SetMessageTargets(
      const std::span<const std::pair<std::size_t, std::uint8_t>> values) override {
    Copy(values);
    ++sets;
  }
  void UpdateMessageTargets(
      const std::span<const std::pair<std::size_t, std::uint8_t>> values) override {
    Copy(values);
    ++updates;
  }
  void ClearMessageTargets() override {
    targets.clear();
    ++clears;
    intensity = 1.0;
    scramble = 0.0;
  }
  void SetMessageIntensity(const double value) override { intensity = value; }
  void SetMessageScramble(const double value) override { scramble = value; }

  std::map<std::size_t, std::uint8_t> targets;
  std::uint32_t sets = 0;
  std::uint32_t updates = 0;
  std::uint32_t clears = 0;
  double intensity = 1.0;
  double scramble = 0.0;

 private:
  void Copy(const std::span<const std::pair<std::size_t, std::uint8_t>> values) {
    targets.clear();
    for (const auto& [index, glyph] : values) targets[index] = glyph;
  }
  std::size_t columns_;
  std::size_t rows_;
};

matrixcode::MessagesDocument Document() {
  matrixcode::MessagesDocument document;
  document.messages = {"HELLO"};
  document.enabled = true;
  document.frequencyMilliseconds = 1000.0;
  document.persistenceMilliseconds = 500.0;
  document.appearMilliseconds = 0.0;
  document.disappearMilliseconds = 0.0;
  document.flickerOut = false;
  document.brightnessFade = true;
  document.layout = matrixcode::MessageLayout::Row;
  document.direction = matrixcode::MessageDirection::TopToBottom;
  document.position = 0.475;
  document.jitter = 0.25;
  return document;
}

std::uint32_t Feed(std::uint32_t hash, const std::uint32_t value) noexcept {
  for (std::uint32_t shift = 0; shift < 32; shift += 8) {
    hash ^= (value >> shift) & 0xffu;
    hash *= 0x01000193u;
  }
  return hash;
}

}  // namespace

void RunMessageSchedulerTests() {
  using namespace matrixcode;

  {
    auto document = Document();
    document.messages = {"A B"};
    document.position = 0.5;
    document.jitter = 0.0;
    FakeMessageSink sink(20, 11);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT_EQ(sink.sets, 1u);
    MX_EXPECT_EQ(sink.targets.size(), static_cast<std::size_t>(2));
    const std::size_t row = sink.targets.begin()->first / sink.Columns();
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 8));
    MX_EXPECT(!sink.targets.contains(row * sink.Columns() + 9));
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 10));
  }

  {
    auto document = Document();
    document.messages = {"ABC"};
    document.layout = MessageLayout::Drop;
    document.direction = MessageDirection::BottomToTop;
    document.position = 0.5;
    document.jitter = 0.0;
    FakeMessageSink sink(21, 20);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    GlyphSet glyphs;
    const std::size_t column = sink.targets.begin()->first % sink.Columns();
    MX_EXPECT_EQ(sink.targets.at(8 * sink.Columns() + column), *glyphs.MessageGlyph('C'));
    MX_EXPECT_EQ(sink.targets.at(9 * sink.Columns() + column), *glyphs.MessageGlyph('B'));
    MX_EXPECT_EQ(sink.targets.at(10 * sink.Columns() + column), *glyphs.MessageGlyph('A'));
  }

  {
    auto document = Document();
    document.messages = {"NEO"};
    document.appearMilliseconds = 400.0;
    document.persistenceMilliseconds = 2000.0;
    document.disappearMilliseconds = 600.0;
    document.flickerOut = true;
    FakeMessageSink sink(40, 40);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT(std::abs(sink.intensity) < 1e-12);
    MX_EXPECT(std::abs(sink.scramble - 1.0) < 1e-12);
    scheduler.Update(200.0, sink);
    MX_EXPECT(std::abs(sink.intensity - 0.5) < 1e-12);
    scheduler.Update(2700.0, sink);
    MX_EXPECT(std::abs(sink.intensity - 0.5) < 1e-12);
    MX_EXPECT(std::abs(sink.scramble - 0.5) < 1e-12);
    scheduler.Update(3000.0, sink);
    MX_EXPECT(sink.targets.empty());
  }

  {
    // Exact port of the browser's cross-language scheduler fixture.
    int tick = 0;
    FakeMessageSink sink(48, 30);
    MessageScheduler scheduler(0x5eed1eu, [&tick](const std::string_view raw) {
      std::string display(raw);
      constexpr std::string_view token = "{tick}";
      if (const auto at = display.find(token); at != std::string::npos) {
        display.replace(at, token.size(), std::to_string(tick));
      }
      return display;
    });
    auto document = Document();
    document.messages = {"WAKE {tick}", "NEO", "A \xF0\x9F\x98\x80 B"};
    document.frequencyMilliseconds = 900.0;
    document.persistenceMilliseconds = 650.0;
    document.appearMilliseconds = 300.0;
    document.disappearMilliseconds = 450.0;
    document.flickerOut = true;
    document.brightnessFade = true;
    document.position = 0.42;
    document.jitter = 0.6;
    scheduler.Configure(document);

    std::uint32_t hash = 0x811c9dc5u;
    for (int now = 0; now <= 16000; now += 125) {
      tick = now / 1000 % 10;
      if (now == 7000) sink.Resize(52, 32);
      const std::array<MessageRegion, 2> before{{
        {0.2, 0.4, 23.4, 29.2},
        {24.2, 0.4, 23.4, 29.2},
      }};
      const std::array<MessageRegion, 2> after{{
        {-2.4, 1.2, 28.1, 30.1},
        {26.2, 1.2, 28.1, 30.1},
      }};
      scheduler.Update(now, sink, now < 7000
        ? std::span<const MessageRegion>(before)
        : std::span<const MessageRegion>(after));

      const std::array<std::uint32_t, 6> values{{
        static_cast<std::uint32_t>(now),
        sink.sets,
        sink.updates,
        sink.clears,
        static_cast<std::uint32_t>(std::floor(sink.intensity * 1000000.0 + 0.5)),
        static_cast<std::uint32_t>(std::floor(sink.scramble * 1000000.0 + 0.5)),
      }};
      for (const auto value : values) hash = Feed(hash, value);
      hash = Feed(hash, static_cast<std::uint32_t>(sink.targets.size()));
      for (const auto& [index, glyph] : sink.targets) {
        hash = Feed(hash, static_cast<std::uint32_t>(index));
        hash = Feed(hash, glyph);
      }
    }
    MX_EXPECT_EQ(hash, 2931333020u);
    MX_EXPECT_EQ(sink.sets, 8u);
    MX_EXPECT_EQ(sink.updates, 3u);
    MX_EXPECT_EQ(sink.clears, 6u);
  }

  {
    std::string dynamic = "OK";
    FakeMessageSink sink(4, 4);
    MessageScheduler scheduler(5u, [&dynamic](std::string_view) { return dynamic; });
    auto document = Document();
    document.messages = {"{dynamic}"};
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT(!sink.targets.empty());
    dynamic = "TOO LONG";
    scheduler.Update(100.0, sink);
    MX_EXPECT(sink.targets.empty());
    MX_EXPECT(!scheduler.Active());
    MX_EXPECT(scheduler.NextFireMilliseconds().has_value());
  }

  {
    RainSimulation simulation(30, 20, 123u);
    RainSimulationMessageSink sink(simulation);
    MessageScheduler scheduler(7u);
    auto document = Document();
    document.messages = {"HI"};
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT(simulation.HasMessageTargets());
  }
}
