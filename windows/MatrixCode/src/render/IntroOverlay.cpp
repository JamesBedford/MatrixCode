#include "matrixcode/render/IntroOverlay.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include <d2d1.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

namespace matrixcode::render {
namespace {

using Microsoft::WRL::ComPtr;

[[nodiscard]] std::wstring Wide(const std::string_view utf8) {
  if (utf8.empty()) return {};
  const int length = MultiByteToWideChar(
    CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()),
        result.data(), length) != length) return {};
  return result;
}

void ApplyTracking(IDWriteTextLayout* layout, const std::wstring_view text, const float fontSize) {
  ComPtr<IDWriteTextLayout1> layout1;
  if (FAILED(layout->QueryInterface(IID_PPV_ARGS(&layout1))) || text.empty()) return;
  const DWRITE_TEXT_RANGE all{0, static_cast<UINT32>(text.size())};
  layout1->SetCharacterSpacing(0.0f, fontSize * 0.02f, 0.0f, all);
  if (text.size() < 2 || (text.back() != L'\u2588' && text.back() != L' ')) return;
  std::size_t previousStart = text.size() - 2;
  if (previousStart > 0 && text[previousStart] >= 0xdc00 && text[previousStart] <= 0xdfff &&
      text[previousStart - 1] >= 0xd800 && text[previousStart - 1] <= 0xdbff) {
    --previousStart;
  }
  const DWRITE_TEXT_RANGE beforeCursor{
    static_cast<UINT32>(previousStart),
    static_cast<UINT32>(text.size() - 1 - previousStart),
  };
  layout1->SetCharacterSpacing(0.0f, fontSize * 0.06f, 0.0f, beforeCursor);
}

void ApplyUniformTracking(
    IDWriteTextLayout* layout,
    const std::wstring_view text,
    const float fontSize,
    const float em) {
  ComPtr<IDWriteTextLayout1> layout1;
  if (FAILED(layout->QueryInterface(IID_PPV_ARGS(&layout1))) || text.empty()) return;
  const DWRITE_TEXT_RANGE range{0, static_cast<UINT32>(text.size())};
  layout1->SetCharacterSpacing(0.0f, fontSize * em, 0.0f, range);
}

[[nodiscard]] std::vector<float> BoxBlurPass(
    const std::vector<float>& source,
    const std::uint32_t width,
    const std::uint32_t height,
    const int radius,
    const bool horizontal) {
  std::vector<float> output(source.size(), 0.0f);
  if (radius <= 0) return source;
  const int diameter = radius * 2 + 1;
  const int lines = horizontal ? static_cast<int>(height) : static_cast<int>(width);
  const int length = horizontal ? static_cast<int>(width) : static_cast<int>(height);
  const auto index = [width, horizontal](const int line, const int position) {
    return horizontal
      ? static_cast<std::size_t>(line) * width + static_cast<std::size_t>(position)
      : static_cast<std::size_t>(position) * width + static_cast<std::size_t>(line);
  };
  for (int line = 0; line < lines; ++line) {
    double sum = 0.0;
    for (int position = 0; position <= radius && position < length; ++position) {
      sum += source[index(line, position)];
    }
    for (int position = 0; position < length; ++position) {
      output[index(line, position)] = static_cast<float>(sum / diameter);
      const int leaving = position - radius;
      const int entering = position + radius + 1;
      if (leaving >= 0) sum -= source[index(line, leaving)];
      if (entering < length) sum += source[index(line, entering)];
    }
  }
  return output;
}

[[nodiscard]] std::vector<float> Blur(
    const std::vector<float>& source,
    const std::uint32_t width,
    const std::uint32_t height,
    const float cssRadius) {
  const int radius = std::max(1, static_cast<int>(std::lround(cssRadius * 0.5f)));
  std::vector<float> result = source;
  for (int pass = 0; pass < 3; ++pass) {
    result = BoxBlurPass(result, width, height, radius, true);
    result = BoxBlurPass(result, width, height, radius, false);
  }
  return result;
}

}  // namespace

