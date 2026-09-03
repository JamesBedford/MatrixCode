#include "matrixcode/platform/ImageImportQt.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include <QFileInfo>
#include <QImage>
#include <QImageIOHandler>
#include <QImageReader>

#include "matrixcode/core/Utf8.h"

namespace matrixcode::platform {
namespace {

constexpr std::uint32_t kMaximumDimension = 96;

[[nodiscard]] QSize TargetSize(const QSize& source) {
  if (!source.isValid() || source.isEmpty()) return {};
  const double scale = std::min({
    1.0,
    static_cast<double>(kMaximumDimension) / source.width(),
    static_cast<double>(kMaximumDimension) / source.height(),
  });
  return {
    std::max(1, static_cast<int>(std::lround(source.width() * scale))),
    std::max(1, static_cast<int>(std::lround(source.height() * scale))),
  };
}

[[nodiscard]] bool IsQuarterTurn(const QImageIOHandler::Transformations transformation) {
  return transformation.testFlag(QImageIOHandler::TransformationRotate90);
}

}  // namespace

std::optional<ImageMask> ImageMaskFromStraightRgba(
    std::string name,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::span<const std::uint8_t> rgba) {
  if (width == 0 || height == 0 || width > kMaximumDimension || height > kMaximumDimension ||
      width > std::numeric_limits<std::size_t>::max() / height / 4 ||
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

std::optional<ImageMask> ImportImageMaskQt(
    const QString& path,
    QString* diagnostic) {
  if (diagnostic != nullptr) diagnostic->clear();
  QImageReader reader(path);
  reader.setAutoTransform(true);
  const QSize encodedSize = reader.size();
  if (!encodedSize.isValid() || encodedSize.isEmpty()) {
    if (diagnostic != nullptr) {
      *diagnostic = reader.errorString().isEmpty()
        ? QStringLiteral("The image dimensions are invalid.")
        : reader.errorString();
    }
    return std::nullopt;
  }

  const bool quarterTurn = IsQuarterTurn(reader.transformation());
  const QSize orientedSize = quarterTurn ? encodedSize.transposed() : encodedSize;
  const QSize targetSize = TargetSize(orientedSize);
  if (!targetSize.isValid()) {
    if (diagnostic != nullptr) *diagnostic = QStringLiteral("The image dimensions are invalid.");
    return std::nullopt;
  }
  const QSize decoderSize = quarterTurn ? targetSize.transposed() : targetSize;
  if (decoderSize != encodedSize) reader.setScaledSize(decoderSize);

  QImage image = reader.read();
  if (image.isNull()) {
    if (diagnostic != nullptr) *diagnostic = reader.errorString();
    return std::nullopt;
  }
  if (image.size() != targetSize) {
    image = image.scaled(targetSize, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
  }
  image = image.convertToFormat(QImage::Format_RGBA8888);
  if (image.isNull() || image.width() <= 0 || image.height() <= 0 ||
      image.width() > static_cast<int>(kMaximumDimension) ||
      image.height() > static_cast<int>(kMaximumDimension)) {
    if (diagnostic != nullptr) *diagnostic = QStringLiteral("Could not convert the image to RGBA8.");
    return std::nullopt;
  }

  const std::size_t rowBytes = static_cast<std::size_t>(image.width()) * 4;
  std::vector<std::uint8_t> rgba(rowBytes * static_cast<std::size_t>(image.height()));
  for (int row = 0; row < image.height(); ++row) {
    std::copy_n(
      image.constScanLine(row),
      rowBytes,
      rgba.data() + static_cast<std::size_t>(row) * rowBytes);
  }
  return ImageMaskFromStraightRgba(
    QFileInfo(path).completeBaseName().toUtf8().toStdString(),
    static_cast<std::uint32_t>(image.width()),
    static_cast<std::uint32_t>(image.height()),
    rgba);
}

std::vector<ImageMask> ImportImageMasksQt(
    const QStringList& paths,
    const std::size_t limit,
    std::size_t* failedCount) {
  if (failedCount != nullptr) *failedCount = 0;
  std::vector<ImageMask> images;
  images.reserve(std::min(limit, static_cast<std::size_t>(paths.size())));
  for (const QString& path : paths) {
    if (images.size() >= limit) break;
    auto image = ImportImageMaskQt(path);
    if (image.has_value()) images.push_back(std::move(*image));
    else if (failedCount != nullptr) ++*failedCount;
  }
  return images;
}

}  // namespace matrixcode::platform
