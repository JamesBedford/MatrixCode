#include <cstdint>
#include <utility>
#include <vector>

#include "TestHarness.h"
#include "matrixcode/core/RainSimulation.h"

namespace {

std::uint32_t Checksum(const std::span<const std::uint8_t> bytes) {
  std::uint32_t hash = 0x811c9dc5u;
  for (const auto byte : bytes) {
    hash ^= byte;
    hash *= 0x01000193u;
  }
  return hash;
}

matrixcode::Controls GoldenControls() {
  matrixcode::Controls controls;
  controls.speed = 1.0;
  controls.trailLength = 0.08;
  controls.trailVariation = 1.0;
  controls.density = 6.0;
  controls.rampUpMilliseconds = 0.0;
  controls.glyphRate = 1.0;
  controls.glyphScale = 1.0;
  controls.glow = 1.0;
  controls.leadBrightness = 1.6;
  return controls;
}

}  // namespace

void RunRainSimulationTests() {
  using namespace matrixcode;
  auto controls = GoldenControls();
  RainSimulation pure(40, 60, 0x00c0ffeeu);
  pure.WarmUp(controls, 3.0);
  for (int index = 0; index < 300; ++index) pure.Update(1.0 / 60.0, controls);
  MX_EXPECT_EQ(Checksum(pure.State()), 437809828u);

  RainSimulation message(24, 40, 12345u);
  message.WarmUp(controls, 2.0);
  std::vector<std::pair<std::size_t, std::uint8_t>> targets;
  for (std::uint8_t index = 0; index < 5; ++index) {
    targets.emplace_back(20 * 24 + 3 + index, static_cast<std::uint8_t>(99 + index));
  }
  message.SetMessageTargets(targets);
  for (int index = 0; index < 250; ++index) {
    message.SetMessageIntensity(0.6);
    message.SetMessageScramble(0.3);
    message.Update(1.0 / 60.0, controls);
  }
  MX_EXPECT_EQ(Checksum(message.State()), 3260864663u);

  RainSimulation distributed(24, 90, 13579u);
  distributed.WarmUpDistributed(controls, 2.5);
  MX_EXPECT_EQ(Checksum(distributed.State()), 3658144001u);

  RainSimulation resized(12, 24, 24680u);
  resized.WarmUp(controls, 2.0);
  const double timeBeforeResize = resized.Time();
  std::vector<std::size_t> streamsBeforeResize;
  for (std::size_t column = 0; column < resized.Columns(); ++column) {
    streamsBeforeResize.push_back(resized.ActiveStreamCount(column));
  }
  resized.Resize(18, 32);
  MX_EXPECT_EQ(resized.Time(), timeBeforeResize);
  for (std::size_t column = 0; column < streamsBeforeResize.size(); ++column) {
    MX_EXPECT_EQ(resized.ActiveStreamCount(column), streamsBeforeResize[column]);
  }
  resized.Update(1.0 / 60.0, controls);
  MX_EXPECT_EQ(resized.State().size(), static_cast<std::size_t>(18 * 32 * 4));

  controls.trailVariation = 0.35;
  RainSimulation varied(40, 60, 0x00c0ffeeu);
  varied.WarmUp(controls, 3.0);
  for (int index = 0; index < 300; ++index) varied.Update(1.0 / 60.0, controls);
  MX_EXPECT_EQ(Checksum(varied.State()), 1771342251u);

  RainSimulation variedDistributed(24, 90, 13579u);
  variedDistributed.WarmUpDistributed(controls, 2.5);
  MX_EXPECT_EQ(Checksum(variedDistributed.State()), 3061054872u);

  const auto packed = PackCell(12, 0.5, true, false, 1.0, 7);
  MX_EXPECT_EQ(packed.newGlyph, static_cast<std::uint8_t>(12));
  MX_EXPECT_EQ(packed.brightness, static_cast<std::uint8_t>(128));
  MX_EXPECT((packed.flagsAndPhase & kFlagIsHead) != 0);
  MX_EXPECT_EQ(packed.oldGlyph, static_cast<std::uint8_t>(7));
}
