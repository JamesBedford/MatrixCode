#include "matrixcode/core/Utf8.h"

namespace matrixcode {
namespace {

[[nodiscard]] bool IsEcmaScriptWhitespace(const std::uint32_t value) noexcept {
  return value == 0x0009u || value == 0x000au || value == 0x000bu || value == 0x000cu ||
    value == 0x000du || value == 0x0020u || value == 0x00a0u || value == 0x1680u ||
    (value >= 0x2000u && value <= 0x200au) || value == 0x2028u || value == 0x2029u ||
    value == 0x202fu || value == 0x205fu || value == 0x3000u || value == 0xfeffu;
}

}  // namespace

Utf8CodePoint DecodeUtf8CodePoint(
    const std::string_view value,
    const std::size_t offset) noexcept {
  if (offset >= value.size()) return {};
  const auto first = static_cast<std::uint8_t>(value[offset]);
  if (first <= 0x7fu) return {first, 1, true};
  std::size_t length = 0;
  std::uint32_t codePoint = 0;
  std::uint32_t minimum = 0;
  if (first >= 0xc2u && first <= 0xdfu) {
    length = 2;
    codePoint = first & 0x1fu;
    minimum = 0x80u;
  } else if (first >= 0xe0u && first <= 0xefu) {
    length = 3;
    codePoint = first & 0x0fu;
    minimum = 0x800u;
  } else if (first >= 0xf0u && first <= 0xf4u) {
    length = 4;
    codePoint = first & 0x07u;
    minimum = 0x10000u;
  } else {
    return {};
  }
  if (offset + length > value.size()) return {};
  for (std::size_t index = 1; index < length; ++index) {
    const auto continuation = static_cast<std::uint8_t>(value[offset + index]);
    if ((continuation & 0xc0u) != 0x80u) return {};
    codePoint = (codePoint << 6u) | (continuation & 0x3fu);
  }
  if (codePoint < minimum || codePoint > 0x10ffffu ||
      (codePoint >= 0xd800u && codePoint <= 0xdfffu)) return {};
  return {codePoint, length, true};
}

std::size_t Utf16LengthOfUtf8(const std::string_view value) noexcept {
  std::size_t units = 0;
  for (std::size_t offset = 0; offset < value.size();) {
    const auto decoded = DecodeUtf8CodePoint(value, offset);
    if (!decoded.valid) {
      ++offset;
      ++units;
      continue;
    }
    units += decoded.value > 0xffffu ? 2u : 1u;
    offset += decoded.bytes;
  }
  return units;
}

std::string_view TrimUtf8(const std::string_view value) noexcept {
  std::size_t first = value.size();
  std::size_t last = 0;
  bool foundContent = false;
  for (std::size_t offset = 0; offset < value.size();) {
    const auto decoded = DecodeUtf8CodePoint(value, offset);
    const std::size_t bytes = decoded.valid ? decoded.bytes : 1u;
    const bool whitespace = decoded.valid && IsEcmaScriptWhitespace(decoded.value);
    if (!whitespace) {
      if (!foundContent) first = offset;
      foundContent = true;
      last = offset + bytes;
    }
    offset += bytes;
  }
  return foundContent ? value.substr(first, last - first) : std::string_view{};
}

std::string TruncateUtf8(
    const std::string_view value,
    const std::size_t maximumUtf16CodeUnits) {
  std::size_t offset = 0;
  std::size_t utf16Units = 0;
  while (offset < value.size()) {
    const auto decoded = DecodeUtf8CodePoint(value, offset);
    if (!decoded.valid) break;
    const std::size_t units = decoded.value > 0xffffu ? 2u : 1u;
    if (utf16Units + units > maximumUtf16CodeUnits) break;
    utf16Units += units;
    offset += decoded.bytes;
  }
  return std::string(value.substr(0, offset));
}

}  // namespace matrixcode
