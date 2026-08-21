#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace matrixcode {

struct Utf8CodePoint {
  std::uint32_t value = 0xfffdu;
  std::size_t bytes = 1;
  bool valid = false;
};

[[nodiscard]] Utf8CodePoint DecodeUtf8CodePoint(
  std::string_view value,
  std::size_t offset) noexcept;
[[nodiscard]] std::size_t Utf16LengthOfUtf8(std::string_view value) noexcept;

/** Trim the same Unicode WhiteSpace and LineTerminator code points as ECMAScript String.trim(). */
[[nodiscard]] std::string_view TrimUtf8(std::string_view value) noexcept;

/**
 * Truncate valid UTF-8 without splitting a code point. The limit is counted in UTF-16 code units,
 * matching JavaScript string limits while refusing to manufacture an unpaired surrogate.
 */
[[nodiscard]] std::string TruncateUtf8(
  std::string_view value,
  std::size_t maximumUtf16CodeUnits);

}  // namespace matrixcode
