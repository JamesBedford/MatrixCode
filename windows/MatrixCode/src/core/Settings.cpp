#include "matrixcode/core/Settings.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <charconv>
#include <initializer_list>
#include <set>

#include "matrixcode/core/Utf8.h"

namespace matrixcode {
namespace {

constexpr std::size_t kMaximumLines = 12;
constexpr std::size_t kMaximumMessages = 12;
constexpr std::size_t kMaximumMoments = 12;
constexpr std::size_t kMaximumText = 120;
constexpr std::size_t kMaximumMomentName = 40;
constexpr std::size_t kMaximumImageName = 80;
constexpr std::size_t kMaximumImages = 64;
constexpr std::size_t kMaximumImageCharacters = 49152;
constexpr std::uint32_t kMaximumStoredImageDimension = 96;

[[nodiscard]] const json::Value* Document(const json::Value& root, const std::string_view key) {
  const auto* value = root.Find(key);
  if (value == nullptr) return nullptr;
  if (value->AsObject() != nullptr) return value;
  if (const auto* string = value->AsString()) {
    // Imported native-macOS documents store each value as a JSON string. Parsing into a
    // thread-local keeps this adapter read-only while accepting that portable shape.
    thread_local json::Value parsed;
    const auto result = json::Parse(*string);
    if (result.value.has_value() && result.value->AsObject() != nullptr) {
      parsed = *result.value;
      return &parsed;
    }
  }
  return nullptr;
}

[[nodiscard]] double Number(
    const json::Value* object,
    const std::string_view key,
    const double fallback,
    const double minimum,
    const double maximum) {
  const auto* value = object == nullptr ? nullptr : object->Find(key);
  const auto* number = value == nullptr ? nullptr : value->AsNumber();
  return number != nullptr && std::isfinite(*number)
    ? std::clamp(*number, minimum, maximum)
    : fallback;
}

[[nodiscard]] bool Boolean(
    const json::Value* object, const std::string_view key, const bool fallback) {
  const auto* value = object == nullptr ? nullptr : object->Find(key);
  const auto* boolean = value == nullptr ? nullptr : value->AsBool();
  return boolean != nullptr ? *boolean : fallback;
}

[[nodiscard]] std::string Text(
    const json::Value* object,
    const std::string_view key,
    std::string fallback,
    const std::size_t maximum) {
  const auto* value = object == nullptr ? nullptr : object->Find(key);
  const auto* string = value == nullptr ? nullptr : value->AsString();
  if (string == nullptr) return fallback;
  return TruncateUtf8(*string, maximum);
}

[[nodiscard]] std::string Trim(std::string value) {
  return std::string(TrimUtf8(value));
}

[[nodiscard]] bool Choice(const std::string& value, const std::initializer_list<std::string_view> choices) {
  return std::find(choices.begin(), choices.end(), value) != choices.end();
}

[[nodiscard]] std::array<float, 3> Rgb(const std::uint32_t value) {
  return {
    static_cast<float>((value >> 16u) & 0xffu) / 255.0f,
    static_cast<float>((value >> 8u) & 0xffu) / 255.0f,
    static_cast<float>(value & 0xffu) / 255.0f,
  };
}

[[nodiscard]] json::Value OptionalNumber(const std::optional<double>& value) {
  return value.has_value() ? json::Value(*value) : json::Value(nullptr);
}

}  // namespace

SettingsSnapshot DefaultSettings() {
  SettingsSnapshot settings;
  settings.intro.lines = {
    {"Wake up, {name}...", 2800.0, 0.0},
    {"The Matrix has you...", 2800.0, 0.0},
    {"Follow the white rabbit.", 2800.0, 0.0},
    {"Knock, knock, {name}.", 2800.0, 0.0},
  };
  settings.intro.charMilliseconds = 95.0;
  settings.intro.startDelayMilliseconds = 600.0;
  settings.intro.fadeOutMilliseconds = 900.0;
  settings.messages.messages = {
    "WAKE UP", "THE MATRIX HAS YOU", "FOLLOW THE WHITE RABBIT", "{countup}",
  };
  return settings;
}

SettingsSnapshot SanitizeSettings(const json::Value& root) {
  SettingsSnapshot output = DefaultSettings();
  if (const auto* version = root.Find("formatVersion"); version != nullptr && version->AsNumber() != nullptr) {
    output.formatVersion = static_cast<std::uint32_t>(std::clamp(*version->AsNumber(), 1.0, 1.0));
  }

  const auto* controls = Document(root, "mx-controls");
  output.controls.speed = Number(controls, "speed", 1.0, 0.1, 3.0);
  output.controls.trailLength = Number(controls, "trailLength", 0.255, 0.01, 0.5);
  output.controls.trailVariation = Number(controls, "trailVariation", 1.0, 0.0, 1.0);
  output.controls.density = Number(controls, "density", 2.0, 0.1, 100.0);
  output.controls.rampUpMilliseconds = Number(controls, "rampUpMs", 8000.0, 0.0, 60000.0);
  output.controls.glyphRate = Number(controls, "glyphRate", 1.0, 0.0, 5.0);
  output.controls.glyphScale = Number(controls, "glyphScale", 1.0, 0.5, 10.0);
  output.controls.glow = Number(controls, "glow", 0.9, 0.0, 2.5);
  output.controls.leadBrightness = Number(controls, "leadBrightness", 1.6, 0.0, 3.0);
  output.controls.vignette = Number(controls, "vignette", 0.0, 0.0, 1.0);
  if (const auto* legacyVignette = controls == nullptr ? nullptr : controls->Find("vignette");
      legacyVignette != nullptr && legacyVignette->AsBool() != nullptr) {
    output.controls.vignette = *legacyVignette->AsBool() ? 0.42 : 0.0;
  }
  output.controls.mirror = Boolean(controls, "mirror", true);
  output.controls.scanlines = Boolean(controls, "scanlines", false);
  output.controls.allowOverlap = Boolean(controls, "allowOverlap", true);
  output.controls.glyphMode = GlyphModeFromString(Text(controls, "glyphMode", "matrix", 20));
  output.controls.glyphFont = GlyphFontFromString(Text(controls, "glyphFont", "matrix", 20));
  output.controls.quality = QualityTierFromString(Text(controls, "quality", "high", 20));
  const auto preset = Text(controls, "preset", "classic", 20);
  output.controls.preset = Choice(preset, {
    "classic", "amber", "orange", "gold", "red", "pink", "purple", "blue", "white", "custom"})
    ? preset : "classic";
  const auto customColor = Text(controls, "customColor", "#00FF41", kMaximumText);
  bool validColor = customColor.size() == 7 && customColor.front() == '#';
  for (std::size_t index = 1; validColor && index < customColor.size(); ++index) {
    validColor = std::isxdigit(static_cast<unsigned char>(customColor[index])) != 0;
  }
  output.controls.customColor = validColor ? customColor : "#00FF41";
  std::transform(
    output.controls.customColor.begin(), output.controls.customColor.end(),
    output.controls.customColor.begin(),
    [](const unsigned char value) { return static_cast<char>(std::toupper(value)); });

  const auto* intro = Document(root, "mx-intro");
  output.intro.enabled = Boolean(intro, "enabled", true);
  output.intro.charMilliseconds = Number(intro, "charMs", 95.0, 10.0, 500.0);
  output.intro.startDelayMilliseconds = Number(intro, "startDelayMs", 600.0, 0.0, 10000.0);
  output.intro.fadeOutMilliseconds = Number(intro, "fadeOutMs", 900.0, 0.0, 10000.0);
  output.intro.rainDuringIntro = Boolean(intro, "rainDuringIntro", false);
  output.intro.postIntroDelayMilliseconds = Number(intro, "postIntroDelayMs", 0.0, 0.0, 10000.0);
  if (const auto* linesValue = intro == nullptr ? nullptr : intro->Find("lines");
      linesValue != nullptr && linesValue->AsArray() != nullptr) {
    std::vector<IntroLine> lines;
    const auto& values = *linesValue->AsArray();
    const std::size_t inspected = std::min(kMaximumLines, values.size());
    for (std::size_t index = 0; index < inspected; ++index) {
      const auto& value = values[index];
      const auto* object = value.AsObject();
      if (object == nullptr || value.Find("text") == nullptr || value.Find("text")->AsString() == nullptr) continue;
      lines.push_back({
        Text(&value, "text", "", kMaximumText),
        Number(&value, "holdMs", 2800.0, 0.0, 20000.0),
        Number(&value, "pauseMs", 0.0, 0.0, 20000.0),
      });
    }
    if (!lines.empty()) output.intro.lines = std::move(lines);
  }

  const auto* messages = Document(root, "mx-messages");
  if (root.Find("mx-messages") != nullptr) output.messages.messages.clear();
  output.messages.enabled = Boolean(messages, "enabled", false);
  output.messages.frequencyMilliseconds = Number(messages, "frequencyMs", 8000.0, 500.0, 600000.0);
  output.messages.persistenceMilliseconds = Number(messages, "persistenceMs", 10000.0, 500.0, 600000.0);
  output.messages.appearMilliseconds = Number(messages, "appearMs", 4000.0, 0.0, 600000.0);
  output.messages.disappearMilliseconds = Number(messages, "disappearMs", 4000.0, 0.0, 600000.0);
  output.messages.flickerOut = Boolean(messages, "flickerOut", true);
  output.messages.brightnessFade = Boolean(messages, "brightnessFade", false);
  output.messages.position = Number(messages, "verticalPosition", 0.5, 0.0, 1.0);
  output.messages.jitter = Number(messages, "verticalJitter", 0.25, 0.0, 1.0);
  output.messages.layout = Text(messages, "messageLayout", "row", 20) == "drop"
    ? MessageLayout::Drop : MessageLayout::Row;
  output.messages.direction = Text(messages, "messageDirection", "topToBottom", 20) == "bottomToTop"
    ? MessageDirection::BottomToTop : MessageDirection::TopToBottom;
  if (const auto* messageValues = messages == nullptr ? nullptr : messages->Find("messages");
      messageValues != nullptr && messageValues->AsArray() != nullptr) {
    const auto& values = *messageValues->AsArray();
    const std::size_t inspected = std::min(kMaximumMessages, values.size());
    for (std::size_t index = 0; index < inspected; ++index) {
      const auto& value = values[index];
      if (const auto* text = value.AsString()) {
        auto clean = TruncateUtf8(*text, kMaximumText);
        if (!Trim(clean).empty()) output.messages.messages.push_back(std::move(clean));
      }
    }
  }

  const auto* images = Document(root, "mx-images");
  output.images.enabled = Boolean(images, "enabled", false);
  output.images.frequencyMilliseconds = Number(images, "frequencyMs", 14000.0, 500.0, 600000.0);
  output.images.persistenceMilliseconds = Number(images, "persistenceMs", 12000.0, 500.0, 600000.0);
  output.images.appearMilliseconds = Number(images, "appearMs", 4500.0, 0.0, 600000.0);
  output.images.disappearMilliseconds = Number(images, "disappearMs", 4500.0, 0.0, 600000.0);
  output.images.flickerOut = Boolean(images, "flickerOut", true);
  output.images.brightnessFade = Boolean(images, "brightnessFade", false);
  output.images.imageScale = Number(images, "imageScale", 0.72, 0.05, 1.0);
  output.images.placementJitter = Number(images, "imagePlacementJitter", 0.35, 0.0, 1.0);
  if (const auto* imageValues = images == nullptr ? nullptr : images->Find("images");
      imageValues != nullptr && imageValues->AsArray() != nullptr) {
    for (const auto& value : *imageValues->AsArray()) {
      if (output.images.images.size() == kMaximumImages) break;
      const auto width = static_cast<std::uint32_t>(Number(&value, "width", 0.0, 1.0, kMaximumStoredImageDimension));
      const auto height = static_cast<std::uint32_t>(Number(&value, "height", 0.0, 1.0, kMaximumStoredImageDimension));
      const auto data = Text(&value, "data", "", kMaximumImageCharacters);
      auto decoded = DecodeBase64(data);
      if (width == 0 || height == 0 || !decoded.has_value() || decoded->size() != width * height) continue;
      auto name = Trim(Text(&value, "name", "Image", kMaximumImageName));
      output.images.images.push_back({name.empty() ? "Image" : std::move(name), width, height, std::move(*decoded)});
    }
  }

  const auto* countdown = Document(root, "mx-countdown");
  if (const auto* target = countdown == nullptr ? nullptr : countdown->Find("targetMs");
      target != nullptr && target->AsNumber() != nullptr && std::isfinite(*target->AsNumber())) {
    output.countdown.targetMilliseconds = std::clamp(*target->AsNumber(), 0.0, 8.64e15);
  }
  if (const auto* momentValues = countdown == nullptr ? nullptr : countdown->Find("moments");
      momentValues != nullptr && momentValues->AsArray() != nullptr) {
    std::set<std::string> seen;
    const auto& values = *momentValues->AsArray();
    const std::size_t inspected = std::min(kMaximumMoments, values.size());
    for (std::size_t index = 0; index < inspected; ++index) {
      const auto& value = values[index];
      auto name = Trim(Text(&value, "name", "", kMaximumMomentName));
      name.erase(std::remove_if(name.begin(), name.end(), [](const char character) {
        return character == ':' || character == '{' || character == '}';
      }), name.end());
      name = Trim(std::move(name));
      if (name.empty() || !seen.insert(name).second) continue;
      std::optional<double> target;
      if (const auto* rawTarget = value.Find("targetMs");
          rawTarget != nullptr && rawTarget->AsNumber() != nullptr && std::isfinite(*rawTarget->AsNumber())) {
        target = std::clamp(*rawTarget->AsNumber(), 0.0, 8.64e15);
      }
      output.countdown.moments.push_back({std::move(name), target});
    }
  }

  if (const auto* name = root.Find("mx-user-name"); name != nullptr && name->AsString() != nullptr) {
    output.viewerName = Trim(TruncateUtf8(*name->AsString(), 80));
  }
  return output;
}

json::Value EncodeSettings(const SettingsSnapshot& settings) {
  json::Object controls{
    {"speed", settings.controls.speed}, {"trailLength", settings.controls.trailLength},
    {"trailVariation", settings.controls.trailVariation}, {"density", settings.controls.density},
    {"rampUpMs", settings.controls.rampUpMilliseconds}, {"glyphRate", settings.controls.glyphRate},
    {"glyphScale", settings.controls.glyphScale}, {"glyphMode", ToString(settings.controls.glyphMode)},
    {"glyphFont", ToString(settings.controls.glyphFont)}, {"glow", settings.controls.glow},
    {"leadBrightness", settings.controls.leadBrightness}, {"preset", settings.controls.preset},
    {"customColor", settings.controls.customColor}, {"mirror", settings.controls.mirror},
    {"scanlines", settings.controls.scanlines}, {"vignette", settings.controls.vignette},
    {"allowOverlap", settings.controls.allowOverlap}, {"quality", ToString(settings.controls.quality)},
  };
  json::Array lines;
  for (const auto& line : settings.intro.lines) {
    lines.emplace_back(json::Object{{"text", line.text}, {"holdMs", line.holdMilliseconds},
      {"pauseMs", line.pauseMilliseconds}});
  }
  json::Object intro{
    {"enabled", settings.intro.enabled}, {"lines", std::move(lines)},
    {"charMs", settings.intro.charMilliseconds},
    {"startDelayMs", settings.intro.startDelayMilliseconds},
    {"fadeOutMs", settings.intro.fadeOutMilliseconds},
    {"rainDuringIntro", settings.intro.rainDuringIntro},
    {"postIntroDelayMs", settings.intro.postIntroDelayMilliseconds},
  };
  json::Array messages;
  for (const auto& message : settings.messages.messages) messages.emplace_back(message);
  json::Object messageDocument{
    {"messages", std::move(messages)}, {"enabled", settings.messages.enabled},
    {"frequencyMs", settings.messages.frequencyMilliseconds},
    {"persistenceMs", settings.messages.persistenceMilliseconds},
    {"appearMs", settings.messages.appearMilliseconds},
    {"disappearMs", settings.messages.disappearMilliseconds},
    {"flickerOut", settings.messages.flickerOut},
    {"brightnessFade", settings.messages.brightnessFade},
    {"messageLayout", settings.messages.layout == MessageLayout::Drop ? "drop" : "row"},
    {"messageDirection", settings.messages.direction == MessageDirection::BottomToTop
      ? "bottomToTop" : "topToBottom"},
    {"verticalPosition", settings.messages.position}, {"verticalJitter", settings.messages.jitter},
  };
  json::Array images;
  for (const auto& image : settings.images.images) {
    images.emplace_back(json::Object{{"name", image.name}, {"width", static_cast<double>(image.width)},
      {"height", static_cast<double>(image.height)}, {"data", EncodeBase64(image.luminance)}});
  }
  json::Object imageDocument{
    {"images", std::move(images)}, {"enabled", settings.images.enabled},
    {"frequencyMs", settings.images.frequencyMilliseconds},
    {"persistenceMs", settings.images.persistenceMilliseconds},
    {"appearMs", settings.images.appearMilliseconds},
    {"disappearMs", settings.images.disappearMilliseconds},
    {"flickerOut", settings.images.flickerOut},
    {"brightnessFade", settings.images.brightnessFade},
    {"imageScale", settings.images.imageScale},
    {"imagePlacementJitter", settings.images.placementJitter},
  };
  json::Array moments;
  for (const auto& moment : settings.countdown.moments) {
    moments.emplace_back(json::Object{{"name", moment.name}, {"targetMs", OptionalNumber(moment.targetMilliseconds)}});
  }
  json::Object countdown{{"targetMs", OptionalNumber(settings.countdown.targetMilliseconds)},
    {"moments", std::move(moments)}};

  return json::Value(json::Object{
    {"formatVersion", static_cast<double>(settings.formatVersion)},
    {"mx-controls", std::move(controls)}, {"mx-intro", std::move(intro)},
    {"mx-messages", std::move(messageDocument)}, {"mx-images", std::move(imageDocument)},
    {"mx-countdown", std::move(countdown)}, {"mx-user-name", settings.viewerName},
  });
}

std::optional<SettingsSnapshot> DecodeSettings(const std::string_view utf8, std::string* error) {
  const auto result = json::Parse(utf8);
  if (!result.value.has_value() || result.value->AsObject() == nullptr) {
    if (error != nullptr) *error = result.error.empty() ? "settings root must be an object" : result.error;
    return std::nullopt;
  }
  return SanitizeSettings(*result.value);
}

std::string EncodeSettingsUtf8(const SettingsSnapshot& settings, const bool pretty) {
  return json::Serialize(EncodeSettings(settings), pretty);
}

std::optional<std::vector<std::uint8_t>> DecodeBase64(const std::string_view value) {
  if (value.empty()) return std::vector<std::uint8_t>{};
  if (value.size() % 4 != 0) return std::nullopt;
  std::array<std::int16_t, 256> table{};
  table.fill(-1);
  constexpr std::string_view alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (std::size_t index = 0; index < alphabet.size(); ++index) {
    table[static_cast<unsigned char>(alphabet[index])] = static_cast<std::int16_t>(index);
  }
  std::vector<std::uint8_t> output;
  output.reserve(value.size() / 4 * 3);
  for (std::size_t offset = 0; offset < value.size(); offset += 4) {
    std::uint32_t packed = 0;
    int padding = 0;
    for (std::size_t index = 0; index < 4; ++index) {
      const unsigned char character = static_cast<unsigned char>(value[offset + index]);
      if (character == '=') {
        ++padding;
        packed <<= 6u;
      } else {
        if (padding != 0 || table[character] < 0) return std::nullopt;
        packed = (packed << 6u) | static_cast<std::uint32_t>(table[character]);
      }
    }
    if (padding > 2 || (padding != 0 && offset + 4 != value.size())) return std::nullopt;
    output.push_back(static_cast<std::uint8_t>((packed >> 16u) & 0xffu));
    if (padding < 2) output.push_back(static_cast<std::uint8_t>((packed >> 8u) & 0xffu));
    if (padding < 1) output.push_back(static_cast<std::uint8_t>(packed & 0xffu));
  }
  return output;
}

std::string EncodeBase64(const std::vector<std::uint8_t>& value) {
  constexpr char alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  output.reserve((value.size() + 2) / 3 * 4);
  for (std::size_t offset = 0; offset < value.size(); offset += 3) {
    const std::uint32_t a = value[offset];
    const std::uint32_t b = offset + 1 < value.size() ? value[offset + 1] : 0;
    const std::uint32_t c = offset + 2 < value.size() ? value[offset + 2] : 0;
    const std::uint32_t packed = (a << 16u) | (b << 8u) | c;
    output.push_back(alphabet[(packed >> 18u) & 0x3fu]);
    output.push_back(alphabet[(packed >> 12u) & 0x3fu]);
    output.push_back(offset + 1 < value.size() ? alphabet[(packed >> 6u) & 0x3fu] : '=');
    output.push_back(offset + 2 < value.size() ? alphabet[packed & 0x3fu] : '=');
  }
  return output;
}

std::string ToString(const GlyphMode mode) {
  switch (mode) {
    case GlyphMode::Katakana: return "katakana";
    case GlyphMode::Binary: return "binary";
    case GlyphMode::Digits: return "digits";
    case GlyphMode::Latin: return "latin";
    case GlyphMode::Symbols: return "symbols";
    case GlyphMode::Matrix: return "matrix";
  }
  return "matrix";
}

std::string ToString(const GlyphFont font) {
  switch (font) {
    case GlyphFont::Gothic: return "gothic";
    case GlyphFont::Mono: return "mono";
    case GlyphFont::Terminal: return "terminal";
    case GlyphFont::Rounded: return "rounded";
    case GlyphFont::Mincho: return "mincho";
    case GlyphFont::Matrix: return "matrix";
  }
  return "matrix";
}

std::string ToString(const QualityTier quality) {
  if (quality == QualityTier::Low) return "low";
  if (quality == QualityTier::Medium) return "med";
  return "high";
}

GlyphMode GlyphModeFromString(const std::string& value) {
  if (value == "katakana") return GlyphMode::Katakana;
  if (value == "binary") return GlyphMode::Binary;
  if (value == "digits") return GlyphMode::Digits;
  if (value == "latin") return GlyphMode::Latin;
  if (value == "symbols") return GlyphMode::Symbols;
  return GlyphMode::Matrix;
}

GlyphFont GlyphFontFromString(const std::string& value) {
  if (value == "gothic") return GlyphFont::Gothic;
  if (value == "mono") return GlyphFont::Mono;
  if (value == "terminal") return GlyphFont::Terminal;
  if (value == "rounded") return GlyphFont::Rounded;
  if (value == "mincho") return GlyphFont::Mincho;
  return GlyphFont::Matrix;
}

QualityTier QualityTierFromString(const std::string& value) {
  if (value == "low") return QualityTier::Low;
  if (value == "med") return QualityTier::Medium;
  return QualityTier::High;
}

ColorPalette PaletteForControls(const Controls& controls) {
  struct NamedPalette { const char* name; std::array<std::uint32_t, 5> colors; };
  constexpr std::array<NamedPalette, 9> palettes{{
    {"classic", {0x0D0208, 0x003B00, 0x008F11, 0x00FF41, 0xDEFFE4}},
    {"amber", {0x0A0600, 0x3B1E00, 0xA85B00, 0xFFB000, 0xFFF1C8}},
    {"orange", {0x0D0400, 0x3B1200, 0xA84400, 0xFF6A00, 0xFFE8D6}},
    {"gold", {0x0C0800, 0x4A3000, 0xB8860B, 0xFFD700, 0xFFF4C2}},
    {"red", {0x0D0202, 0x3B0000, 0xA80008, 0xFF2A2A, 0xFFE0E0}},
    {"pink", {0x0D0207, 0x3B0022, 0xA80060, 0xFF3DA0, 0xFFE2F1}},
    {"purple", {0x08020D, 0x2A003B, 0x6E00A8, 0xB23BFF, 0xF2E2FF}},
    {"blue", {0x02060D, 0x00263B, 0x0066A8, 0x27D6FF, 0xE4FAFF}},
    {"white", {0x060606, 0x2A2A2A, 0x8C8C8C, 0xEDEDED, 0xFFFFFF}},
  }};
  std::array<std::uint32_t, 5> colors = palettes.front().colors;
  for (const auto& palette : palettes) {
    if (controls.preset == palette.name) { colors = palette.colors; break; }
  }
  if (controls.preset == "custom") {
    std::uint32_t bright = 0x00ff41;
    if (controls.customColor.size() == 7) {
      const auto begin = controls.customColor.data() + 1;
      const auto end = controls.customColor.data() + controls.customColor.size();
      const auto parsed = std::from_chars(begin, end, bright, 16);
      if (parsed.ec != std::errc{} || parsed.ptr != end) bright = 0x00ff41;
    }
    const auto base = Rgb(bright);
    const auto scale = [](const std::array<float, 3>& color, const float factor) {
      return std::array<float, 3>{color[0] * factor, color[1] * factor, color[2] * factor};
    };
    const auto lighten = [](const std::array<float, 3>& color, const float amount) {
      return std::array<float, 3>{
        color[0] + (1.0f - color[0]) * amount,
        color[1] + (1.0f - color[1]) * amount,
        color[2] + (1.0f - color[2]) * amount,
      };
    };
    return {
      scale(base, 0.05f), scale(base, 0.23f), scale(base, 0.66f), base, lighten(base, 0.88f)};
  }
  return {Rgb(colors[0]), Rgb(colors[1]), Rgb(colors[2]), Rgb(colors[3]), Rgb(colors[4])};
}

}  // namespace matrixcode
