#include "TestHarness.h"

#include <array>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

#ifndef MATRIXCODE_LINUX_SHADER_SOURCE_DIR
#error "MATRIXCODE_LINUX_SHADER_SOURCE_DIR must name the Linux shader source directory"
#endif

#ifndef MATRIXCODE_LINUX_RESOURCE_FILE
#error "MATRIXCODE_LINUX_RESOURCE_FILE must name the Linux Qt resource manifest"
#endif

namespace {

struct ShaderContract {
  std::string_view filename;
  std::vector<std::string_view> requiredSource;
};

[[nodiscard]] std::string ReadTextFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Unable to read " + path.string());
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

void ExpectContract(const bool condition, const std::string& description) {
  matrixcode::test::Expect(condition, description.c_str(), __FILE__, __LINE__);
}

[[nodiscard]] bool IsIdentifierStart(const char value) {
  return value == '_' || std::isalpha(static_cast<unsigned char>(value)) != 0;
}

[[nodiscard]] bool IsIdentifierContinuation(const char value) {
  return value == '_' || std::isalnum(static_cast<unsigned char>(value)) != 0;
}

[[nodiscard]] std::vector<std::string> IdentifiersWithoutComments(
    const std::string& source,
    const std::string_view filename) {
  std::vector<std::string> identifiers;
  std::size_t cursor = 0;
  while (cursor < source.size()) {
    if (source[cursor] == '/' && cursor + 1 < source.size() && source[cursor + 1] == '/') {
      const std::size_t newline = source.find('\n', cursor + 2);
      cursor = newline == std::string::npos ? source.size() : newline + 1;
      continue;
    }
    if (source[cursor] == '/' && cursor + 1 < source.size() && source[cursor + 1] == '*') {
      const std::size_t terminator = source.find("*/", cursor + 2);
      ExpectContract(
        terminator != std::string::npos,
        std::string(filename) + " contains an unterminated block comment");
      cursor = terminator + 2;
      continue;
    }
    if (!IsIdentifierStart(source[cursor])) {
      ++cursor;
      continue;
    }
    const std::size_t start = cursor++;
    while (cursor < source.size() && IsIdentifierContinuation(source[cursor])) ++cursor;
    identifiers.emplace_back(source.substr(start, cursor - start));
  }
  return identifiers;
}

[[nodiscard]] std::size_t CountOccurrences(
    const std::string& source,
    const std::string_view value) {
  std::size_t count = 0;
  std::size_t offset = 0;
  while ((offset = source.find(value, offset)) != std::string::npos) {
    ++count;
    offset += value.size();
  }
  return count;
}

[[nodiscard]] bool ContainsVersionDirective(const std::string& source) {
  for (std::size_t cursor = 0; cursor < source.size(); ++cursor) {
    if (source[cursor] != '#') continue;
    std::size_t token = cursor + 1;
    while (token < source.size() &&
           (source[token] == ' ' || source[token] == '\t')) ++token;
    constexpr std::string_view version = "version";
    if (source.compare(token, version.size(), version) != 0) continue;
    const std::size_t end = token + version.size();
    if (end == source.size() || !IsIdentifierContinuation(source[end])) return true;
  }
  return false;
}

}  // namespace

