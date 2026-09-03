#include "matrixcode/render/GlyphAtlas.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <string_view>

#include <QFont>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QImage>
#include <QPainter>
#include <QString>
#include <QStringList>

#include "matrixcode/core/GlyphSet.h"

namespace matrixcode::render {
namespace {

constexpr std::uint32_t kAtlasCellPixels = 64;

[[nodiscard]] QString FirstInstalledFamily(const std::initializer_list<const char*> choices) {
  const QStringList installed = QFontDatabase::families();
  for (const char* choice : choices) {
    const QString requested = QString::fromUtf8(choice);
    const auto match = std::find_if(installed.cbegin(), installed.cend(), [&](const QString& family) {
      return family.compare(requested, Qt::CaseInsensitive) == 0;
    });
    if (match != installed.cend()) return *match;
  }
  const QFont fallback = QFontDatabase::systemFont(QFontDatabase::FixedFont);
  return fallback.family();
}

[[nodiscard]] QString FontFamily(const Controls& controls) {
  if (controls.glyphMode == GlyphMode::Binary || controls.glyphMode == GlyphMode::Digits) {
    return FirstInstalledFamily({"Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono"});
  }
  switch (controls.glyphFont) {
    case GlyphFont::Gothic:
      return FirstInstalledFamily({"Noto Sans CJK JP", "Noto Sans JP", "IPAGothic", "Ubuntu"});
    case GlyphFont::Mono:
      return FirstInstalledFamily({"Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono"});
    case GlyphFont::Terminal:
      return FirstInstalledFamily({"Liberation Mono", "DejaVu Sans Mono", "Ubuntu Mono"});
    case GlyphFont::Rounded:
      return FirstInstalledFamily({"Noto Sans", "Ubuntu", "DejaVu Sans"});
    case GlyphFont::Mincho:
      return FirstInstalledFamily({"Noto Serif CJK JP", "Noto Serif JP", "IPAMincho", "DejaVu Serif"});
    case GlyphFont::Matrix:
      return FirstInstalledFamily({"Noto Sans CJK JP", "Noto Sans JP", "IPAGothic", "DejaVu Sans"});
  }
  return FirstInstalledFamily({"Noto Sans CJK JP", "Noto Sans JP", "DejaVu Sans"});
}

[[nodiscard]] int PositiveModulo(const long long value, const int divisor) noexcept {
  const int remainder = static_cast<int>(value % divisor);
  return remainder < 0 ? remainder + divisor : remainder;
}

[[nodiscard]] QString DisplayGlyph(
    const QString& source,
    const std::size_t index,
    const std::size_t rainGlyphCount,
    const std::size_t digitStart,
    const GlyphMode mode) {
  if (index >= rainGlyphCount) return source;
  const auto offset = static_cast<long long>(index) - static_cast<long long>(digitStart);
  if (mode == GlyphMode::Binary) return QString::number(PositiveModulo(offset, 2));
  if (mode == GlyphMode::Digits) return QString::number(PositiveModulo(offset, 10));
  return source;
}

void DrawReadableDigit(QPainter& painter, const int digit, const QRectF& cell) {
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
  const qreal extent = std::min(cell.width(), cell.height());
  const qreal margin = extent * 0.2;
  const qreal thickness = std::max<qreal>(3.0, extent * 0.12);
  const qreal left = cell.left() + margin;
  const qreal right = cell.right() - margin;
  const qreal top = cell.top() + margin;
  const qreal bottom = cell.bottom() - margin;
  const qreal middle = cell.center().y();
  const qreal capInset = thickness * 0.5;
  const auto horizontal = [&](const qreal y) {
    painter.fillRect(QRectF(
      left + capInset, y - thickness * 0.5,
      right - left - capInset * 2.0, thickness), Qt::white);
  };
  const auto vertical = [&](const qreal x, const qreal y0, const qreal y1) {
    painter.fillRect(QRectF(
      x - thickness * 0.5, y0 + capInset,
      thickness, y1 - y0 - capInset * 2.0), Qt::white);
  };
  if (digit == 0) {
    QPen pen(Qt::white, thickness);
    pen.setCapStyle(Qt::SquareCap);
    painter.setPen(pen);
    painter.setBrush(Qt::NoBrush);
    const qreal inset = margin + thickness * 0.5;
    painter.drawEllipse(cell.adjusted(inset, inset, -inset, -inset));
    return;
  }
  if (digit == 1) {
    const qreal centerX = cell.center().x();
    painter.fillRect(QRectF(centerX - thickness * 0.5, top, thickness, bottom - top), Qt::white);
    painter.fillRect(QRectF(
      centerX - thickness * 1.2, top, thickness * 1.7, thickness), Qt::white);
    painter.fillRect(QRectF(
      centerX - thickness * 1.4, bottom - thickness, thickness * 2.8, thickness), Qt::white);
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

[[nodiscard]] bool CellIsInked(
    const QImage& image,
    const std::size_t index,
    const std::uint32_t columns) {
  const int x0 = static_cast<int>((index % columns) * kAtlasCellPixels);
  const int y0 = static_cast<int>((index / columns) * kAtlasCellPixels);
  for (int y = y0; y < y0 + static_cast<int>(kAtlasCellPixels); y += 2) {
    const QRgb* row = reinterpret_cast<const QRgb*>(image.constScanLine(y));
    for (int x = x0; x < x0 + static_cast<int>(kAtlasCellPixels); x += 2) {
      if (qAlpha(row[x]) > 24) return true;
    }
  }
  return false;
}

}  // namespace

GlyphAtlasBitmap BuildGlyphAtlas(const Controls& controls) {
  const GlyphSet glyphSet(controls.glyphMode);
  const std::size_t glyphCount = glyphSet.Count();
  if (glyphCount == 0) return {};
  const auto columns = static_cast<std::uint32_t>(std::ceil(std::sqrt(static_cast<double>(glyphCount))));
  const auto rows = static_cast<std::uint32_t>((glyphCount + columns - 1) / columns);
  const std::uint32_t width = columns * kAtlasCellPixels;
  const std::uint32_t height = rows * kAtlasCellPixels;

  QImage image(static_cast<int>(width), static_cast<int>(height), QImage::Format_ARGB32_Premultiplied);
  if (image.isNull()) return {};
  image.fill(Qt::transparent);

  const QString family = FontFamily(controls);
  QFont font(family);
  font.setPixelSize(static_cast<int>(std::lround(kAtlasCellPixels * 0.78)));
  font.setWeight(QFont::Medium);
  font.setStyleStrategy(static_cast<QFont::StyleStrategy>(
    QFont::PreferAntialias | QFont::PreferQuality));
  const QFontMetricsF metrics(font);
  const std::size_t rainGlyphCount = glyphSet.Message().start;
  const std::size_t digitStart = glyphSet.Digits().start;
  const bool readableDigits = controls.glyphMode == GlyphMode::Binary ||
    controls.glyphMode == GlyphMode::Digits;

  QPainter painter(&image);
  painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing, true);
  painter.setPen(Qt::white);
  painter.setFont(font);

  const auto drawGlyph = [&](const QString& sourceGlyph, const std::size_t targetIndex) {
    const QString glyph = DisplayGlyph(
      sourceGlyph, targetIndex, rainGlyphCount, digitStart, controls.glyphMode);
    const qreal x = static_cast<qreal>((targetIndex % columns) * kAtlasCellPixels);
    const qreal y = static_cast<qreal>((targetIndex / columns) * kAtlasCellPixels);
    const QRectF cell(x, y, kAtlasCellPixels, kAtlasCellPixels);
    painter.save();
    if (controls.mirror && targetIndex < rainGlyphCount) {
      painter.translate(x + kAtlasCellPixels, 0.0);
      painter.scale(-1.0, 1.0);
    }
    const QRectF localCell = controls.mirror && targetIndex < rainGlyphCount
      ? QRectF(0.0, y, kAtlasCellPixels, kAtlasCellPixels)
      : cell;
    if (readableDigits && targetIndex < rainGlyphCount && glyph.size() == 1 && glyph.front().isDigit()) {
      DrawReadableDigit(painter, glyph.front().digitValue(), localCell);
    } else {
      const qreal advance = metrics.horizontalAdvance(glyph);
      const qreal baseline = localCell.center().y() + (metrics.ascent() - metrics.descent()) * 0.5;
      painter.drawText(QPointF(localCell.center().x() - advance * 0.5, baseline), glyph);
    }
    painter.restore();
  };

  std::vector<QString> glyphs;
  glyphs.reserve(glyphCount);
  for (const std::wstring& glyph : glyphSet.Glyphs()) {
    glyphs.push_back(QString::fromStdWString(glyph));
  }
  for (std::size_t index = 0; index < glyphs.size(); ++index) drawGlyph(glyphs[index], index);

  std::vector<std::size_t> inkedIndexes;
  for (std::size_t index = 0; index < glyphs.size(); ++index) {
    if (CellIsInked(image, index, columns)) inkedIndexes.push_back(index);
  }
  const std::optional<std::size_t> fallbackIndex = inkedIndexes.empty()
    ? std::nullopt
    : std::optional<std::size_t>(inkedIndexes[inkedIndexes.size() / 2]);
  if (fallbackIndex.has_value()) {
    for (std::size_t index = 0; index < glyphs.size(); ++index) {
      if (CellIsInked(image, index, columns)) continue;
      const QRect rectangle(
        static_cast<int>((index % columns) * kAtlasCellPixels),
        static_cast<int>((index / columns) * kAtlasCellPixels),
        static_cast<int>(kAtlasCellPixels),
        static_cast<int>(kAtlasCellPixels));
      painter.setCompositionMode(QPainter::CompositionMode_Clear);
      painter.fillRect(rectangle, Qt::transparent);
      painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
      drawGlyph(glyphs[*fallbackIndex], index);
    }
  }
  painter.end();

  std::vector<std::size_t> remainingBlank;
  for (std::size_t index = 0; index < glyphs.size(); ++index) {
    if (!CellIsInked(image, index, columns)) remainingBlank.push_back(index);
  }
  if (fallbackIndex.has_value() && !remainingBlank.empty()) {
    const int sourceX = static_cast<int>((*fallbackIndex % columns) * kAtlasCellPixels);
    const int sourceY = static_cast<int>((*fallbackIndex / columns) * kAtlasCellPixels);
    const QImage sourceCell = image.copy(
      sourceX, sourceY, static_cast<int>(kAtlasCellPixels), static_cast<int>(kAtlasCellPixels));
    const bool sourceMirrored = controls.mirror && *fallbackIndex < rainGlyphCount;
    QPainter fallbackPainter(&image);
    fallbackPainter.setCompositionMode(QPainter::CompositionMode_Source);
    for (const std::size_t index : remainingBlank) {
      QImage copy = sourceCell;
      const bool targetMirrored = controls.mirror && index < rainGlyphCount;
      if (sourceMirrored != targetMirrored) copy = copy.mirrored(true, false);
      fallbackPainter.drawImage(
        QPoint(
          static_cast<int>((index % columns) * kAtlasCellPixels),
          static_cast<int>((index / columns) * kAtlasCellPixels)),
        copy);
    }
  }

  GlyphAtlasBitmap result;
  result.width = width;
  result.height = height;
  result.columns = columns;
  result.rows = rows;
  result.cellPixels = kAtlasCellPixels;
  result.resolvedFontFamily = family.toUtf8().toStdString();
  result.coverage.resize(static_cast<std::size_t>(width) * height);
  for (std::uint32_t y = 0; y < height; ++y) {
    const QRgb* row = reinterpret_cast<const QRgb*>(image.constScanLine(static_cast<int>(y)));
    for (std::uint32_t x = 0; x < width; ++x) {
      result.coverage[static_cast<std::size_t>(y) * width + x] =
        static_cast<std::uint8_t>(qAlpha(row[x]));
    }
  }
  result.blankCellCount = 0;
  for (std::size_t index = 0; index < glyphs.size(); ++index) {
    if (!CellIsInked(image, index, columns)) ++result.blankCellCount;
  }
  return result;
}

}  // namespace matrixcode::render
