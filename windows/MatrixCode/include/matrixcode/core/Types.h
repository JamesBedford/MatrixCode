#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace matrixcode {

inline constexpr std::uint8_t kFlagIsHead = 0x80;
inline constexpr std::uint8_t kFlagWhiteHead = 0x40;
inline constexpr std::uint8_t kPhaseMask = 0x3f;
inline constexpr std::size_t kMaxGlyphs = 255;

enum class GlyphMode { Matrix, Katakana, Binary, Digits, Latin, Symbols };
enum class GlyphFont { Matrix, Gothic, Mono, Terminal, Rounded, Mincho };
enum class QualityTier { Low, Medium, High };
enum class MessageLayout { Row, Drop };
enum class MessageDirection { TopToBottom, BottomToTop };

struct SimConfig {
  double targetCellPixels = 18.0;
  double minSpeed = 3.5;
  double speedRange = 8.0;
  double decayPerSecond = 0.08;
  double trailLengthScale = 1.2;
  double mutationRate = 1.6;
  double crossfadeDuration = 0.09;
  double whiteHeadFraction = 0.2;
  double respawnChance = 1.1;
  double respawnDelayMin = 0.15;
  double respawnDelayJitter = 2.6;
  double startRowsAbove = 24.0;
  double tailMargin = 36.0;
  double globalSyncAmount = 0.35;
  double globalSyncHz = 1.7;
  double messageBrightFloor = 0.45;
};

struct Controls {
  double speed = 1.0;
  double trailLength = 0.255;
  double trailVariation = 1.0;
  double density = 2.0;
  double rampUpMilliseconds = 8000.0;
  double glyphRate = 1.0;
  double glyphScale = 1.0;
  GlyphMode glyphMode = GlyphMode::Matrix;
  GlyphFont glyphFont = GlyphFont::Matrix;
  double glow = 0.9;
  double leadBrightness = 1.6;
  std::string preset = "classic";
  std::string customColor = "#00FF41";
  bool mirror = true;
  bool scanlines = false;
  double vignette = 0.0;
  bool allowOverlap = true;
  QualityTier quality = QualityTier::High;
};

struct ColorPalette {
  std::array<float, 3> background{};
  std::array<float, 3> tail{};
  std::array<float, 3> body{};
  std::array<float, 3> bright{};
  std::array<float, 3> head{};
};

struct IntroLine {
  std::string text;
  double holdMilliseconds = 2800.0;
  double pauseMilliseconds = 0.0;
};

struct IntroDocument {
  bool enabled = true;
  std::vector<IntroLine> lines;
  double charMilliseconds = 95.0;
  double startDelayMilliseconds = 600.0;
  double fadeOutMilliseconds = 900.0;
  bool rainDuringIntro = false;
  double postIntroDelayMilliseconds = 0.0;
};

struct MessagesDocument {
  std::vector<std::string> messages;
  bool enabled = false;
  double frequencyMilliseconds = 8000.0;
  double persistenceMilliseconds = 10000.0;
  double appearMilliseconds = 4000.0;
  double disappearMilliseconds = 4000.0;
  bool flickerOut = true;
  bool brightnessFade = false;
  MessageLayout layout = MessageLayout::Row;
  MessageDirection direction = MessageDirection::TopToBottom;
  double position = 0.5;
  double jitter = 0.25;
};

struct ImageMask {
  std::string name = "Image";
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::vector<std::uint8_t> luminance;
};

struct ImagesDocument {
  std::vector<ImageMask> images;
  bool enabled = false;
  double frequencyMilliseconds = 14000.0;
  double persistenceMilliseconds = 12000.0;
  double appearMilliseconds = 4500.0;
  double disappearMilliseconds = 4500.0;
  bool flickerOut = true;
  bool brightnessFade = false;
  double imageScale = 0.72;
  double placementJitter = 0.35;
};

struct CountdownMoment {
  std::string name;
  std::optional<double> targetMilliseconds;
};

struct CountdownDocument {
  std::optional<double> targetMilliseconds;
  std::vector<CountdownMoment> moments;
};

struct SettingsSnapshot {
  std::uint32_t formatVersion = 1;
  Controls controls;
  IntroDocument intro;
  MessagesDocument messages;
  ImagesDocument images;
  CountdownDocument countdown;
  std::string viewerName;
};

struct PackedCell {
  std::uint8_t newGlyph = 0;
  std::uint8_t brightness = 0;
  std::uint8_t flagsAndPhase = 0;
  std::uint8_t oldGlyph = 0;
};

[[nodiscard]] ColorPalette PaletteForControls(const Controls& controls);
[[nodiscard]] std::string ToString(GlyphMode mode);
[[nodiscard]] std::string ToString(GlyphFont font);
[[nodiscard]] std::string ToString(QualityTier quality);
[[nodiscard]] GlyphMode GlyphModeFromString(const std::string& value);
[[nodiscard]] GlyphFont GlyphFontFromString(const std::string& value);
[[nodiscard]] QualityTier QualityTierFromString(const std::string& value);

}  // namespace matrixcode