void RunShaderContractTests() {
  const std::array<ShaderContract, 7> contracts{{
    {"fullscreen.vert", {
      "in vec2 position;", "out vec2 vUv;", "void main()", "gl_Position"}},
    {"glyph.frag", {
      "uniform sampler2D uState;", "uniform sampler2D uAtlas;",
      "uniform sampler2D uBrightnessBoost;", "uniform vec2 uGrid;",
      "uniform vec2 uAtlasGrid;", "uniform vec3 uTail;", "uniform vec3 uBody;",
      "uniform vec3 uBright;", "uniform vec3 uHead;", "uniform float uGoldSparkle;",
      "uniform float uLeadBrightness;", "uniform float uColOffset;",
      "uniform vec2 uOutputSize;", "uniform vec2 uLogicalPerPixel;",
      "uniform vec2 uVirtualOrigin;", "uniform float uCellPixels;"}},
    {"brightpass.frag", {"uniform sampler2D uScene;"}},
    {"blur.frag", {"uniform sampler2D uTex;", "uniform vec2 uDir;"}},
    {"copy.frag", {"uniform sampler2D uTex;"}},
    {"composite.frag", {
      "uniform sampler2D uScene;", "uniform sampler2D uBloom;",
      "uniform vec3 uBackground;", "uniform float uGlow;",
      "uniform float uScanline;", "uniform float uVignette;",
      "uniform vec2 uResolution;"}},
    {"overlay.frag", {
      "uniform sampler2D uOverlay;", "uniform vec2 uOutputSize;",
      "uniform vec2 uOverlayOrigin;", "uniform vec2 uOverlaySize;",
      "uniform float uOverlayOpacity;"}},
  }};

  const std::unordered_set<std::string_view> forbiddenIdentifiers{
    "active", "asm", "cast", "class", "common", "enum", "extern", "external",
    "double", "filter", "fixed", "fvec2", "fvec3", "fvec4", "goto", "half", "hvec2",
    "hvec3", "hvec4", "inline", "input", "interface", "long", "namespace",
    "noinline", "output", "packed", "partition", "public", "resource",
    "row_major", "sampler3DRect", "short", "sizeof", "static", "superp",
    "template", "this", "typedef", "union", "unsigned", "using"};

  const std::filesystem::path shaderDirectory{MATRIXCODE_LINUX_SHADER_SOURCE_DIR};
  std::set<std::string> expectedFiles;
  for (const ShaderContract& contract : contracts) {
    expectedFiles.emplace(contract.filename);
  }

  std::set<std::string> actualFiles;
  for (const std::filesystem::directory_entry& entry :
       std::filesystem::directory_iterator(shaderDirectory)) {
    if (!entry.is_regular_file()) continue;
    const std::string extension = entry.path().extension().string();
    if (extension == ".vert" || extension == ".frag") {
      actualFiles.emplace(entry.path().filename().string());
    }
  }
  MX_EXPECT_EQ(actualFiles, expectedFiles);

  for (const ShaderContract& contract : contracts) {
    const std::string source = ReadTextFile(shaderDirectory / contract.filename);
    ExpectContract(!source.empty(), std::string(contract.filename) + " is empty");
    ExpectContract(
      !ContainsVersionDirective(source),
      std::string(contract.filename) + " embeds a #version directive");

    if (contract.filename.ends_with(".frag")) {
      ExpectContract(
        source.find("in vec2 vUv;") != std::string::npos,
        std::string(contract.filename) + " is missing its vUv input");
      ExpectContract(
        source.find("out vec4 frag;") != std::string::npos,
        std::string(contract.filename) + " is missing its fragment output");
      ExpectContract(
        source.find("void main()") != std::string::npos,
        std::string(contract.filename) + " is missing its entry point");
    }
    for (const std::string_view required : contract.requiredSource) {
      ExpectContract(
        source.find(required) != std::string::npos,
        std::string(contract.filename) + " is missing: " + std::string(required));
    }
    for (const std::string& identifier :
         IdentifiersWithoutComments(source, contract.filename)) {
      ExpectContract(
        !forbiddenIdentifiers.contains(identifier),
        std::string(contract.filename) + " uses reserved identifier: " + identifier);
    }
  }

  const std::string resourceManifest = ReadTextFile(MATRIXCODE_LINUX_RESOURCE_FILE);
  MX_EXPECT_EQ(CountOccurrences(resourceManifest, "alias=\"shaders/"), contracts.size());
  for (const ShaderContract& contract : contracts) {
    const std::string resourceEntry =
      "<file alias=\"shaders/" + std::string(contract.filename) + "\">../shaders/" +
      std::string(contract.filename) + "</file>";
    ExpectContract(
      CountOccurrences(resourceManifest, resourceEntry) == 1,
      std::string(contract.filename) + " does not have exactly one canonical QRC alias");
  }
}
