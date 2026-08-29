#include "matrixcode/platform/Win32Utf.h"

#include <limits>
#include <windows.h>

namespace matrixcode::platform {
namespace {

template <typename Character>
[[nodiscard]] bool FitsWin32Length(const std::basic_string_view<Character> value) noexcept {
  return value.size() <= static_cast<std::size_t>(std::numeric_limits<int>::max());
}

}  // namespace

std::wstring WideFromUtf8(const std::string_view utf8) {
  if (utf8.empty() || !FitsWin32Length(utf8)) return {};
  const int inputLength = static_cast<int>(utf8.size());
  const int outputLength = MultiByteToWideChar(
    CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), inputLength, nullptr, 0);
  if (outputLength <= 0) return {};
  std::wstring output(static_cast<std::size_t>(outputLength), L'\0');
  return MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), inputLength,
      output.data(), outputLength) == outputLength
    ? output
    : std::wstring{};
}

std::string Utf8FromWide(const std::wstring_view wide) {
  if (wide.empty() || !FitsWin32Length(wide)) return {};
  const int inputLength = static_cast<int>(wide.size());
  const int outputLength = WideCharToMultiByte(
    CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), inputLength, nullptr, 0, nullptr, nullptr);
  if (outputLength <= 0) return {};
  std::string output(static_cast<std::size_t>(outputLength), '\0');
  return WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), inputLength,
      output.data(), outputLength, nullptr, nullptr) == outputLength
    ? output
    : std::string{};
}

}  // namespace matrixcode::platform