IntroOverlayBitmap BuildIntroOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale,
    const std::array<float, 3>& accent) {
  const std::wstring text = Wide(utf8);
  if (text.empty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = std::clamp(
    static_cast<float>(outputWidth) * 0.042f, 20.0f * dpiScale, 52.0f * dpiScale);
  const float maximumWidth = std::max(1.0f, std::floor(static_cast<float>(outputWidth) * 0.88f));

  ComPtr<IWICImagingFactory> wic;
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  ComPtr<IDWriteTextFormat> format;
  if (FAILED(CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) ||
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf())) ||
      FAILED(DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()))) ||
      FAILED(dwrite->CreateTextFormat(
        L"Consolas", nullptr, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, fontSize, L"en-us", &format))) return {};
  format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);

  ComPtr<IDWriteTextLayout> naturalLayout;
  if (FAILED(dwrite->CreateTextLayout(
        text.data(), static_cast<UINT32>(text.size()), format.Get(),
        1'000'000.0f, std::max(1'000'000.0f, static_cast<float>(outputHeight)),
        &naturalLayout))) return {};
  naturalLayout->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  ApplyTracking(naturalLayout.Get(), text, fontSize);
  DWRITE_TEXT_METRICS naturalMetrics{};
  if (FAILED(naturalLayout->GetMetrics(&naturalMetrics))) return {};
  const float textWidth = std::min(
    maximumWidth, std::max(1.0f, std::ceil(naturalMetrics.widthIncludingTrailingWhitespace)));

  ComPtr<IDWriteTextLayout> layout;
  if (FAILED(dwrite->CreateTextLayout(
        text.data(), static_cast<UINT32>(text.size()), format.Get(), textWidth,
        std::max(1'000'000.0f, static_cast<float>(outputHeight)), &layout))) return {};
  layout->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
  ApplyTracking(layout.Get(), text, fontSize);
  DWRITE_TEXT_METRICS metrics{};
  if (FAILED(layout->GetMetrics(&metrics))) return {};

  const std::uint32_t padding = std::max(
    1u, static_cast<std::uint32_t>(std::ceil(64.0f * dpiScale)));
  IntroOverlayBitmap result;
  result.width = std::max(1u, static_cast<std::uint32_t>(std::ceil(textWidth)) + padding * 2u);
  result.height = std::max(1u, static_cast<std::uint32_t>(std::ceil(metrics.height)) + padding * 2u);
  result.originX = std::floor((static_cast<float>(outputWidth) - result.width) * 0.5f);
  result.originY = std::floor((static_cast<float>(outputHeight) - result.height) * 0.5f);

  ComPtr<IWICBitmap> bitmap;
  ComPtr<ID2D1RenderTarget> target;
  ComPtr<ID2D1SolidColorBrush> brush;
  if (FAILED(wic->CreateBitmap(
        result.width, result.height, GUID_WICPixelFormat32bppPBGRA,
        WICBitmapCacheOnLoad, &bitmap))) return {};
  const auto properties = D2D1::RenderTargetProperties(
    D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
    96.0f, 96.0f, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
  if (FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target)) ||
      FAILED(target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &brush))) return {};
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  target->BeginDraw();
  target->Clear(D2D1::ColorF(0, 0.0f));
  target->DrawTextLayout(
    D2D1::Point2F(static_cast<float>(padding), static_cast<float>(padding)),
    layout.Get(), brush.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
  if (FAILED(target->EndDraw())) return {};

  WICRect rectangle{0, 0, static_cast<INT>(result.width), static_cast<INT>(result.height)};
  ComPtr<IWICBitmapLock> lock;
  if (FAILED(bitmap->Lock(&rectangle, WICBitmapLockRead, &lock))) return {};
  UINT stride = 0;
  UINT byteCount = 0;
  BYTE* pixels = nullptr;
  if (FAILED(lock->GetStride(&stride)) || FAILED(lock->GetDataPointer(&byteCount, &pixels)) ||
      pixels == nullptr) return {};
  std::vector<float> mask(static_cast<std::size_t>(result.width) * result.height, 0.0f);
  for (std::uint32_t row = 0; row < result.height; ++row) {
    for (std::uint32_t column = 0; column < result.width; ++column) {
      mask[static_cast<std::size_t>(row) * result.width + column] =
        pixels[static_cast<std::size_t>(row) * stride + column * 4u + 3u] / 255.0f;
    }
  }
  const auto inner = Blur(mask, result.width, result.height, 12.0f * dpiScale);
  const auto outer = Blur(mask, result.width, result.height, 28.0f * dpiScale);
  result.bgra.resize(mask.size() * 4u);
  for (std::size_t index = 0; index < mask.size(); ++index) {
    const float alpha = 1.0f - (1.0f - std::clamp(mask[index], 0.0f, 1.0f)) *
      (1.0f - 0.65f * std::clamp(inner[index], 0.0f, 1.0f)) *
      (1.0f - 0.35f * std::clamp(outer[index], 0.0f, 1.0f));
    const auto channel = [alpha](const float value) {
      return static_cast<std::uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * alpha * 255.0f));
    };
    result.bgra[index * 4u] = channel(accent[2]);
    result.bgra[index * 4u + 1u] = channel(accent[1]);
    result.bgra[index * 4u + 2u] = channel(accent[0]);
    result.bgra[index * 4u + 3u] = static_cast<std::uint8_t>(std::lround(alpha * 255.0f));
  }
  return result;
}

