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
  document.position = 0.5;
  document.jitter = 0.25;
  document.horizontalPosition = 0.5;
  document.horizontalJitter = 0.0;
  return document;
}

struct Bounds {
  std::size_t firstRow;
  std::size_t lastRow;
  std::size_t firstColumn;
  std::size_t lastColumn;
};

Bounds TargetBounds(const FakeMessageSink& sink) {
  Bounds bounds{sink.Rows(), 0, sink.Columns(), 0};
  for (const auto& [index, glyph] : sink.targets) {
    static_cast<void>(glyph);
    const std::size_t row = index / sink.Columns();
    const std::size_t column = index % sink.Columns();
    bounds.firstRow = std::min(bounds.firstRow, row);
    bounds.lastRow = std::max(bounds.lastRow, row);
    bounds.firstColumn = std::min(bounds.firstColumn, column);
    bounds.lastColumn = std::max(bounds.lastColumn, column);
  }
  return bounds;
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

  // Percentage positions anchor the message centre within the whole region.
  for (const auto layout : {MessageLayout::Row, MessageLayout::Drop}) {
    for (const double position : {0.0, 0.25, 0.5, 0.75, 1.0}) {
      std::string dynamic = "ABCD";
      FakeMessageSink sink(100, 100);
      MessageScheduler scheduler(13u, [&dynamic](std::string_view) { return dynamic; });
      auto document = Document();
      document.messages = {"{dynamic}"};
      document.layout = layout;
      document.position = position;
      document.horizontalPosition = position;
      document.jitter = 0.0;
      document.horizontalJitter = 0.0;
      const std::array<MessageRegion, 1> region{{{10.0, 20.0, 80.0, 60.0}}};
      scheduler.PreviewOne(0.0, sink, document, region);
      for (const std::string text : {"ABCD", "ABCDE", "ABCDEFGHIJKL"}) {
        dynamic = text;
        scheduler.Update(100.0, sink, region);
        const auto bounds = TargetBounds(sink);
        const double columnExtent = layout == MessageLayout::Row ? text.size() : 1;
        const double rowExtent = layout == MessageLayout::Drop ? text.size() : 1;
        // Quantization can move a centre by at most half a cell; edges clamp.
        const double expectedColumnCentre = std::clamp(position * 80.0,
          columnExtent / 2.0, 80.0 - columnExtent / 2.0);
        const double expectedRowCentre = std::clamp(position * 60.0,
          rowExtent / 2.0, 60.0 - rowExtent / 2.0);
        const double columnCentre = (bounds.firstColumn + bounds.lastColumn + 1) / 2.0 - 10.0;
        const double rowCentre = (bounds.firstRow + bounds.lastRow + 1) / 2.0 - 20.0;
        MX_EXPECT(std::abs(columnCentre - expectedColumnCentre) <= 0.5);
        MX_EXPECT(std::abs(rowCentre - expectedRowCentre) <= 0.5);
        MX_EXPECT_EQ(sink.targets.size(), text.size());
      }
    }
  }

  {
    auto document = Document();
    document.messages = {"A B"};
    document.position = 0.5;
    document.jitter = 0.0;
    document.horizontalPosition = 0.5;
    document.horizontalJitter = 0.0;
    FakeMessageSink sink(20, 11);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT_EQ(sink.sets, 1u);
    MX_EXPECT_EQ(sink.targets.size(), static_cast<std::size_t>(2));
    const std::size_t row = sink.targets.begin()->first / sink.Columns();
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 9));
    MX_EXPECT(!sink.targets.contains(row * sink.Columns() + 10));
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 11));
  }

  {
    auto document = Document();
    document.messages = {std::string("A\xF0\x9F\x98\x80" "B")};
    document.position = 0.5;
    document.jitter = 0.0;
    document.horizontalPosition = 0.5;
    document.horizontalJitter = 0.0;
    FakeMessageSink sink(20, 11);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    MX_EXPECT_EQ(sink.targets.size(), static_cast<std::size_t>(2));
    const std::size_t row = sink.targets.begin()->first / sink.Columns();
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 9));
    MX_EXPECT(sink.targets.contains(row * sink.Columns() + 11));
  }

  {
    const std::array<MessageRegion, 1> region{{{3.0, 2.0, 10.0, 5.0}}};
    auto left = Document();
    left.messages = {"ABC"};
    left.position = 0.0;
    left.jitter = 0.0;
    left.horizontalPosition = 0.0;
    left.horizontalJitter = 0.0;
    FakeMessageSink leftSink(20, 12);
    MessageScheduler leftScheduler(1u);
    leftScheduler.PreviewOne(0.0, leftSink, left, region);
    const auto leftBounds = TargetBounds(leftSink);
    MX_EXPECT_EQ(leftBounds.firstRow, static_cast<std::size_t>(2));
    MX_EXPECT_EQ(leftBounds.firstColumn, static_cast<std::size_t>(3));
    MX_EXPECT_EQ(leftBounds.lastColumn, static_cast<std::size_t>(5));

    auto right = left;
    right.horizontalPosition = 1.0;
    FakeMessageSink rightSink(20, 12);
    MessageScheduler rightScheduler(1u);
    rightScheduler.PreviewOne(0.0, rightSink, right, region);
    const auto rightBounds = TargetBounds(rightSink);
    MX_EXPECT_EQ(rightBounds.firstColumn, static_cast<std::size_t>(10));
    MX_EXPECT_EQ(rightBounds.lastColumn, static_cast<std::size_t>(12));
  }

  {
    auto document = Document();
    document.messages = {"ABC"};
    document.layout = MessageLayout::Drop;
    document.direction = MessageDirection::BottomToTop;
    document.position = 0.5;
    document.jitter = 0.0;
    document.horizontalPosition = 0.5;
    document.horizontalJitter = 0.0;
    FakeMessageSink sink(21, 20);
    MessageScheduler scheduler(1u);
    scheduler.PreviewOne(0.0, sink, document);
    GlyphSet glyphs;
    const std::size_t column = sink.targets.begin()->first % sink.Columns();
    MX_EXPECT_EQ(sink.targets.at(9 * sink.Columns() + column), *glyphs.MessageGlyph('C'));
    MX_EXPECT_EQ(sink.targets.at(10 * sink.Columns() + column), *glyphs.MessageGlyph('B'));
    MX_EXPECT_EQ(sink.targets.at(11 * sink.Columns() + column), *glyphs.MessageGlyph('A'));
  }

  {
    const std::array<MessageRegion, 1> region{{{3.0, 4.0, 7.0, 8.0}}};
    auto topLeft = Document();
    topLeft.messages = {"ABC"};
    topLeft.layout = MessageLayout::Drop;
    topLeft.position = 0.0;
    topLeft.jitter = 0.0;
    topLeft.horizontalPosition = 0.0;
    topLeft.horizontalJitter = 0.0;
    FakeMessageSink topLeftSink(15, 16);
    MessageScheduler topLeftScheduler(1u);
    topLeftScheduler.PreviewOne(0.0, topLeftSink, topLeft, region);
    const auto topLeftBounds = TargetBounds(topLeftSink);
    MX_EXPECT_EQ(topLeftBounds.firstRow, static_cast<std::size_t>(4));
    MX_EXPECT_EQ(topLeftBounds.lastRow, static_cast<std::size_t>(6));
    MX_EXPECT_EQ(topLeftBounds.firstColumn, static_cast<std::size_t>(3));

    auto bottomRight = topLeft;
    bottomRight.position = 1.0;
    bottomRight.horizontalPosition = 1.0;
    FakeMessageSink bottomRightSink(15, 16);
    MessageScheduler bottomRightScheduler(1u);
    bottomRightScheduler.PreviewOne(0.0, bottomRightSink, bottomRight, region);
    const auto bottomRightBounds = TargetBounds(bottomRightSink);
    MX_EXPECT_EQ(bottomRightBounds.firstRow, static_cast<std::size_t>(9));
    MX_EXPECT_EQ(bottomRightBounds.lastRow, static_cast<std::size_t>(11));
    MX_EXPECT_EQ(bottomRightBounds.firstColumn, static_cast<std::size_t>(9));
  }

  {
    const std::array<MessageRegion, 1> region{{{3.0, 4.0, 10.0, 10.0}}};
    std::size_t firstHorizontalStart = 20;
    std::size_t lastHorizontalStart = 0;
    std::size_t firstVerticalStart = 20;
    std::size_t lastVerticalStart = 0;
    for (std::uint32_t seed = 1; seed <= 64; ++seed) {
      auto row = Document();
      row.messages = {"ABC"};
      row.position = 0.0;
      row.jitter = 0.0;
      row.horizontalPosition = 1.0;
      row.horizontalJitter = 1.0;
      FakeMessageSink rowSink(20, 18);
      MessageScheduler rowScheduler(seed);
      rowScheduler.PreviewOne(0.0, rowSink, row, region);
      const auto rowBounds = TargetBounds(rowSink);
      MX_EXPECT(rowBounds.firstColumn >= 3 && rowBounds.firstColumn <= 10);
      MX_EXPECT(rowBounds.lastColumn <= 12);
      firstHorizontalStart = std::min(firstHorizontalStart, rowBounds.firstColumn);
      lastHorizontalStart = std::max(lastHorizontalStart, rowBounds.firstColumn);

      auto drop = row;
      drop.layout = MessageLayout::Drop;
      drop.position = 1.0;
      drop.jitter = 1.0;
      drop.horizontalPosition = 0.0;
      drop.horizontalJitter = 0.0;
      FakeMessageSink dropSink(20, 18);
      MessageScheduler dropScheduler(seed);
      dropScheduler.PreviewOne(0.0, dropSink, drop, region);
      const auto dropBounds = TargetBounds(dropSink);
      MX_EXPECT(dropBounds.firstRow >= 4 && dropBounds.firstRow <= 11);
      MX_EXPECT(dropBounds.lastRow <= 13);
      firstVerticalStart = std::min(firstVerticalStart, dropBounds.firstRow);
      lastVerticalStart = std::max(lastVerticalStart, dropBounds.firstRow);
    }
    MX_EXPECT(firstHorizontalStart < lastHorizontalStart);
    MX_EXPECT(firstVerticalStart < lastVerticalStart);
  }

  {
    // Jitter is a radius measured against the entire physical region, even for wide text.
    for (const auto layout : {MessageLayout::Row, MessageLayout::Drop}) {
      std::size_t minimum = 100, maximum = 0;
      for (std::uint32_t seed = 1; seed <= 2048; ++seed) {
        auto document = Document();
        document.messages = {std::string(20, 'A')};
        document.layout = layout;
        document.jitter = 0.25;
        document.horizontalJitter = 0.25;
        FakeMessageSink sink(100, 100);
        MessageScheduler scheduler(seed);
        scheduler.PreviewOne(0.0, sink, document);
        const auto bounds = TargetBounds(sink);
        const auto start = layout == MessageLayout::Row ? bounds.firstColumn : bounds.firstRow;
        MX_EXPECT(start >= 15 && start <= 65);
        minimum = std::min(minimum, start);
        maximum = std::max(maximum, start);
      }
      MX_EXPECT_EQ(minimum, std::size_t{15});
      MX_EXPECT_EQ(maximum, std::size_t{65});
    }
  }

  {
    const std::array<MessageRegion, 3> regions{{{0, 0, 40, 40}, {40, 0, 40, 40}, {80, 0, 40, 40}}};
    auto document = Document();
    document.messages = {"A"};
    document.singleMonitor = true;
    document.horizontalJitter = 0.25;
    std::size_t minimum = 120, maximum = 0;
    for (std::uint32_t seed = 1; seed <= 2048; ++seed) {
      FakeMessageSink sink(120, 40);
      MessageScheduler scheduler(seed);
      scheduler.PreviewOne(0.0, sink, document, regions);
      MX_EXPECT_EQ(sink.targets.size(), std::size_t{1});
      const auto bounds = TargetBounds(sink);
      MX_EXPECT(bounds.firstColumn >= 30 && bounds.firstColumn <= 90);
      MX_EXPECT(bounds.firstRow >= 10 && bounds.firstRow <= 30);
      minimum = std::min(minimum, bounds.firstColumn);
      maximum = std::max(maximum, bounds.firstColumn);
    }
    MX_EXPECT_EQ(minimum, std::size_t{30});
    MX_EXPECT_EQ(maximum, std::size_t{90});
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
    const std::array<MessageRegion, 2> regions{{{0, 0, 40, 30}, {40, 0, 40, 30}}};
    auto shared = Document();
    shared.jitter = 1.0;
    shared.horizontalJitter = 1.0;
    auto independent = shared;
    independent.independentMonitorPositions = true;
    MessageScheduler sharedScheduler(123u), independentScheduler(123u), oneScheduler(123u);
    sharedScheduler.Configure(shared);
    independentScheduler.Configure(independent);
    oneScheduler.Configure(shared);
    FakeMessageSink sharedSink(80, 30), independentSink(80, 30), oneSink(80, 30);
    bool sawDifference = false;
    for (int now = 0; now <= 20000; now += 100) {
      sharedScheduler.Update(now, sharedSink, regions);
      independentScheduler.Update(now, independentSink, regions);
      oneScheduler.Update(now, oneSink);
      MX_EXPECT_EQ(sharedSink.sets, independentSink.sets);
      MX_EXPECT_EQ(sharedSink.sets, oneSink.sets);
      MX_EXPECT_EQ(sharedSink.clears, independentSink.clears);
      MX_EXPECT_EQ(sharedSink.intensity, independentSink.intensity);
      for (const auto& [index, glyph] : sharedSink.targets) {
        if (index % 80 < 40) {
          MX_EXPECT(sharedSink.targets.contains(index + 40));
          MX_EXPECT_EQ(sharedSink.targets.at(index + 40), glyph);
        }
      }
      sawDifference |= sharedSink.targets != independentSink.targets;
    }
    MX_EXPECT(sawDifference);
  }

  {
    const std::array<MessageRegion, 2> regions{{{0, 0, 40, 30}, {40, 0, 40, 30}}};
    auto single = Document();
    single.singleMonitor = true;
    single.horizontalPosition = 1.0;
    single.position = 1.0;
    single.jitter = 0.0;
    auto independent = single;
    independent.singleMonitor = false;
    independent.independentMonitorPositions = true;
    auto shared = independent;
    shared.independentMonitorPositions = false;
    MessageScheduler singleScheduler(123u), fullScheduler(123u), sharedScheduler(123u), independentScheduler(123u);
    singleScheduler.Configure(single);
    fullScheduler.Configure(single);
    sharedScheduler.Configure(shared);
    independentScheduler.Configure(independent);
    FakeMessageSink singleSink(80, 30), fullSink(80, 30), sharedSink(80, 30), independentSink(80, 30);
    for (int now = 0; now <= 10000; now += 100) {
      singleScheduler.Update(now, singleSink, regions);
      fullScheduler.Update(now, fullSink);
      sharedScheduler.Update(now, sharedSink, regions);
      independentScheduler.Update(now, independentSink, regions);
      MX_EXPECT_EQ(singleSink.targets, fullSink.targets);
      MX_EXPECT_EQ(sharedSink.targets, independentSink.targets);
    }
  }

  {
    // Shared cross-platform fixture for independent region hashing.
    const std::array<MessageRegion, 2> regions{{{0, 0, 40, 40}, {40, 0, 40, 40}}};
    auto document = Document();
    document.messages = {"A"};
    document.jitter = 1.0;
    document.horizontalJitter = 1.0;
    document.independentMonitorPositions = true;
    MessageScheduler scheduler(42u);
    FakeMessageSink sink(80, 40);
    scheduler.PreviewOne(0.0, sink, document, regions);
    MX_EXPECT_EQ(sink.targets.size(), std::size_t{2});
    MX_EXPECT(sink.targets.contains(1287));
    MX_EXPECT(sink.targets.contains(2792));
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
    document.horizontalPosition = 0.68;
    document.horizontalJitter = 0.4;
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
    MX_EXPECT_EQ(hash, 1085214760u);
    MX_EXPECT_EQ(sink.sets, 8u);
    MX_EXPECT_EQ(sink.updates, 3u);
    MX_EXPECT_EQ(sink.clears, 6u);
    const std::map<std::size_t, std::uint8_t> expectedTargets{
      {std::size_t{794}, std::uint8_t{121}}, {std::size_t{795}, std::uint8_t{99}},
      {std::size_t{796}, std::uint8_t{109}}, {std::size_t{797}, std::uint8_t{103}},
      {std::size_t{799}, std::uint8_t{157}}, {std::size_t{820}, std::uint8_t{121}},
      {std::size_t{821}, std::uint8_t{99}}, {std::size_t{822}, std::uint8_t{109}},
      {std::size_t{823}, std::uint8_t{103}}, {std::size_t{825}, std::uint8_t{157}},
    };
    MX_EXPECT_EQ(sink.targets, expectedTargets);
  }

  {
    std::string dynamic = "AB";
    FakeMessageSink sink(20, 10);
    MessageScheduler scheduler(13u, [&dynamic](std::string_view) { return dynamic; });
    auto document = Document();
    document.messages = {"{dynamic}"};
    document.position = 0.5;
    document.jitter = 0.0;
    document.horizontalPosition = 0.5;
    document.horizontalJitter = 1.0;
    scheduler.PreviewOne(0.0, sink, document);
    const auto originalTargets = sink.targets;
    dynamic = "ABCD";
    scheduler.Update(100.0, sink);
    MX_EXPECT(!sink.targets.empty());
    MX_EXPECT(TargetBounds(sink).lastColumn < sink.Columns());
    dynamic = "AB";
    scheduler.Update(200.0, sink);
    MX_EXPECT_EQ(sink.targets, originalTargets);
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
