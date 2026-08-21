#include <cmath>

#include "TestHarness.h"
#include "matrixcode/core/ImageReveal.h"

void RunImageRevealTests() {
  using namespace matrixcode;
  ImageMask mask{"asymmetric", 2, 2, {0, 64, 128, 255}};
  MX_EXPECT(std::abs(SampleImageMask(mask, 0.0, 0.0) - 0.0) < 1e-12);
  MX_EXPECT(std::abs(SampleImageMask(mask, 1.0, 1.0) - 1.0) < 1e-12);
  const double center = SampleImageMask(mask, 0.5, 0.5);
  MX_EXPECT(center > 0.43 && center < 0.44);
  MX_EXPECT_EQ(ImageSignal(0.0), 0.0);
  MX_EXPECT(ImageSignal(1.0) > 0.7);
  MX_EXPECT_EQ(ImageEdgeFeather(0.0, 0.5, 0.1, 0.1), 0.0);
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

  const auto cell = ApplyImageReveal(
    0.8, 1, GlyphMode::Latin, 1.0, 1.0, 1.0, 1.0, 0.0, 99u, 2u);
  MX_EXPECT(cell.influence > 0.0);
  MX_EXPECT(cell.brightness >= 0.8);

  constexpr std::uint32_t exactIdentity = 44u;
  constexpr std::uint32_t exactBucket = 7u;
  const auto matrixDark = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.15, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandTwo = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.16, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandThree = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.32, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBandFour = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 0.48, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  const auto matrixBright = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(matrixDark.glyph, static_cast<std::uint8_t>(93));
  MX_EXPECT_EQ(matrixBandTwo.glyph, static_cast<std::uint8_t>(57));
  MX_EXPECT_EQ(matrixBandThree.glyph, static_cast<std::uint8_t>(74));
  MX_EXPECT_EQ(matrixBandFour.glyph, static_cast<std::uint8_t>(78));
  MX_EXPECT_EQ(matrixBright.glyph, static_cast<std::uint8_t>(46));
  const auto katakanaBright = ApplyImageReveal(
    1.0, 1, GlyphMode::Katakana, 1.0, 1.0, 1.0, 1.0, 0.0,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(katakanaBright.glyph, static_cast<std::uint8_t>(46));
  const auto scrambled = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 1.0, 0.5,
    exactIdentity, exactBucket);
  MX_EXPECT_EQ(scrambled.glyph, static_cast<std::uint8_t>(19));
  const auto dissolved = ApplyImageReveal(
    1.0, 1, GlyphMode::Matrix, 1.0, 1.0, 1.0, 1.0, 0.8,
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
