#include "matrixcode/platform/ScreenSaverArgs.h"

#include <algorithm>
#include <cerrno>
#include <cwchar>
#include <cwctype>

namespace matrixcode::platform {
namespace {

[[nodiscard]] std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](const wchar_t character) {
    return static_cast<wchar_t>(std::towlower(character));
  });
  return value;
}

[[nodiscard]] bool ParseHandle(const std::wstring& text, std::uintptr_t& output) noexcept {
  if (text.empty()) return false;
  wchar_t* end = nullptr;
  errno = 0;
  const auto value = std::wctoull(text.c_str(), &end, 0);
  if (errno != 0 || end == text.c_str() || *end != L'\0') return false;
  output = static_cast<std::uintptr_t>(value);
  return output != 0;
}

}  // namespace

ScreenSaverArguments ParseScreenSaverArguments(
    const std::span<const std::wstring> arguments) noexcept {
  if (arguments.empty()) return {};
  std::wstring option = Lower(arguments.front());
  if (!option.empty() && (option.front() == L'/' || option.front() == L'-')) {
    option.erase(option.begin());
  }
  std::wstring attached;
  if (const auto separator = option.find(L':'); separator != std::wstring::npos) {
    attached = option.substr(separator + 1);
    option.resize(separator);
  }
  if (option == L"s") return {ScreenSaverMode::Run, 0, true};
  if (option == L"c" || option == L"a") {
    std::uintptr_t owner = 0;
    const std::wstring* value = !attached.empty()
      ? &attached
      : arguments.size() > 1 ? &arguments[1] : nullptr;
    if (value != nullptr && !ParseHandle(*value, owner)) owner = 0;
    return {ScreenSaverMode::Configure, owner, true};
  }
  if (option == L"p") {
    std::uintptr_t owner = 0;
    const std::wstring* value = !attached.empty()
      ? &attached
      : arguments.size() > 1 ? &arguments[1] : nullptr;
    return value != nullptr && ParseHandle(*value, owner)
      ? ScreenSaverArguments{ScreenSaverMode::Preview, owner, true}
      : ScreenSaverArguments{ScreenSaverMode::Preview, 0, false};
  }
  return {ScreenSaverMode::Configure, 0, false};
}

}  // namespace matrixcode::platform