IntroOverlayBitmap BuildHudOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale) {
  const std::wstring text = Wide(utf8);
  if (text.empty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = 12.0f * dpiScale;
  const float lineHeight = 18.0f * dpiScale;
  const float paddingX = 8.0f * dpiScale;
  const float paddingY = 4.0f * dpiScale;

  ComPtr<IWICImagingFactory> wic;
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  ComPtr<IDWriteTextFormat> format;
  if (FAILED(CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) ||
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf())) ||
      FAILED(DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()))) ||
      FAILED(dwrite->CreateTextFormat(
        L"Consolas", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, fontSize, L"en-us", &format))) return {};
  format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  format->SetLineSpacing(
    DWRITE_LINE_SPACING_METHOD_UNIFORM, lineHeight, std::min(lineHeight, fontSize * 1.15f));

  ComPtr<IDWriteTextLayout> layout;
  if (FAILED(dwrite->CreateTextLayout(
        text.data(), static_cast<UINT32>(text.size()), format.Get(),
        std::max(1.0f, static_cast<float>(outputWidth) - 16.0f * dpiScale),
        lineHeight, &layout))) return {};
  ApplyTracking(layout.Get(), text, fontSize);
  DWRITE_TEXT_METRICS metrics{};
  if (FAILED(layout->GetMetrics(&metrics))) return {};

  IntroOverlayBitmap result;
  result.width = std::max(1u, static_cast<std::uint32_t>(std::ceil(
    metrics.widthIncludingTrailingWhitespace + paddingX * 2.0f)));
  result.height = std::max(1u, static_cast<std::uint32_t>(std::ceil(
    lineHeight + paddingY * 2.0f)));
  result.originX = std::floor(8.0f * dpiScale);
  result.originY = std::floor(8.0f * dpiScale);

  ComPtr<IWICBitmap> bitmap;
  ComPtr<ID2D1RenderTarget> target;
  ComPtr<ID2D1SolidColorBrush> background;
  ComPtr<ID2D1SolidColorBrush> foreground;
  if (FAILED(wic->CreateBitmap(
        result.width, result.height, GUID_WICPixelFormat32bppPBGRA,
        WICBitmapCacheOnLoad, &bitmap))) return {};
  const auto properties = D2D1::RenderTargetProperties(
    D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
    96.0f, 96.0f, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
  if (FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target)) ||
      FAILED(target->CreateSolidColorBrush(D2D1::ColorF(0x000000, 0.55f), &background)) ||
      FAILED(target->CreateSolidColorBrush(D2D1::ColorF(0x00ff41), &foreground))) return {};
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  target->BeginDraw();
  target->Clear(D2D1::ColorF(0, 0.0f));
  const auto bounds = D2D1::RoundedRect(
    D2D1::RectF(0.0f, 0.0f, static_cast<float>(result.width), static_cast<float>(result.height)),
    4.0f * dpiScale, 4.0f * dpiScale);
  target->FillRoundedRectangle(bounds, background.Get());
  target->DrawTextLayout(
    D2D1::Point2F(paddingX, paddingY), layout.Get(), foreground.Get(),
    D2D1_DRAW_TEXT_OPTIONS_CLIP);
  if (FAILED(target->EndDraw())) return {};

  WICRect rectangle{0, 0, static_cast<INT>(result.width), static_cast<INT>(result.height)};
  ComPtr<IWICBitmapLock> lock;
  if (FAILED(bitmap->Lock(&rectangle, WICBitmapLockRead, &lock))) return {};
  UINT stride = 0;
  UINT byteCount = 0;
  BYTE* pixels = nullptr;
  if (FAILED(lock->GetStride(&stride)) || FAILED(lock->GetDataPointer(&byteCount, &pixels)) ||
      pixels == nullptr) return {};
  const std::size_t rowBytes = static_cast<std::size_t>(result.width) * 4u;
  result.bgra.resize(rowBytes * result.height);
  for (std::uint32_t row = 0; row < result.height; ++row) {
    std::copy_n(
      pixels + static_cast<std::size_t>(row) * stride,
      rowBytes,
      result.bgra.data() + static_cast<std::size_t>(row) * rowBytes);
  }
  return result;
}

