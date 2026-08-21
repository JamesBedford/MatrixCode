#include "matrixcode/core/GlyphSet.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace matrixcode {
namespace {

void AppendCodePoints(std::vector<std::wstring>& output, wchar_t first, wchar_t last) {
  for (wchar_t value = first; value <= last; ++value) output.emplace_back(1, value);
}

void AppendAscii(std::vector<std::wstring>& output, std::string_view values) {
  for (const char value : values) output.emplace_back(1, static_cast<wchar_t>(value));
}

}  // namespace

GlyphSet::GlyphSet(const GlyphMode mode) : mode_(mode) {
  katakana_ = {glyphs_.size(), 56};
  AppendCodePoints(glyphs_, 0xff66, 0xff9d);

  digits_ = {glyphs_.size(), 10};
  AppendAscii(glyphs_, "0123456789");

  latin_ = {glyphs_.size(), 26};
  AppendAscii(glyphs_, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");

  symbols_ = {glyphs_.size(), 7};
  AppendAscii(glyphs_, "=+-*<>:");

  message_ = {glyphs_.size(), 74};
  AppendAscii(glyphs_, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
  AppendAscii(glyphs_, "abcdefghijklmnopqrstuvwxyz");
  AppendAscii(glyphs_, "0123456789");
  AppendAscii(glyphs_, "=+-*<>:");
  AppendAscii(glyphs_, ".,!?'" );

  if (glyphs_.size() > kMaxGlyphs) glyphs_.resize(kMaxGlyphs);
}

std::uint8_t GlyphSet::RandomGlyphIndex(Mulberry32& rng) const noexcept {
  const auto pick = [&rng](const GlyphRange range) {
    return static_cast<std::uint8_t>(range.start +
      static_cast<std::size_t>(std::floor(rng.Next() * static_cast<double>(range.count))));
  };

  switch (mode_) {
    case GlyphMode::Binary:
      return static_cast<std::uint8_t>(digits_.start + static_cast<std::size_t>(std::floor(rng.Next() * 2.0)));
    case GlyphMode::Katakana: return pick(katakana_);
    case GlyphMode::Digits: return pick(digits_);
    case GlyphMode::Latin: return pick(latin_);
    case GlyphMode::Symbols: return pick(symbols_);
    case GlyphMode::Matrix: break;
  }

  constexpr std::array<double, 4> weights{0.8, 0.11, 0.05, 0.04};
  constexpr double total = 1.0;
  double remaining = rng.Next() * total;
  std::size_t group = weights.size() - 1;
  for (std::size_t index = 0; index < weights.size(); ++index) {
    remaining -= weights[index];
    if (remaining < 0.0) {
      group = index;
      break;
    }
  }
  const std::array<GlyphRange, 4> ranges{katakana_, digits_, latin_, symbols_};
  return pick(ranges[group]);
}

std::optional<std::uint8_t> GlyphSet::MessageGlyph(const char character) const noexcept {
  constexpr std::string_view chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=+-*<>:.,!?'";
  const auto position = chars.find(character);
  if (position == std::string_view::npos) return std::nullopt;
  return static_cast<std::uint8_t>(message_.start + position);
}

}  // namespace matrixcode
