#include "matrixcode/render/GlyphAtlas.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <wincodec.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include "matrixcode/core/GlyphSet.h"

namespace matrixcode::render {
namespace {

using Microsoft::WRL::ComPtr;

[[nodiscard]] const wchar_t* FontFamily(const Controls& controls) noexcept {
  if (controls.glyphMode == GlyphMode::Binary || controls.glyphMode == GlyphMode::Digits) {
    return L"Consolas";
  }
  switch (controls.glyphFont) {
    case GlyphFont::Gothic: return L"Yu Gothic";
    case GlyphFont::Mono: return L"Consolas";
    case GlyphFont::Terminal: return L"Courier New";
    case GlyphFont::Rounded: return L"Yu Gothic UI Semibold";
    case GlyphFont::Mincho: return L"Yu Mincho";
    case GlyphFont::Matrix: return L"Yu Gothic";
  }
  return L"Yu Gothic";
}

void DrawReadableDigit(
    ID2D1RenderTarget* target,
    ID2D1Brush* brush,
    const int digit,
    const float centerX,
    const float centerY,
    const float cell) {
  constexpr std::array<std::array<bool, 7>, 10> segments{{
    {{true, true, true, true, true, true, false}},
    {{false, true, true, false, false, false, false}},
    {{true, true, false, true, true, false, true}},
    {{true, true, true, true, false, false, true}},
    {{false, true, true, false, false, true, true}},
    {{true, false, true, true, false, true, true}},
    {{true, false, true, true, true, true, true}},
    {{true, true, true, false, false, false, false}},
    {{true, true, true, true, true, true, true}},
    {{true, true, true, true, false, true, true}},
  }};
  if (digit < 0 || digit > 9) return;
  const float margin = cell * 0.2f;
  const float thickness = std::max(3.0f, cell * 0.12f);
  const float half = cell * 0.5f;
  const float left = centerX - half + margin;
  const float right = centerX + half - margin;
  const float top = centerY - half + margin;
  const float bottom = centerY + half - margin;
  const float middle = centerY;
  const float capInset = thickness * 0.5f;
  const auto horizontal = [=](const float y) {
    target->FillRectangle(D2D1::RectF(
      left + capInset, y - thickness * 0.5f,
      right - capInset, y + thickness * 0.5f), brush);
  };
  const auto vertical = [=](const float x, const float y0, const float y1) {
    target->FillRectangle(D2D1::RectF(
      x - thickness * 0.5f, y0 + capInset,
      x + thickness * 0.5f, y1 - capInset), brush);
  };
  if (digit == 0) {
    const float radius = half - margin - thickness * 0.5f;
    target->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(centerX, centerY), radius, radius),
      brush, thickness);
    return;
  }
  if (digit == 1) {
    target->FillRectangle(D2D1::RectF(
      centerX - thickness * 0.5f, top, centerX + thickness * 0.5f, bottom), brush);
    target->FillRectangle(D2D1::RectF(
      centerX - thickness * 1.2f, top,
      centerX + thickness * 0.5f, top + thickness), brush);
    target->FillRectangle(D2D1::RectF(
      centerX - thickness * 1.4f, bottom - thickness,
      centerX + thickness * 1.4f, bottom), brush);
    return;
  }
  const auto& active = segments[static_cast<std::size_t>(digit)];
  if (active[0]) horizontal(top);
  if (active[1]) vertical(right, top, middle);
  if (active[2]) vertical(right, middle, bottom);
  if (active[3]) horizontal(bottom);
  if (active[4]) vertical(left, middle, bottom);
  if (active[5]) vertical(left, top, middle);
  if (active[6]) horizontal(middle);
}

}  // namespace

