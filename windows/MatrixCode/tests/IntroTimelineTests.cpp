#include <cmath>
#include <vector>

#include "TestHarness.h"
#include "matrixcode/core/IntroTimeline.h"

void RunIntroTimelineTests() {
  using namespace matrixcode;
  const std::vector<IntroLine> lines{{"AB", 500.0, 300.0}, {"CDE", 500.0, 0.0}};
  MX_EXPECT_EQ(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 100.0).visibleText, std::string());
  MX_EXPECT_EQ(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 300.0).visibleText, std::string("A"));
  MX_EXPECT_EQ(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 400.0).visibleText, std::string("AB"));
  MX_EXPECT_EQ(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 950.0).visibleText, std::string());
  MX_EXPECT_EQ(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 1300.0).visibleText, std::string("C"));
  const auto fading = ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 2200.0);
  MX_EXPECT(!fading.done);
  MX_EXPECT(std::abs(fading.opacity - 0.5) < 1e-12);
  MX_EXPECT(ComputeIntroTimeline(lines, 100.0, 200.0, 400.0, 2400.0).done);
  MX_EXPECT(IntroCursorVisible(0.0));
  MX_EXPECT(!IntroCursorVisible(450.0));
  IntroDocument document;
  document.lines = lines;
  document.charMilliseconds = 100.0;
  document.startDelayMilliseconds = 200.0;
  document.fadeOutMilliseconds = 400.0;
  MX_EXPECT_EQ(IntroTotalDurationMilliseconds(document), 2400.0);
  const std::vector<IntroLine> unicode{{"A\xF0\x9F\x98\x80" "B", 0.0, 0.0}};
  MX_EXPECT_EQ(ComputeIntroTimeline(unicode, 100.0, 0.0, 0.0, 350.0).visibleText,
    std::string("A\xF0\x9F\x98\x80"));
  MX_EXPECT_EQ(RainStartAfterIntro(2.0, 10.0, false, 1500.0), 11.5);
  MX_EXPECT_EQ(RainStartAfterIntro(2.0, 10.0, true, 1500.0), 2.0);
}
