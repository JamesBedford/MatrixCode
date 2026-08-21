#include <string>
#include <vector>

#include "TestHarness.h"
#include "matrixcode/core/Json.h"
#include "matrixcode/core/Settings.h"

void RunSettingsTests() {
  using namespace matrixcode;
  const auto defaults = DefaultSettings();
  MX_EXPECT_EQ(defaults.controls.density, 2.0);
  MX_EXPECT_EQ(defaults.intro.lines.size(), static_cast<std::size_t>(4));
  MX_EXPECT_EQ(defaults.messages.messages.size(), static_cast<std::size_t>(4));

  const std::string malformed = R"({
    "mx-controls":{"speed":999,"density":-5,"vignette":true,"quality":"bad"},
    "mx-messages":{"messages":["", "HELLO"],"frequencyMs":1},
    "mx-countdown":{"moments":[{"name":" bad:{} ","targetMs":-8}]}
  })";
  std::string error;
  const auto decoded = DecodeSettings(malformed, &error);
  MX_EXPECT(decoded.has_value());
  MX_EXPECT_EQ(decoded->controls.speed, 3.0);
  MX_EXPECT_EQ(decoded->controls.density, 0.1);
  MX_EXPECT_EQ(decoded->controls.vignette, 0.42);
  MX_EXPECT_EQ(decoded->controls.quality, QualityTier::High);
  MX_EXPECT_EQ(decoded->messages.frequencyMilliseconds, 500.0);
  MX_EXPECT_EQ(decoded->messages.messages.size(), static_cast<std::size_t>(1));
  MX_EXPECT_EQ(decoded->countdown.moments.front().name, std::string("bad"));
  MX_EXPECT_EQ(*decoded->countdown.moments.front().targetMilliseconds, 0.0);

  std::string unicodeBoundary(118, 'x');
  unicodeBoundary += "\xC3\xA9";
  const std::string tooLongUnicode = unicodeBoundary + "\xF0\x9F\x98\x80" "tail";
  const auto unicodeSettings = SanitizeSettings(json::Value(json::Object{
    {"mx-messages", json::Value(json::Object{
      {"messages", json::Value(json::Array{json::Value(tooLongUnicode)})}})}}));
  MX_EXPECT_EQ(unicodeSettings.messages.messages.size(), static_cast<std::size_t>(1));
  MX_EXPECT_EQ(unicodeSettings.messages.messages.front(), unicodeBoundary);

  json::Array invalidPrefix;
  for (std::size_t index = 0; index < 12; ++index) invalidPrefix.emplace_back(nullptr);
  json::Array introWithThirteenth = invalidPrefix;
  introWithThirteenth.emplace_back(json::Object{{"text", "must not be inspected"}});
  json::Array messagesWithThirteenth = invalidPrefix;
  messagesWithThirteenth.emplace_back("must not be inspected");
  json::Array momentsWithThirteenth = invalidPrefix;
  momentsWithThirteenth.emplace_back(json::Object{{"name", "must-not-be-inspected"}});
  const auto rawCapSettings = SanitizeSettings(json::Value(json::Object{
    {"mx-controls", json::Value(json::Object{{"customColor", "#FF0000junk"}})},
    {"mx-intro", json::Value(json::Object{{"lines", std::move(introWithThirteenth)}})},
    {"mx-messages", json::Value(json::Object{{"messages", std::move(messagesWithThirteenth)}})},
    {"mx-countdown", json::Value(json::Object{{"moments", std::move(momentsWithThirteenth)}})},
  }));
  MX_EXPECT_EQ(rawCapSettings.controls.customColor, std::string("#00FF41"));
  MX_EXPECT_EQ(rawCapSettings.intro.lines.size(), defaults.intro.lines.size());
  MX_EXPECT(rawCapSettings.messages.messages.empty());
  MX_EXPECT(rawCapSettings.countdown.moments.empty());

  const auto missingMessagesArray = SanitizeSettings(json::Value(json::Object{
    {"mx-messages", json::Value(json::Object{{"enabled", true}})},
    {"mx-countdown", json::Value(json::Object{{"moments", json::Value(json::Array{
      json::Value(json::Object{{"name", "{ launch }"}}),
    })}})},
  }));
  MX_EXPECT(missingMessagesArray.messages.messages.empty());
  MX_EXPECT_EQ(missingMessagesArray.countdown.moments.front().name, std::string("launch"));

  const auto surrogateJson = json::Parse(R"({"value":"\uD800A\uDC00/\uD83D\uDE00"})");
  MX_EXPECT(surrogateJson.value.has_value());
  MX_EXPECT_EQ(
    *surrogateJson.value->Find("value")->AsString(),
    std::string("\xEF\xBF\xBD" "A" "\xEF\xBF\xBD" "/" "\xF0\x9F\x98\x80"));

  const auto extremeNumbers = DecodeSettings(R"({
    "mx-controls":{"speed":1e400,"density":1e-4000},
    "mx-messages":{"messages":["PRESERVED"]}
  })");
  MX_EXPECT(extremeNumbers.has_value());
  MX_EXPECT_EQ(extremeNumbers->controls.speed, 1.0);
  MX_EXPECT_EQ(extremeNumbers->controls.density, 0.1);
  MX_EXPECT_EQ(extremeNumbers->messages.messages.front(), std::string("PRESERVED"));

  const auto encoded = EncodeSettingsUtf8(defaults, false);
  const auto roundTrip = DecodeSettings(encoded, &error);
  MX_EXPECT(roundTrip.has_value());
  MX_EXPECT_EQ(roundTrip->controls.customColor, std::string("#00FF41"));
  MX_EXPECT_EQ(roundTrip->intro.lines.front().text, std::string("Wake up, {name}..."));

  const std::vector<std::uint8_t> bytes{0, 1, 2, 127, 128, 255};
  const auto base64 = EncodeBase64(bytes);
  const auto restored = DecodeBase64(base64);
  MX_EXPECT(restored.has_value());
  MX_EXPECT_EQ(*restored, bytes);
  MX_EXPECT(!DecodeBase64("not base64").has_value());

  const std::string portableMask = EncodeBase64(std::vector<std::uint8_t>(96 * 96, 173));
  json::Array imageItems;
  imageItems.emplace_back(json::Object{{"width", 4.0}, {"height", 4.0}, {"data", "bad"}});
  for (int index = 0; index < 70; ++index) {
    imageItems.emplace_back(json::Object{
      {"name", " Portable image "}, {"width", 120.0}, {"height", 120.0}, {"data", portableMask}});
  }
  const auto portable = SanitizeSettings(json::Value(json::Object{
    {"mx-images", json::Value(json::Object{{"images", std::move(imageItems)}})}}));
  MX_EXPECT_EQ(portable.images.images.size(), static_cast<std::size_t>(64));
  MX_EXPECT_EQ(portable.images.images.front().width, static_cast<std::uint32_t>(96));
  MX_EXPECT_EQ(portable.images.images.front().height, static_cast<std::uint32_t>(96));
  MX_EXPECT_EQ(portable.images.images.front().name, std::string("Portable image"));

  const auto json = json::Parse(R"({"a":[true,null,"\u30cd\u30aa"],"n":1.5})");
  MX_EXPECT(json.value.has_value());
  MX_EXPECT(json.value->Find("a") != nullptr);
  MX_EXPECT(!json::Parse("{bad").value.has_value());
}
