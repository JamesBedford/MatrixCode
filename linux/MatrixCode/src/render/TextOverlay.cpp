#include "matrixcode/render/TextOverlay.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

#include <QColor>
#include <QFont>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QString>
#include <QStringList>
#include <QTextLayout>
#include <QTextOption>

namespace matrixcode::render {
namespace {

[[nodiscard]] QString MonoFamily() {
  const QStringList installed = QFontDatabase::families();
  for (const char* candidate : {"Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono"}) {
    const QString requested = QString::fromUtf8(candidate);
    const auto match = std::find_if(installed.cbegin(), installed.cend(), [&](const QString& family) {
      return family.compare(requested, Qt::CaseInsensitive) == 0;
    });
    if (match != installed.cend()) return *match;
  }
  return QFontDatabase::systemFont(QFontDatabase::FixedFont).family();
}

[[nodiscard]] QFont OverlayFont(const float pixelSize, const float trackingEm, const bool medium) {
  QFont font(MonoFamily());
  font.setPixelSize(std::max(1, static_cast<int>(std::lround(pixelSize))));
  font.setWeight(medium ? QFont::Medium : QFont::Normal);
  font.setStyleStrategy(static_cast<QFont::StyleStrategy>(
    QFont::PreferAntialias | QFont::PreferQuality));
  font.setLetterSpacing(QFont::AbsoluteSpacing, pixelSize * trackingEm);
  return font;
}

[[nodiscard]] std::vector<float> BoxBlurPass(
    const std::vector<float>& source,
    const std::uint32_t width,
    const std::uint32_t height,
    const int radius,
    const bool horizontal) {
  std::vector<float> output(source.size(), 0.0f);
  if (radius <= 0 || width == 0 || height == 0) return source;
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

[[nodiscard]] std::vector<std::uint8_t> PremultipliedRgba(const QImage& input) {
  const QImage converted = input.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
  if (converted.isNull()) return {};
  const std::size_t rowBytes = static_cast<std::size_t>(converted.width()) * 4u;
  std::vector<std::uint8_t> output(rowBytes * static_cast<std::size_t>(converted.height()));
  for (int row = 0; row < converted.height(); ++row) {
    std::copy_n(
      converted.constScanLine(row),
      rowBytes,
      output.data() + static_cast<std::size_t>(row) * rowBytes);
  }
  return output;
}

[[nodiscard]] QColor AccentColor(const std::array<float, 3>& accent, const float alpha = 1.0f) {
  return QColor::fromRgbF(
    std::clamp(accent[0], 0.0f, 1.0f),
    std::clamp(accent[1], 0.0f, 1.0f),
    std::clamp(accent[2], 0.0f, 1.0f),
    std::clamp(alpha, 0.0f, 1.0f));
}

struct LaidOutText {
  std::unique_ptr<QTextLayout> layout;
  qreal width = 0.0;
  qreal height = 0.0;
};

[[nodiscard]] LaidOutText LayOutText(const QString& text, const QFont& font, const qreal maximumWidth) {
  LaidOutText result;
  result.layout = std::make_unique<QTextLayout>(text, font);
  QTextOption option;
  option.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
  result.layout->setTextOption(option);
  result.layout->beginLayout();
  qreal y = 0.0;
  while (true) {
    QTextLine line = result.layout->createLine();
    if (!line.isValid()) break;
    line.setLineWidth(std::max<qreal>(1.0, maximumWidth));
    line.setPosition(QPointF(0.0, y));
    y += line.height();
    result.width = std::max(result.width, line.naturalTextWidth());
  }
  result.layout->endLayout();
  result.height = y;
  return result;
}

}  // namespace

TextOverlayBitmap BuildIntroOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale,
    const std::array<float, 3>& accent) {
  const QString text = QString::fromUtf8(utf8.data(), static_cast<qsizetype>(utf8.size()));
  if (text.isEmpty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = std::clamp(
    static_cast<float>(outputWidth) * 0.042f, 20.0f * dpiScale, 52.0f * dpiScale);
  const qreal maximumWidth = std::max(1.0f, std::floor(static_cast<float>(outputWidth) * 0.88f));
  const QFont font = OverlayFont(fontSize, 0.02f, true);
  LaidOutText laidOut = LayOutText(text, font, maximumWidth);
  if (!laidOut.layout || laidOut.height <= 0.0) return {};

  const std::uint32_t padding = std::max(
    1u, static_cast<std::uint32_t>(std::ceil(64.0f * dpiScale)));
  TextOverlayBitmap result;
  result.width = std::max(
    1u, static_cast<std::uint32_t>(std::ceil(std::min(maximumWidth, laidOut.width))) + padding * 2u);
  result.height = std::max(
    1u, static_cast<std::uint32_t>(std::ceil(laidOut.height)) + padding * 2u);
  result.originX = std::floor((static_cast<float>(outputWidth) - result.width) * 0.5f);
  result.originY = std::floor((static_cast<float>(outputHeight) - result.height) * 0.5f);

  QImage mask(
    static_cast<int>(result.width), static_cast<int>(result.height), QImage::Format_ARGB32_Premultiplied);
  if (mask.isNull()) return {};
  mask.fill(Qt::transparent);
  {
    QPainter painter(&mask);
    painter.setRenderHint(QPainter::TextAntialiasing, true);
    painter.setPen(Qt::white);
    laidOut.layout->draw(&painter, QPointF(padding, padding));
  }

  std::vector<float> coverage(static_cast<std::size_t>(result.width) * result.height, 0.0f);
  for (std::uint32_t row = 0; row < result.height; ++row) {
    const QRgb* pixels = reinterpret_cast<const QRgb*>(mask.constScanLine(static_cast<int>(row)));
    for (std::uint32_t column = 0; column < result.width; ++column) {
      coverage[static_cast<std::size_t>(row) * result.width + column] = qAlpha(pixels[column]) / 255.0f;
    }
  }
  const auto inner = Blur(coverage, result.width, result.height, 12.0f * dpiScale);
  const auto outer = Blur(coverage, result.width, result.height, 28.0f * dpiScale);
  result.rgba.resize(coverage.size() * 4u);
  for (std::size_t index = 0; index < coverage.size(); ++index) {
    const float alpha = 1.0f - (1.0f - std::clamp(coverage[index], 0.0f, 1.0f)) *
      (1.0f - 0.65f * std::clamp(inner[index], 0.0f, 1.0f)) *
      (1.0f - 0.35f * std::clamp(outer[index], 0.0f, 1.0f));
    const auto channel = [alpha](const float value) {
      return static_cast<std::uint8_t>(std::lround(
        std::clamp(value, 0.0f, 1.0f) * alpha * 255.0f));
    };
    result.rgba[index * 4u] = channel(accent[0]);
    result.rgba[index * 4u + 1u] = channel(accent[1]);
    result.rgba[index * 4u + 2u] = channel(accent[2]);
    result.rgba[index * 4u + 3u] =
      static_cast<std::uint8_t>(std::lround(alpha * 255.0f));
  }
  return result;
}

TextOverlayBitmap BuildHudOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale) {
  const QString text = QString::fromUtf8(utf8.data(), static_cast<qsizetype>(utf8.size()));
  if (text.isEmpty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = 12.0f * dpiScale;
  const float lineHeight = 18.0f * dpiScale;
  const float paddingX = 8.0f * dpiScale;
  const float paddingY = 4.0f * dpiScale;
  const QFont font = OverlayFont(fontSize, 0.02f, false);
  const QFontMetricsF metrics(font);

  TextOverlayBitmap result;
  result.width = std::max(1u, static_cast<std::uint32_t>(std::ceil(
    std::min<qreal>(
      std::max(1.0f, static_cast<float>(outputWidth) - 16.0f * dpiScale),
      metrics.horizontalAdvance(text) + paddingX * 2.0f))));
  result.height = std::max(1u, static_cast<std::uint32_t>(std::ceil(lineHeight + paddingY * 2.0f)));
  result.originX = std::floor(8.0f * dpiScale);
  result.originY = std::floor(8.0f * dpiScale);

  QImage image(
    static_cast<int>(result.width), static_cast<int>(result.height), QImage::Format_ARGB32_Premultiplied);
  if (image.isNull()) return {};
  image.fill(Qt::transparent);
  {
    QPainter painter(&image);
    painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing, true);
    painter.setPen(Qt::NoPen);
    painter.setBrush(QColor::fromRgbF(0.0, 0.0, 0.0, 0.55));
    painter.drawRoundedRect(image.rect(), 4.0f * dpiScale, 4.0f * dpiScale);
    painter.setFont(font);
    painter.setPen(QColor::fromRgb(0x00, 0xff, 0x41));
    painter.drawText(
      QRectF(paddingX, paddingY, result.width - paddingX * 2.0f, lineHeight),
      Qt::AlignLeft | Qt::AlignVCenter | Qt::TextSingleLine,
      text);
  }
  result.rgba = PremultipliedRgba(image);
  return result;
}

TextOverlayBitmap BuildToastOverlayBitmap(
    const std::string_view utf8,
    const std::uint32_t outputWidth,
    const std::uint32_t outputHeight,
    const float requestedDpiScale,
    const std::array<float, 3>& accent) {
  const QString text = QString::fromUtf8(utf8.data(), static_cast<qsizetype>(utf8.size()));
  if (text.isEmpty() || outputWidth == 0 || outputHeight == 0) return {};
  const float dpiScale = std::clamp(requestedDpiScale, 0.5f, 8.0f);
  const float fontSize = 12.0f * dpiScale;
  const float lineHeight = 16.2f * dpiScale;
  const float paddingX = 13.0f * dpiScale;
  const float paddingY = 9.0f * dpiScale;
  const float maximumWidth = std::max(
    1.0f, std::min(280.0f * dpiScale, static_cast<float>(outputWidth) - 32.0f * dpiScale));
  const QFont font = OverlayFont(fontSize, 0.08f, false);
  LaidOutText laidOut = LayOutText(text, font, std::max(1.0f, maximumWidth - paddingX * 2.0f));
  if (!laidOut.layout || laidOut.height <= 0.0) return {};

  TextOverlayBitmap result;
  result.width = std::max(1u, static_cast<std::uint32_t>(std::ceil(std::min(
    maximumWidth, static_cast<float>(laidOut.width + paddingX * 2.0f)))));
  result.height = std::max(1u, static_cast<std::uint32_t>(std::ceil(
    std::max<qreal>(lineHeight, laidOut.height) + paddingY * 2.0f)));
  result.originX = std::floor(static_cast<float>(outputWidth) - 16.0f * dpiScale - result.width);
  result.originY = std::floor(16.0f * dpiScale);

  QImage image(
    static_cast<int>(result.width), static_cast<int>(result.height), QImage::Format_ARGB32_Premultiplied);
  if (image.isNull()) return {};
  image.fill(Qt::transparent);
  {
    QPainter painter(&image);
    painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing, true);
    const qreal halfStroke = 0.5f * dpiScale;
    const QRectF bounds = QRectF(image.rect()).adjusted(halfStroke, halfStroke, -halfStroke, -halfStroke);
    QPainterPath path;
    path.addRoundedRect(bounds, 6.0f * dpiScale, 6.0f * dpiScale);
    painter.fillPath(path, QColor::fromRgbF(0.008, 0.055, 0.024, 0.92));
    QPen border(AccentColor(accent, 0.42f), std::max(1.0f, dpiScale));
    painter.setPen(border);
    painter.setBrush(Qt::NoBrush);
    painter.drawPath(path);
    painter.setPen(AccentColor(accent));
    laidOut.layout->draw(&painter, QPointF(paddingX, paddingY));
  }
  result.rgba = PremultipliedRgba(image);
  return result;
}

}  // namespace matrixcode::render
