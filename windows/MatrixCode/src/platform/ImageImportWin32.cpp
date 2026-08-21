#include "matrixcode/platform/ImageImportWin32.h"

#include <algorithm>
#include <cmath>
#include <commdlg.h>
#include <cstdint>
#include <limits>
#include <propvarutil.h>
#include <sstream>
#include <utility>
#include <wincodec.h>
#include <wrl/client.h>

#include "matrixcode/core/Utf8.h"

namespace matrixcode::platform {
namespace {

using Microsoft::WRL::ComPtr;
constexpr std::uint32_t kMaximumDimension = 96;

[[nodiscard]] std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
    CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
    nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(
    CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
    result.data(), size, nullptr, nullptr);
  return result;
}

void SetDiagnostic(std::wstring* diagnostic, const wchar_t* operation, const HRESULT result) {
  if (diagnostic == nullptr) return;
  std::wostringstream message;
  message << operation << L" failed (HRESULT 0x" << std::hex
          << static_cast<unsigned long>(result) << L").";
  *diagnostic = message.str();
}

[[nodiscard]] std::uint16_t Orientation(IWICBitmapFrameDecode* frame) noexcept {
  ComPtr<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader))) return 1;
  PROPVARIANT value;
  PropVariantInit(&value);
  HRESULT result = reader->GetMetadataByName(L"System.Photo.Orientation", &value);
  if (FAILED(result)) {
    PropVariantClear(&value);
    PropVariantInit(&value);
    result = reader->GetMetadataByName(L"/app1/ifd/{ushort=274}", &value);
  }
  const auto orientation = SUCCEEDED(result) && value.vt == VT_UI2 ? value.uiVal : 1u;
  PropVariantClear(&value);
  return orientation >= 1u && orientation <= 8u
    ? static_cast<std::uint16_t>(orientation)
    : static_cast<std::uint16_t>(1u);
}

[[nodiscard]] WICBitmapTransformOptions TransformForOrientation(
    const std::uint16_t orientation) noexcept {
  switch (orientation) {
    case 2: return WICBitmapTransformFlipHorizontal;
    case 3: return WICBitmapTransformRotate180;
    case 4: return WICBitmapTransformFlipVertical;
    // IWICBitmapFlipRotator applies the flip before the rotation.
    case 5: return static_cast<WICBitmapTransformOptions>(
      WICBitmapTransformFlipHorizontal | WICBitmapTransformRotate270);
    case 6: return WICBitmapTransformRotate90;
    case 7: return static_cast<WICBitmapTransformOptions>(
      WICBitmapTransformFlipHorizontal | WICBitmapTransformRotate90);
    case 8: return WICBitmapTransformRotate270;
    default: return WICBitmapTransformRotate0;
  }
}

[[nodiscard]] bool QuarterTurn(const WICBitmapTransformOptions transform) noexcept {
  const auto rotation = static_cast<unsigned int>(transform) & 0x3u;
  return rotation == WICBitmapTransformRotate90 || rotation == WICBitmapTransformRotate270;
}

[[nodiscard]] std::vector<std::filesystem::path> PickImagePaths(HWND owner) {
  std::vector<wchar_t> buffer(65536, L'\0');
  constexpr wchar_t filter[] =
    L"Images\0*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.tif;*.tiff;*.heic;*.heif;*.webp\0"
    L"All files\0*.*\0\0";
  OPENFILENAMEW dialog{sizeof(dialog)};
  dialog.hwndOwner = owner;
  dialog.lpstrFilter = filter;
  dialog.lpstrFile = buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(buffer.size());
  dialog.lpstrTitle = L"Add images to Matrix Code";
  dialog.Flags = OFN_ALLOWMULTISELECT | OFN_EXPLORER | OFN_FILEMUSTEXIST |
    OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
  if (GetOpenFileNameW(&dialog) == FALSE) return {};

  const std::filesystem::path first(buffer.data());
  const wchar_t* cursor = buffer.data() + first.wstring().size() + 1;
  if (*cursor == L'\0') return {first};
  std::vector<std::filesystem::path> paths;
  while (*cursor != L'\0') {
    const std::filesystem::path name(cursor);
    paths.push_back(first / name);
    cursor += name.wstring().size() + 1;
  }
  return paths;
}

}  // namespace

