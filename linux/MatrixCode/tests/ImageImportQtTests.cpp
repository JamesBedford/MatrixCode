#include "TestHarness.h"

#include <array>
#include <cmath>

#include <QDir>
#include <QFile>
#include <QImage>
#include <QTemporaryDir>

#include "matrixcode/platform/ImageImportQt.h"

void RunImageImportQtTests() {
  using namespace matrixcode::platform;

  const std::array<std::uint8_t, 8> range{
    0, 0, 0, 0,
    255, 255, 255, 255,
  };
  const auto normalized = ImageMaskFromStraightRgba("  Range  ", 2, 1, range);
  MX_EXPECT(normalized.has_value());
  MX_EXPECT_EQ(normalized->name, std::string("Range"));
  MX_EXPECT_EQ(normalized->luminance.size(), std::size_t{2});
  MX_EXPECT_EQ(normalized->luminance[0], std::uint8_t{0});
  MX_EXPECT_EQ(normalized->luminance[1], std::uint8_t{255});

  const std::array<std::uint8_t, 4> translucent{255, 255, 255, 128};
  const auto alphaSquared = ImageMaskFromStraightRgba("", 1, 1, translucent);
  MX_EXPECT(alphaSquared.has_value());
  MX_EXPECT_EQ(alphaSquared->name, std::string("Image"));
  const double alpha = 128.0 / 255.0;
  const auto expected = static_cast<std::uint8_t>(
    std::lround(std::pow(alpha * alpha, 0.82) * 255.0));
  MX_EXPECT_EQ(alphaSquared->luminance[0], expected);

  MX_EXPECT(!ImageMaskFromStraightRgba("bad", 0, 1, {}).has_value());
  MX_EXPECT(!ImageMaskFromStraightRgba("bad", 97, 1, {}).has_value());
  MX_EXPECT(!ImageMaskFromStraightRgba("bad", 1, 1, range).has_value());

  QTemporaryDir temporary;
  MX_EXPECT(temporary.isValid());
  const QString largePath = QDir(temporary.path()).filePath(QStringLiteral("large.test.png"));
  QImage large(200, 100, QImage::Format_RGBA8888);
  for (int row = 0; row < large.height(); ++row) {
    for (int column = 0; column < large.width(); ++column) {
      large.setPixelColor(column, row, QColor(column, row * 2, 255 - column, 255));
    }
  }
  MX_EXPECT(large.save(largePath, "PNG"));
  QString diagnostic = QStringLiteral("stale");
  const auto importedLarge = ImportImageMaskQt(largePath, &diagnostic);
  MX_EXPECT(importedLarge.has_value());
  MX_EXPECT(diagnostic.isEmpty());
  MX_EXPECT_EQ(importedLarge->name, std::string("large.test"));
  MX_EXPECT_EQ(importedLarge->width, std::uint32_t{96});
  MX_EXPECT_EQ(importedLarge->height, std::uint32_t{48});
  MX_EXPECT_EQ(importedLarge->luminance.size(), std::size_t{96 * 48});

  const QString smallPath = QDir(temporary.path()).filePath(QStringLiteral("small.png"));
  QImage small(12, 6, QImage::Format_RGBA8888);
  small.fill(QColor(255, 255, 255, 255));
  MX_EXPECT(small.save(smallPath, "PNG"));
  const auto importedSmall = ImportImageMaskQt(smallPath, &diagnostic);
  MX_EXPECT(importedSmall.has_value());
  MX_EXPECT_EQ(importedSmall->width, std::uint32_t{12});
  MX_EXPECT_EQ(importedSmall->height, std::uint32_t{6});

  const QString invalidPath = QDir(temporary.path()).filePath(QStringLiteral("invalid.png"));
  QFile invalid(invalidPath);
  MX_EXPECT(invalid.open(QIODevice::WriteOnly));
  MX_EXPECT_EQ(invalid.write("not an image"), qint64{12});
  invalid.close();
  MX_EXPECT(!ImportImageMaskQt(invalidPath, &diagnostic).has_value());
  MX_EXPECT(!diagnostic.isEmpty());

  std::size_t failed = 0;
  const auto limited = ImportImageMasksQt({invalidPath, smallPath, largePath}, 1, &failed);
  MX_EXPECT_EQ(limited.size(), std::size_t{1});
  MX_EXPECT_EQ(failed, std::size_t{1});
  MX_EXPECT_EQ(limited.front().name, std::string("small"));
}
