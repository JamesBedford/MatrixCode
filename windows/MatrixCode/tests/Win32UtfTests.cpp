#include <string>

#include "TestHarness.h"
#include "matrixcode/platform/Win32Utf.h"

void RunWin32UtfTests() {
  using namespace matrixcode::platform;

  const std::string utf8 = "Neo \xE6\x97\xA5\xE6\x9C\xAC \xF0\x9F\x98\x80";
  const std::wstring wide = L"Neo \u65E5\u672C \xD83D\xDE00";
  MX_EXPECT_EQ(WideFromUtf8(utf8), wide);
  MX_EXPECT_EQ(Utf8FromWide(wide), utf8);
  MX_EXPECT(WideFromUtf8(std::string("\xC0\xAF", 2)).empty());
  MX_EXPECT(Utf8FromWide(std::wstring(1, static_cast<wchar_t>(0xd800))).empty());
}
