#pragma once

#include <string>
#include <string_view>

namespace matrixcode::platform {

[[nodiscard]] std::wstring WideFromUtf8(std::string_view utf8);
[[nodiscard]] std::string Utf8FromWide(std::wstring_view wide);

}  // namespace matrixcode::platform