IntroOverlayBitmap BuildToastOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale,
    const std::array<float, 3>& accent) {
  const std::wstring text = Wide(utf8);
  if (text.empty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = 12.0f * dpiScale;
  const float lineHeight = 16.2f * dpiScale;
  const float paddingX = 13.0f * dpiScale;
  const float paddingY = 9.0f * dpiScale;
  const float maximumWidth = std::max(
    1.0f, std::min(280.0f * dpiScale, static_cast<float>(outputWidth) - 32.0f * dpiScale));

  ComPtr<IWICImagingFactory> wic;
  ComPtr<ID2D1Factory> d2d;
  ComPtr<IDWriteFactory> dwrite;
  ComPtr<IDWriteTextFormat> format;
  if (FAILED(CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) ||
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf())) ||
      FAILED(DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()))) ||
      FAILED(dwrite->CreateTextFormat(
        L"Consolas", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, fontSize, L"en-us", &format))) return {};
  format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
  format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
  format->SetLineSpacing(
    DWRITE_LINE_SPACING_METHOD_UNIFORM, lineHeight, std::min(lineHeight, fontSize * 1.15f));

  ComPtr<IDWriteTextLayout> layout;
  if (FAILED(dwrite->CreateTextLayout(
        text.data(), static_cast<UINT32>(text.size()), format.Get(),
        std::max(1.0f, maximumWidth - paddingX * 2.0f),
        std::max(lineHeight, static_cast<float>(outputHeight)), &layout))) return {};
  ApplyUniformTracking(layout.Get(), text, fontSize, 0.08f);
  DWRITE_TEXT_METRICS metrics{};
  if (FAILED(layout->GetMetrics(&metrics))) return {};

  IntroOverlayBitmap result;
  result.width = std::max(1u, static_cast<std::uint32_t>(std::ceil(std::min(
    maximumWidth, metrics.widthIncludingTrailingWhitespace + paddingX * 2.0f))));
  result.height = std::max(1u, static_cast<std::uint32_t>(std::ceil(
    std::max(lineHeight, metrics.height) + paddingY * 2.0f)));
  result.originX = std::floor(static_cast<float>(outputWidth) - 16.0f * dpiScale - result.width);
  result.originY = std::floor(16.0f * dpiScale);

  ComPtr<IWICBitmap> bitmap;
  ComPtr<ID2D1RenderTarget> target;
  ComPtr<ID2D1SolidColorBrush> background;
  ComPtr<ID2D1SolidColorBrush> border;
  ComPtr<ID2D1SolidColorBrush> foreground;
  if (FAILED(wic->CreateBitmap(
        result.width, result.height, GUID_WICPixelFormat32bppPBGRA,
        WICBitmapCacheOnLoad, &bitmap))) return {};
  const auto properties = D2D1::RenderTargetProperties(
    D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
    96.0f, 96.0f, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
  if (FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), properties, &target)) ||
      FAILED(target->CreateSolidColorBrush(D2D1::ColorF(0.008f, 0.055f, 0.024f, 0.92f), &background)) ||
      FAILED(target->CreateSolidColorBrush(
        D2D1::ColorF(accent[0], accent[1], accent[2], 0.42f), &border)) ||
      FAILED(target->CreateSolidColorBrush(
        D2D1::ColorF(accent[0], accent[1], accent[2], 1.0f), &foreground))) return {};
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  target->BeginDraw();
  target->Clear(D2D1::ColorF(0, 0.0f));
  const auto bounds = D2D1::RoundedRect(
    D2D1::RectF(
      0.5f * dpiScale, 0.5f * dpiScale,
      static_cast<float>(result.width) - 0.5f * dpiScale,
      static_cast<float>(result.height) - 0.5f * dpiScale),
    6.0f * dpiScale, 6.0f * dpiScale);
  target->FillRoundedRectangle(bounds, background.Get());
  target->DrawRoundedRectangle(bounds, border.Get(), std::max(1.0f, dpiScale));
  target->DrawTextLayout(
    D2D1::Point2F(paddingX, paddingY), layout.Get(), foreground.Get(),
    D2D1_DRAW_TEXT_OPTIONS_CLIP);
  if (FAILED(target->EndDraw())) return {};

  WICRect rectangle{0, 0, static_cast<INT>(result.width), static_cast<INT>(result.height)};
  ComPtr<IWICBitmapLock> lock;
  if (FAILED(bitmap->Lock(&rectangle, WICBitmapLockRead, &lock))) return {};
  UINT stride = 0;
  UINT byteCount = 0;
  BYTE* pixels = nullptr;
  if (FAILED(lock->GetStride(&stride)) || FAILED(lock->GetDataPointer(&byteCount, &pixels)) ||
      pixels == nullptr) return {};
  const std::size_t rowBytes = static_cast<std::size_t>(result.width) * 4u;
  result.bgra.resize(rowBytes * result.height);
  for (std::uint32_t row = 0; row < result.height; ++row) {
    std::copy_n(
      pixels + static_cast<std::size_t>(row) * stride,
      rowBytes,
      result.bgra.data() + static_cast<std::size_t>(row) * rowBytes);
  }
  return result;
}

}  // namespace matrixcode::render
