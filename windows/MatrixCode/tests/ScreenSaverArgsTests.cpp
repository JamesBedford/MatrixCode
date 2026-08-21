#include <array>
#include <string>

#include "TestHarness.h"
#include "matrixcode/platform/ScreenSaverArgs.h"

void RunScreenSaverArgsTests() {
  using namespace matrixcode::platform;
  const std::array<std::wstring, 1> run{L"/S"};
  MX_EXPECT_EQ(ParseScreenSaverArguments(run).mode, ScreenSaverMode::Run);
  const std::array<std::wstring, 1> configure{L"-c:42"};
  const auto configured = ParseScreenSaverArguments(configure);
  MX_EXPECT_EQ(configured.mode, ScreenSaverMode::Configure);
  MX_EXPECT_EQ(configured.ownerWindow, static_cast<std::uintptr_t>(42));
  const std::array<std::wstring, 2> preview{L"/p", L"0x1234"};
  const auto previewed = ParseScreenSaverArguments(preview);
  MX_EXPECT(previewed.valid);
  MX_EXPECT_EQ(previewed.mode, ScreenSaverMode::Preview);
  MX_EXPECT_EQ(previewed.ownerWindow, static_cast<std::uintptr_t>(0x1234));
  const std::array<std::wstring, 1> invalidPreview{L"/p"};
  MX_EXPECT(!ParseScreenSaverArguments(invalidPreview).valid);
  const std::array<std::wstring, 1> unknown{L"/what"};
  MX_EXPECT(!ParseScreenSaverArguments(unknown).valid);
  MX_EXPECT_EQ(ParseScreenSaverArguments(std::span<const std::wstring>{}).mode, ScreenSaverMode::Configure);
}