GlyphAtlasBitmap BuildGlyphAtlas(const Controls& controls) {
  constexpr std::uint32_t cell = 64;
  const GlyphSet glyphs(controls.glyphMode);
  const auto columns = static_cast<std::uint32_t>(std::ceil(
    std::sqrt(static_cast<double>(glyphs.Count()))));
  const auto rows = static_cast<std::uint32_t>((glyphs.Count() + columns - 1) / columns);
  GlyphAtlasBitmap result{
    columns * cell,
    rows * cell,
    columns,
    rows,
    cell,
    std::vector<std::uint8_t>(static_cast<std::size_t>(columns * cell) * rows * cell * 4, 0),
  };

  ComPtr<IWICImagingFactory> wic;
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  ComPtr<IWICBitmap> bitmap;
  ComPtr<ID2D1RenderTarget> target;
  ComPtr<ID2D1SolidColorBrush> brush;
  ComPtr<IDWriteTextFormat> format;
  if (FAILED(CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) ||
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf())) ||
      FAILED(DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()))) ||
      FAILED(wic->CreateBitmap(
        result.width, result.height, GUID_WICPixelFormat32bppPBGRA,
        WICBitmapCacheOnLoad, &bitmap))) {
    return {};
  }

  const auto properties = D2D1::RenderTargetProperties(
    D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
    96.0f,
    96.0f,
    D2D1_RENDER_TARGET_USAGE_NONE,
    D2D1_FEATURE_LEVEL_DEFAULT);
  if (FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target)) ||
      FAILED(target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &brush)) ||
      FAILED(dwrite->CreateTextFormat(
        FontFamily(controls), nullptr, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, 50.0f, L"en-us", &format))) {
    return {};
  }
  format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  target->BeginDraw();
  target->Clear(D2D1::ColorF(0, 0.0f));
  for (std::size_t index = 0; index < glyphs.Count(); ++index) {
    const auto column = static_cast<std::uint32_t>(index % columns);
    const auto row = static_cast<std::uint32_t>(index / columns);
    const auto rectangle = D2D1::RectF(
      static_cast<float>(column * cell), static_cast<float>(row * cell),
      static_cast<float>((column + 1) * cell), static_cast<float>((row + 1) * cell));
    D2D1_MATRIX_3X2_F saved{};
    target->GetTransform(&saved);
    if (controls.mirror && index < glyphs.Message().start) {
      const auto centerX = static_cast<float>(column * cell) + static_cast<float>(cell) * 0.5f;
      target->SetTransform(D2D1::Matrix3x2F::Translation(-centerX, 0.0f) *
        D2D1::Matrix3x2F::Scale(-1.0f, 1.0f) *
        D2D1::Matrix3x2F::Translation(centerX, 0.0f));
    }
    std::wstring glyph = glyphs.Glyphs()[index];
    const bool digitMode = controls.glyphMode == GlyphMode::Binary ||
      controls.glyphMode == GlyphMode::Digits;
    if (digitMode && index < glyphs.Message().start) {
      const auto offset = static_cast<long long>(index) -
        static_cast<long long>(glyphs.Digits().start);
      const int divisor = controls.glyphMode == GlyphMode::Binary ? 2 : 10;
      const int digit = static_cast<int>(((offset % divisor) + divisor) % divisor);
      glyph.assign(1, static_cast<wchar_t>(L'0' + digit));
      DrawReadableDigit(
        target.Get(), brush.Get(), digit,
        static_cast<float>(column * cell) + static_cast<float>(cell) * 0.5f,
        static_cast<float>(row * cell) + static_cast<float>(cell) * 0.5f,
        static_cast<float>(cell));
    } else {
      target->DrawTextW(
        glyph.c_str(), static_cast<UINT32>(glyph.size()), format.Get(), rectangle, brush.Get(),
        D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
    }
    target->SetTransform(saved);
  }
  if (FAILED(target->EndDraw())) return {};

  const WICRect rectangle{0, 0, static_cast<INT>(result.width), static_cast<INT>(result.height)};
  const UINT stride = result.width * 4;
  if (FAILED(bitmap->CopyPixels(
        &rectangle, stride, static_cast<UINT>(result.bgra.size()), result.bgra.data()))) {
    return {};
  }
  return result;
}

}  // namespace matrixcode::render
