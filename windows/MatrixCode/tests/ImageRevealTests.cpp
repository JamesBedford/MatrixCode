#include <array>
#include <cmath>
#include <limits>
#include <vector>

#include "TestHarness.h"
#include "matrixcode/core/ImageReveal.h"
#include "matrixcode/core/Rng.h"

namespace {

bool Near(const double actual, const double expected, const double tolerance = 1e-12) {
  return std::abs(actual - expected) < tolerance;
}

}  // namespace

void RunImageRevealTests() {
  using namespace matrixcode;
  ImageMask mask{"asymmetric", 2, 2, {0, 64, 128, 255}};
  MX_EXPECT(std::abs(SampleImageMask(mask, 0.0, 0.0) - 0.0) < 1e-12);
  MX_EXPECT(std::abs(SampleImageMask(mask, 1.0, 1.0) - 1.0) < 1e-12);
  const double center = SampleImageMask(mask, 0.5, 0.5);
  MX_EXPECT(center > 0.43 && center < 0.44);
  struct SampleCase {
    double u;
    double v;
    double expected;
  };
  const std::array<SampleCase, 8> extendedSamples{{
    {-2.0, 0.25, 32.0 / 255.0},
    {3.0, 0.75, 207.25 / 255.0},
    {0.25, -2.0, 16.0 / 255.0},
    {0.75, 3.0, 223.25 / 255.0},
    {-2.0, -2.0, 0.0},
    {3.0, -2.0, 64.0 / 255.0},
    {-2.0, 3.0, 128.0 / 255.0},
    {3.0, 3.0, 1.0},
  }};
  for (const auto& sample : extendedSamples) {
    MX_EXPECT(Near(SampleImageMask(mask, sample.u, sample.v), sample.expected));
  }
  ImageMask singlePixel{"one pixel", 1, 1, {42}};
  MX_EXPECT(Near(SampleImageMask(singlePixel,
    std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max()), 42.0 / 255.0));
  MX_EXPECT_EQ(SampleImageMask(mask, std::numeric_limits<double>::quiet_NaN(), 0.5), 0.0);
  MX_EXPECT_EQ(SampleImageMask(mask, 0.5, std::numeric_limits<double>::infinity()), 0.0);
  MX_EXPECT_EQ(SampleImageMask(ImageMask{}, 0.5, 0.5), 0.0);
  ImageMask malformed{"malformed", 2, 2, {255}};
  MX_EXPECT_EQ(SampleImageMask(malformed, 0.5, 0.5), 0.0);

  MX_EXPECT_EQ(ImageSignal(0.0), 1.0);
  MX_EXPECT(Near(ImageSignal(0.08), 0.84));
  MX_EXPECT(Near(ImageSignal(0.5), 0.36));
  MX_EXPECT_EQ(ImageSignal(1.0), 1.0);
  MX_EXPECT_EQ(ImageSignal(-1.0), 1.0);
  MX_EXPECT_EQ(ImageSignal(2.0), 1.0);
  MX_EXPECT(ImageFallingGate(5, 8, 2.0, 123u) >= 0.0);
  MX_EXPECT(ImageFallingGate(5, 8, 2.0, 123u) <= 1.0);

  ImagesDocument document;
  document.enabled = true;
  document.images.push_back(mask);
  ImageScheduler first;
  ImageScheduler second;
  first.Configure(document, 123u, 1000.0, 1000.0, true);
  second.Configure(document, 123u, 1000.0, 1000.0, true);
  MX_EXPECT_EQ(first.NextFireSeconds(), second.NextFireSeconds());
  MX_EXPECT(!first.Update(first.NextFireSeconds() - 0.001).has_value());
  const auto active = first.Update(first.NextFireSeconds());
  MX_EXPECT(active.has_value());
  MX_EXPECT_EQ(active->imageIndex, static_cast<std::size_t>(0));
  const auto placement = ComputeImagePlacement(mask, document, *active, 100, 50);
  MX_EXPECT(placement.columns > 0.0 && placement.rows > 0.0);
  ImageMask wide{"wide", 4, 2, std::vector<std::uint8_t>(8, 255)};
  ImagesDocument centered;
  centered.imageScale = 0.4;
  centered.placementJitter = 0.0;
  const auto centeredPlacement = ComputeImagePlacement(wide, centered, ActiveImageState{}, 100, 50);
  MX_EXPECT_EQ(centeredPlacement.columns, 40.0);
  MX_EXPECT_EQ(centeredPlacement.rows, 20.0);
  MX_EXPECT_EQ(centeredPlacement.originColumn, 30.0);
  MX_EXPECT_EQ(centeredPlacement.originRow, 15.0);

  const auto cell = ApplyImageReveal(
    0.8, 1, GlyphMode::Latin, 1.0, 1.0, 1.0, 0.0, 99u, 2u);
  MX_EXPECT(cell.influence > 0.0);
  MX_EXPECT(cell.brightness >= 0.8);

  constexpr std::uint32_t exactIdentity = 44u;
  constexpr std::uint32_t exactBucket = 7u;
  const auto black = ApplyImageReveal(
    0.8, 1, GlyphMode::Matrix, 0.0, 1.0, 1.0, 0.0, exactIdentity, exactBucket);
  MX_EXPECT_EQ(black.influence, 1.0);
  MX_EXPECT(Near(black.brightness, 0.432));
  MX_EXPECT_EQ(black.glyph, static_cast<std::uint8_t>(93));

  for (const auto& sample : extendedSamples) {
    const auto outside = ApplyImageReveal(
      0.8, 1, GlyphMode::Matrix, SampleImageMask(mask, sample.u, sample.v),
      0.6, 0.7, 0.0, exactIdentity, exactBucket);
    const auto edge = ApplyImageReveal(
      0.8, 1, GlyphMode::Matrix, sample.expected,
      0.6, 0.7, 0.0, exactIdentity, exactBucket);
    MX_EXPECT(outside.influence > 0.0);
    MX_EXPECT(Near(outside.influence, edge.influence));
    MX_EXPECT(Near(outside.brightness, edge.brightness));
    MX_EXPECT_EQ(outside.glyph, edge.glyph);
  }
  constexpr double epsilon = 1e-6;
  const std::array<std::array<double, 4>, 4> borderPairs{{
    {-epsilon, 0.25, epsilon, 0.25},
    {1.0 + epsilon, 0.75, 1.0 - epsilon, 0.75},
    {0.25, -epsilon, 0.25, epsilon},
    {0.75, 1.0 + epsilon, 0.75, 1.0 - epsilon},
  }};
  for (const auto& pair : borderPairs) {
    const auto outside = ApplyImageReveal(
      0.8, 1, GlyphMode::Matrix, SampleImageMask(mask, pair[0], pair[1]),
      0.6, 0.7, 0.0, exactIdentity, exactBucket);
    const auto inside = ApplyImageReveal(
      0.8, 1, GlyphMode::Matrix, SampleImageMask(mask, pair[2], pair[3]),
      0.6, 0.7, 0.0, exactIdentity, exactBucket);
    MX_EXPECT(outside.influence > 0.0);
    MX_EXPECT(Near(outside.influence, inside.influence, 1e-5));
    MX_EXPECT(Near(outside.brightness, inside.brightness, 1e-5));
  }
  const auto identity = Hash32(0x1a2b3cu ^ 12u * 73856093u ^ 8u * 19349663u);
  MX_EXPECT_EQ(identity, 1316630523u);
  MX_EXPECT(Near(ImageFallingGate(12, 8, 2.5, 0x1a2b3cu), 0.0509755093, 1e-10));

  const auto matrixDark = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.15, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandTwo = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.16, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandThree = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.32, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandFour = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.48, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBright = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(matrixDark.glyph, static_cast<std::uint8_t>(93));
  MX_EXPECT_EQ(matrixBandTwo.glyph, static_cast<std::uint8_t>(57));
  MX_EXPECT_EQ(matrixBandThree.glyph, static_cast<std::uint8_t>(74));
  MX_EXPECT_EQ(matrixBandFour.glyph, static_cast<std::uint8_t>(78));
  MX_EXPECT_EQ(matrixBright.glyph, static_cast<std::uint8_t>(46));
  const auto katakanaBright = ApplyImageReveal(
    1.0, 1, GlyphMode::Katakana, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(katakanaBright.glyph, static_cast<std::uint8_t>(46));
  const auto scrambled = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 0.5,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(scrambled.glyph, static_cast<std::uint8_t>(19));
  const auto dissolved = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 0.8,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(dissolved.influence, 0.0);
  MX_EXPECT_EQ(dissolved.glyph, static_cast<std::uint8_t>(1));

  ImageScheduler lateFirst;
  ImageScheduler lateSecond;
  lateFirst.Configure(document, 987u, 1000.0, 1000.0, true);
  lateSecond.Configure(document, 987u, 1000.0, 3600.0, true);
  const auto atLateTime = lateFirst.Update(3600.0);
  const auto joinedLate = lateSecond.Update(3600.0);
  MX_EXPECT_EQ(atLateTime.has_value(), joinedLate.has_value());
  MX_EXPECT_EQ(lateFirst.NextFireSeconds(), lateSecond.NextFireSeconds());
  if (atLateTime.has_value() && joinedLate.has_value()) {
    MX_EXPECT_EQ(atLateTime->imageIndex, joinedLate->imageIndex);
    MX_EXPECT_EQ(atLateTime->startSeconds, joinedLate->startSeconds);
    MX_EXPECT(atLateTime->endSeconds > 3600.0);
  } else {
    MX_EXPECT(lateFirst.NextFireSeconds() > 3600.0);
  }

  ImageScheduler hostileFirst;
  ImageScheduler hostileSecond;
  hostileFirst.Configure(document, 456u, 1000.0, 1000.0, true);
  hostileSecond.Configure(document, 456u, 1000.0, 1000.0, true);
  constexpr double hostileNow = 1.0e9;
  const auto hostileActiveFirst = hostileFirst.Update(hostileNow);
  const auto hostileActiveSecond = hostileSecond.Update(hostileNow);
  MX_EXPECT_EQ(hostileActiveFirst.has_value(), hostileActiveSecond.has_value());
  MX_EXPECT_EQ(hostileFirst.NextFireSeconds(), hostileSecond.NextFireSeconds());
  MX_EXPECT(hostileFirst.NextFireSeconds() > hostileNow);
}