std::optional<ImageMask> ImageMaskFromRgba(
    std::string name,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::span<const std::uint8_t> rgba) {
  if (width == 0 || height == 0 || width > kMaximumDimension || height > kMaximumDimension ||
      rgba.size() != static_cast<std::size_t>(width) * height * 4) return std::nullopt;
  std::vector<double> values(static_cast<std::size_t>(width) * height);
  double minimum = 1.0;
  double maximum = 0.0;
  for (std::size_t pixel = 0, offset = 0; pixel < values.size(); ++pixel, offset += 4) {
    const double alpha = rgba[offset + 3] / 255.0;
    const double luminance = (0.2126 * (rgba[offset] / 255.0) +
      0.7152 * (rgba[offset + 1] / 255.0) +
      0.0722 * (rgba[offset + 2] / 255.0)) * alpha * alpha;
    values[pixel] = luminance;
    minimum = std::min(minimum, luminance);
    maximum = std::max(maximum, luminance);
  }
  const bool normalize = maximum - minimum > 0.035;
  const double range = maximum - minimum;
  std::vector<std::uint8_t> mask(values.size());
  for (std::size_t index = 0; index < values.size(); ++index) {
    const double value = normalize ? (values[index] - minimum) / range : values[index];
    mask[index] = static_cast<std::uint8_t>(std::lround(
      std::pow(std::clamp(value, 0.0, 1.0), 0.82) * 255.0));
  }
  name = std::string(TrimUtf8(TruncateUtf8(name, 80)));
  if (name.empty()) name = "Image";
  return ImageMask{std::move(name), width, height, std::move(mask)};
}

std::optional<ImageMask> ImportImageMaskWic(
    const std::filesystem::path& path,
    std::wstring* diagnostic) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT result = CoCreateInstance(
    CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Creating the WIC factory", result);
    return std::nullopt;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  result = factory->CreateDecoderFromFilename(
    path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder);
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Opening the image", result);
    return std::nullopt;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  result = decoder->GetFrame(0, &frame);
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Decoding the first image frame", result);
    return std::nullopt;
  }
  UINT sourceWidth = 0;
  UINT sourceHeight = 0;
  result = frame->GetSize(&sourceWidth, &sourceHeight);
  if (FAILED(result) || sourceWidth == 0 || sourceHeight == 0) {
    SetDiagnostic(diagnostic, L"Reading image dimensions", result);
    return std::nullopt;
  }

  const auto transform = TransformForOrientation(Orientation(frame.Get()));
  const bool quarterTurn = QuarterTurn(transform);
  const double orientedWidth = quarterTurn ? sourceHeight : sourceWidth;
  const double orientedHeight = quarterTurn ? sourceWidth : sourceHeight;
  const double scale = std::min({1.0, kMaximumDimension / orientedWidth,
    kMaximumDimension / orientedHeight});
  const auto targetWidth = static_cast<UINT>(std::max(1.0, std::round(orientedWidth * scale)));
  const auto targetHeight = static_cast<UINT>(std::max(1.0, std::round(orientedHeight * scale)));
  const UINT preRotateWidth = quarterTurn ? targetHeight : targetWidth;
  const UINT preRotateHeight = quarterTurn ? targetWidth : targetHeight;

  ComPtr<IWICBitmapScaler> scaler;
  result = factory->CreateBitmapScaler(&scaler);
  if (SUCCEEDED(result)) {
    result = scaler->Initialize(
      frame.Get(), preRotateWidth, preRotateHeight, WICBitmapInterpolationModeFant);
  }
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Downsampling the image", result);
    return std::nullopt;
  }
  ComPtr<IWICBitmapSource> source;
  result = scaler.As(&source);
  if (FAILED(result)) return std::nullopt;
  if (transform != WICBitmapTransformRotate0) {
    ComPtr<IWICBitmapFlipRotator> rotator;
    result = factory->CreateBitmapFlipRotator(&rotator);
    if (SUCCEEDED(result)) result = rotator->Initialize(source.Get(), transform);
    if (FAILED(result)) {
      SetDiagnostic(diagnostic, L"Applying image orientation", result);
      return std::nullopt;
    }
    result = rotator.As(&source);
    if (FAILED(result)) return std::nullopt;
  }
  ComPtr<IWICFormatConverter> converter;
  result = factory->CreateFormatConverter(&converter);
  if (SUCCEEDED(result)) {
    result = converter->Initialize(
      source.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone,
      nullptr, 0.0, WICBitmapPaletteTypeCustom);
  }
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Converting image pixels", result);
    return std::nullopt;
  }
  const UINT stride = targetWidth * 4u;
  std::vector<std::uint8_t> rgba(static_cast<std::size_t>(stride) * targetHeight);
  result = converter->CopyPixels(
    nullptr, stride, static_cast<UINT>(rgba.size()), rgba.data());
  if (FAILED(result)) {
    SetDiagnostic(diagnostic, L"Reading image pixels", result);
    return std::nullopt;
  }
  auto name = Utf8(path.stem().wstring());
  return ImageMaskFromRgba(std::move(name), targetWidth, targetHeight, rgba);
}

std::vector<ImageMask> PickAndImportImageMasks(
    HWND owner,
    const std::size_t limit,
    std::size_t* failedCount) {
  if (failedCount != nullptr) *failedCount = 0;
  std::vector<ImageMask> images;
  if (limit == 0) return images;
  const auto paths = PickImagePaths(owner);
  images.reserve(std::min(limit, paths.size()));
  for (const auto& path : paths) {
    if (images.size() >= limit) break;
    auto image = ImportImageMaskWic(path);
    if (image.has_value()) images.push_back(std::move(*image));
    else if (failedCount != nullptr) ++*failedCount;
  }
  return images;
}

}  // namespace matrixcode::platform
