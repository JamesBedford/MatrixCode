#include <string>

#include "TestHarness.h"
#include "matrixcode/core/Utf8.h"

void RunUtf8Tests() {
  using matrixcode::TruncateUtf8;
  using matrixcode::TrimUtf8;
  using matrixcode::Utf16LengthOfUtf8;
  MX_EXPECT_EQ(TruncateUtf8("abcdef", 4), std::string("abcd"));
  MX_EXPECT_EQ(TruncateUtf8("A\xC3\xA9" "B", 2), std::string("A\xC3\xA9"));
  MX_EXPECT_EQ(TruncateUtf8("A\xF0\x9F\x98\x80" "B", 2), std::string("A"));
  MX_EXPECT_EQ(TruncateUtf8("A\xF0\x9F\x98\x80" "B", 3),
    std::string("A\xF0\x9F\x98\x80"));
  MX_EXPECT_EQ(TruncateUtf8("A\xE2", 8), std::string("A"));
  MX_EXPECT_EQ(Utf16LengthOfUtf8("A\xF0\x9F\x98\x80" "B"), static_cast<std::size_t>(4));
  MX_EXPECT_EQ(TrimUtf8(" \tMatrix\r\n"), std::string_view("Matrix"));
  MX_EXPECT_EQ(TrimUtf8("\xC2\xA0" "Neo" "\xEF\xBB\xBF"), std::string_view("Neo"));
  MX_EXPECT_EQ(TrimUtf8("\xE2\x80\xA8\xE3\x80\x80"), std::string_view{});
}
