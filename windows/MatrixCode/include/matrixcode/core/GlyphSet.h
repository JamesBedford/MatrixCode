#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "matrixcode/core/Rng.h"
#include "matrixcode/core/Types.h"

namespace matrixcode {

struct GlyphRange {
  std::size_t start = 0;
  std::size_t count = 0;
};

class GlyphSet final {
 public:
  explicit GlyphSet(GlyphMode mode = GlyphMode::Matrix);

  [[nodiscard]] std::size_t Count() const noexcept { return glyphs_.size(); }
  [[nodiscard]] const std::vector<std::wstring>& Glyphs() const noexcept { return glyphs_; }
  [[nodiscard]] const GlyphRange& Katakana() const noexcept { return katakana_; }
  [[nodiscard]] const GlyphRange& Digits() const noexcept { return digits_; }
  [[nodiscard]] const GlyphRange& Latin() const noexcept { return latin_; }
  [[nodiscard]] const GlyphRange& Symbols() const noexcept { return symbols_; }
  [[nodiscard]] const GlyphRange& Message() const noexcept { return message_; }
  [[nodiscard]] GlyphMode Mode() const noexcept { return mode_; }
  void SetMode(GlyphMode mode) noexcept { mode_ = mode; }

  [[nodiscard]] std::uint8_t RandomGlyphIndex(Mulberry32& rng) const noexcept;
  [[nodiscard]] std::optional<std::uint8_t> MessageGlyph(char character) const noexcept;

 private:
  std::vector<std::wstring> glyphs_;
  GlyphRange katakana_;
  GlyphRange digits_;
  GlyphRange latin_;
  GlyphRange symbols_;
  GlyphRange message_;
  GlyphMode mode_;
};

}  // namespace matrixcode
