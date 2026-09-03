#include "matrixcode/render/OpenGLRenderer.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <sstream>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <QCoreApplication>
#include <QFile>
#include <QOpenGLContext>
#include <QOpenGLExtraFunctions>
#include <QPointer>
#include <QSurfaceFormat>

#include "matrixcode/render/GlyphAtlas.h"
#include "matrixcode/render/TextOverlay.h"

namespace matrixcode::render {
namespace {

constexpr float kBlurSpread = 1.8f;
constexpr float kGoldSparkleStrength = 0.18f;

struct TargetFormat {
  GLint internalFormat = GL_RGBA8;
  GLenum format = GL_RGBA;
  GLenum type = GL_UNSIGNED_BYTE;
};

struct Target {
  GLuint framebuffer = 0;
  GLuint texture = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  TargetFormat format;
};

struct OverlayTexture {
  GLuint texture = 0;
  std::string text;
  std::array<float, 3> accent{};
  std::uint32_t outputWidth = 0;
  std::uint32_t outputHeight = 0;
  float dpiScale = 0.0f;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  float originX = 0.0f;
  float originY = 0.0f;
};

[[nodiscard]] std::string GlString(QOpenGLExtraFunctions* gl, const GLenum name) {
  const auto* value = gl == nullptr ? nullptr : gl->glGetString(name);
  return value == nullptr ? std::string{} : reinterpret_cast<const char*>(value);
}

[[nodiscard]] bool LooksSoftwareRendered(const std::string& renderer) {
  std::string lower = renderer;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](const unsigned char value) {
    return static_cast<char>(std::tolower(value));
  });
  for (const std::string_view marker : {
         "llvmpipe", "softpipe", "swrast", "software rasterizer", "swiftshader"}) {
    if (lower.find(marker) != std::string::npos) return true;
  }
  return false;
}

[[nodiscard]] QString ReadShaderBody(const QString& filename) {
  const QString resourcePath = QStringLiteral(":/matrixcode/shaders/") + filename;
  QFile resource(resourcePath);
  if (resource.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return QString::fromUtf8(resource.readAll());
  }
#if defined(MATRIXCODE_LINUX_SHADER_DIR)
  QFile configured(QStringLiteral(MATRIXCODE_LINUX_SHADER_DIR) + QLatin1Char('/') + filename);
  if (configured.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return QString::fromUtf8(configured.readAll());
  }
#endif
  const std::array<QString, 3> developmentPaths{
    QCoreApplication::applicationDirPath() + QStringLiteral("/shaders/") + filename,
    QStringLiteral("linux/MatrixCode/shaders/") + filename,
    QStringLiteral("shaders/") + filename,
  };
  for (const QString& path : developmentPaths) {
    QFile file(path);
    if (file.open(QIODevice::ReadOnly | QIODevice::Text)) return QString::fromUtf8(file.readAll());
  }
  return {};
}

[[nodiscard]] QByteArray ShaderSource(const QString& filename, const bool openGles) {
  const QString body = ReadShaderBody(filename);
  if (body.isEmpty()) return {};
  QByteArray source = openGles
    ? QByteArrayLiteral("#version 300 es\nprecision highp float;\nprecision highp int;\n")
    : QByteArrayLiteral("#version 330 core\n");
  source += body.toUtf8();
  return source;
}

[[nodiscard]] std::string HexError(const GLenum error) {
  std::ostringstream output;
  output << "OpenGL error 0x" << std::hex << static_cast<unsigned int>(error);
  return output.str();
}

}  // namespace

struct OpenGLRenderer::Impl {
  QPointer<QOpenGLContext> context;
  QOpenGLExtraFunctions* gl = nullptr;
  RendererDiagnostics diagnostics;

  GLuint vertexArray = 0;
  GLuint vertexBuffer = 0;
  GLuint glyphProgram = 0;
  GLuint brightPassProgram = 0;
  GLuint blurProgram = 0;
  GLuint copyProgram = 0;
  GLuint compositeProgram = 0;
  GLuint overlayProgram = 0;
  std::unordered_map<GLuint, std::unordered_map<std::string, GLint>> uniformLocations;

  GLuint stateTexture = 0;
  GLuint boostTexture = 0;
  std::uint32_t stateColumns = 0;
  std::uint32_t stateRows = 0;
  std::vector<float> zeroBoost;

  GLuint atlasTexture = 0;
  std::uint32_t atlasColumns = 0;
  std::uint32_t atlasRows = 0;
  GlyphMode atlasMode = GlyphMode::Matrix;
  GlyphFont atlasFont = GlyphFont::Matrix;
  bool atlasMirror = true;
  bool atlasReady = false;

  std::uint32_t outputWidth = 0;
  std::uint32_t outputHeight = 0;
  GLuint lastOutputFramebuffer = 0;
  Target scene;
  std::array<Target, 3> bloomMain;
  std::array<Target, 3> bloomTemporary;
  std::size_t bloomLevelCount = 0;

  OverlayTexture introOverlay;
  OverlayTexture hudOverlay;
  OverlayTexture toastOverlay;

  [[nodiscard]] bool IsCurrent() const noexcept {
    return context != nullptr && context->isValid() &&
      QOpenGLContext::currentContext() == context.data() && gl != nullptr;
  }

  void SetError(std::string message) {
    diagnostics.lastError = std::move(message);
  }

  void DrainErrors() noexcept {
    if (gl == nullptr) return;
    while (gl->glGetError() != GL_NO_ERROR) {}
  }

  void DeleteTarget(Target& target) noexcept {
    if (gl != nullptr && target.framebuffer != 0) gl->glDeleteFramebuffers(1, &target.framebuffer);
    if (gl != nullptr && target.texture != 0) gl->glDeleteTextures(1, &target.texture);
    target = {};
  }

  void DeleteOverlay(OverlayTexture& overlay) noexcept {
    if (gl != nullptr && overlay.texture != 0) gl->glDeleteTextures(1, &overlay.texture);
    overlay = {};
  }

  void DeleteTargets() noexcept {
    DeleteTarget(scene);
    for (Target& target : bloomMain) DeleteTarget(target);
    for (Target& target : bloomTemporary) DeleteTarget(target);
    bloomLevelCount = 0;
  }

  void DeleteResources() noexcept {
    if (IsCurrent()) {
      DeleteTargets();
      DeleteOverlay(introOverlay);
      DeleteOverlay(hudOverlay);
      DeleteOverlay(toastOverlay);
      if (stateTexture != 0) gl->glDeleteTextures(1, &stateTexture);
      if (boostTexture != 0) gl->glDeleteTextures(1, &boostTexture);
      if (atlasTexture != 0) gl->glDeleteTextures(1, &atlasTexture);
      for (const GLuint program : {
             glyphProgram, brightPassProgram, blurProgram, copyProgram, compositeProgram, overlayProgram}) {
        if (program != 0) gl->glDeleteProgram(program);
      }
      if (vertexBuffer != 0) gl->glDeleteBuffers(1, &vertexBuffer);
      if (vertexArray != 0) gl->glDeleteVertexArrays(1, &vertexArray);
    }

    vertexArray = vertexBuffer = 0;
    glyphProgram = brightPassProgram = blurProgram = copyProgram = compositeProgram = overlayProgram = 0;
    stateTexture = boostTexture = atlasTexture = 0;
    stateColumns = stateRows = atlasColumns = atlasRows = 0;
    zeroBoost.clear();
    atlasReady = false;
    scene = {};
    bloomMain = {};
    bloomTemporary = {};
    bloomLevelCount = 0;
    introOverlay = {};
    hudOverlay = {};
    toastOverlay = {};
    outputWidth = outputHeight = 0;
    lastOutputFramebuffer = 0;
    uniformLocations.clear();
    diagnostics.initialized = false;
  }

  [[nodiscard]] GLuint CompileShader(
      const GLenum kind, const QString& filename, const bool openGles) {
    const QByteArray source = ShaderSource(filename, openGles);
    if (source.isEmpty()) {
      SetError("Unable to load shader " + filename.toStdString());
      return 0;
    }
    const GLuint shader = gl->glCreateShader(kind);
    if (shader == 0) {
      SetError("Unable to create shader " + filename.toStdString());
      return 0;
    }
    const GLchar* pointer = source.constData();
    const GLint length = source.size();
    gl->glShaderSource(shader, 1, &pointer, &length);
    gl->glCompileShader(shader);
    GLint compiled = GL_FALSE;
    gl->glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_TRUE) return shader;
    GLint logLength = 0;
    gl->glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    std::vector<GLchar> log(static_cast<std::size_t>(std::max(1, logLength)), '\0');
    gl->glGetShaderInfoLog(shader, logLength, nullptr, log.data());
    SetError("Shader compile failed for " + filename.toStdString() + ": " + log.data());
    gl->glDeleteShader(shader);
    return 0;
  }

  [[nodiscard]] GLuint BuildProgram(const GLuint vertex, const QString& fragmentFilename) {
    const GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, fragmentFilename, diagnostics.openGles);
    if (fragment == 0) return 0;
    const GLuint program = gl->glCreateProgram();
    if (program == 0) {
      SetError("Unable to create shader program for " + fragmentFilename.toStdString());
      gl->glDeleteShader(fragment);
      return 0;
    }
    gl->glAttachShader(program, vertex);
    gl->glAttachShader(program, fragment);
    gl->glBindAttribLocation(program, 0, "position");
    gl->glLinkProgram(program);
    gl->glDetachShader(program, vertex);
    gl->glDetachShader(program, fragment);
    gl->glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    gl->glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked == GL_TRUE) return program;
    GLint logLength = 0;
    gl->glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
    std::vector<GLchar> log(static_cast<std::size_t>(std::max(1, logLength)), '\0');
    gl->glGetProgramInfoLog(program, logLength, nullptr, log.data());
    SetError("Shader link failed for " + fragmentFilename.toStdString() + ": " + log.data());
    gl->glDeleteProgram(program);
    return 0;
  }

  [[nodiscard]] bool CreatePrograms() {
    const GLuint vertex = CompileShader(
      GL_VERTEX_SHADER, QStringLiteral("fullscreen.vert"), diagnostics.openGles);
    if (vertex == 0) return false;
    const auto build = [this, vertex](GLuint& destination, const char* filename) {
      destination = BuildProgram(vertex, QString::fromLatin1(filename));
      return destination != 0;
    };
    const bool success =
      build(glyphProgram, "glyph.frag") &&
      build(brightPassProgram, "brightpass.frag") &&
      build(blurProgram, "blur.frag") &&
      build(copyProgram, "copy.frag") &&
      build(compositeProgram, "composite.frag") &&
      build(overlayProgram, "overlay.frag");
    gl->glDeleteShader(vertex);
    return success;
  }

  [[nodiscard]] bool CreateFullscreenTriangle() {
    constexpr std::array<GLfloat, 6> vertices{-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};
    gl->glGenVertexArrays(1, &vertexArray);
    gl->glGenBuffers(1, &vertexBuffer);
    if (vertexArray == 0 || vertexBuffer == 0) return false;
    gl->glBindVertexArray(vertexArray);
    gl->glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    gl->glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(), GL_STATIC_DRAW);
    gl->glEnableVertexAttribArray(0);
    gl->glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);
    gl->glBindBuffer(GL_ARRAY_BUFFER, 0);
    gl->glBindVertexArray(0);
    return true;
  }

  [[nodiscard]] GLint Location(const GLuint program, const char* name) {
    auto& locations = uniformLocations[program];
    const auto found = locations.find(name);
    if (found != locations.end()) return found->second;
    const GLint location = gl->glGetUniformLocation(program, name);
    locations.emplace(name, location);
    return location;
  }

  void Set1i(const GLuint program, const char* name, const GLint value) {
    const GLint location = Location(program, name);
    if (location >= 0) gl->glUniform1i(location, value);
  }

  void Set1f(const GLuint program, const char* name, const GLfloat value) {
    const GLint location = Location(program, name);
    if (location >= 0) gl->glUniform1f(location, value);
  }

  void Set2f(const GLuint program, const char* name, const GLfloat x, const GLfloat y) {
    const GLint location = Location(program, name);
    if (location >= 0) gl->glUniform2f(location, x, y);
  }

  void Set3f(const GLuint program, const char* name, const std::array<float, 3>& value) {
    const GLint location = Location(program, name);
    if (location >= 0) gl->glUniform3f(location, value[0], value[1], value[2]);
  }

  void DrawFullscreen() {
    gl->glBindVertexArray(vertexArray);
    gl->glDrawArrays(GL_TRIANGLES, 0, 3);
  }

  [[nodiscard]] Target CreateTarget(
      const std::uint32_t width,
      const std::uint32_t height,
      const TargetFormat format) {
    Target target;
    target.width = std::max(1u, width);
    target.height = std::max(1u, height);
    target.format = format;
    gl->glActiveTexture(GL_TEXTURE0);
    gl->glGenTextures(1, &target.texture);
    gl->glGenFramebuffers(1, &target.framebuffer);
    if (target.texture == 0 || target.framebuffer == 0) {
      DeleteTarget(target);
      return {};
    }
    gl->glBindTexture(GL_TEXTURE_2D, target.texture);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->glTexImage2D(
      GL_TEXTURE_2D, 0, format.internalFormat,
      static_cast<GLsizei>(target.width), static_cast<GLsizei>(target.height), 0,
      format.format, format.type, nullptr);
    gl->glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    gl->glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target.texture, 0);
    const GLenum status = gl->glCheckFramebufferStatus(GL_FRAMEBUFFER);
    const GLenum allocationError = gl->glGetError();
    if (status != GL_FRAMEBUFFER_COMPLETE || allocationError != GL_NO_ERROR) {
      DeleteTarget(target);
      DrainErrors();
      return {};
    }
    return target;
  }

  [[nodiscard]] bool BuildBloomTargets(
      const std::uint32_t sceneWidth,
      const std::uint32_t sceneHeight,
      const std::size_t levels,
      const TargetFormat format,
      std::array<Target, 3>& main,
      std::array<Target, 3>& temporary) {
    for (std::size_t level = 0; level < levels; ++level) {
      const std::uint32_t width = std::max(1u, sceneWidth >> (level + 1u));
      const std::uint32_t height = std::max(1u, sceneHeight >> (level + 1u));
      main[level] = CreateTarget(width, height, format);
      temporary[level] = CreateTarget(width, height, format);
      if (main[level].framebuffer == 0 || temporary[level].framebuffer == 0) {
        for (Target& target : main) DeleteTarget(target);
        for (Target& target : temporary) DeleteTarget(target);
        return false;
      }
    }
    return true;
  }

  [[nodiscard]] bool EnsureTargets(
      const std::uint32_t requestedWidth,
      const std::uint32_t requestedHeight,
      const std::size_t requestedLevels) {
    const std::uint32_t width = std::max(1u, requestedWidth);
    const std::uint32_t height = std::max(1u, requestedHeight);
    const std::size_t levels = std::clamp<std::size_t>(requestedLevels, 1, bloomMain.size());
    if (scene.framebuffer != 0 && scene.width == width && scene.height == height &&
        bloomLevelCount == levels) return true;

    Target nextScene = CreateTarget(width, height, {GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT});
    bool hdr = nextScene.framebuffer != 0;
    if (!hdr) nextScene = CreateTarget(width, height, {GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE});
    if (nextScene.framebuffer == 0) {
      SetError("Unable to allocate the OpenGL scene render target");
      return false;
    }

    std::array<Target, 3> nextMain;
    std::array<Target, 3> nextTemporary;
    bool packedBloom = false;
    if (hdr) {
      packedBloom = BuildBloomTargets(
        width, height, levels,
        {GL_R11F_G11F_B10F, GL_RGB, GL_HALF_FLOAT}, nextMain, nextTemporary);
      if (!packedBloom) {
        if (!BuildBloomTargets(
              width, height, levels,
              {GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT}, nextMain, nextTemporary)) {
          DeleteTarget(nextScene);
          SetError("Unable to allocate floating-point OpenGL bloom targets");
          return false;
        }
      }
    } else if (!BuildBloomTargets(
                 width, height, levels,
                 {GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE}, nextMain, nextTemporary)) {
      DeleteTarget(nextScene);
      SetError("Unable to allocate OpenGL bloom targets");
      return false;
    }

    DeleteTargets();
    scene = nextScene;
    bloomMain = nextMain;
    bloomTemporary = nextTemporary;
    bloomLevelCount = levels;
    diagnostics.hdrScene = hdr;
    diagnostics.packedFloatBloom = packedBloom;
    return true;
  }

  [[nodiscard]] bool EnsureCellTextures(const std::uint32_t columns, const std::uint32_t rows) {
    if (columns == 0 || rows == 0) return false;
    if (stateTexture == 0) gl->glGenTextures(1, &stateTexture);
    if (boostTexture == 0) gl->glGenTextures(1, &boostTexture);
    if (stateTexture == 0 || boostTexture == 0) return false;
    if (stateColumns == columns && stateRows == rows) return true;

    gl->glActiveTexture(GL_TEXTURE0);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->glBindTexture(GL_TEXTURE_2D, stateTexture);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RGBA8,
      static_cast<GLsizei>(columns), static_cast<GLsizei>(rows), 0,
      GL_RGBA, GL_UNSIGNED_BYTE, nullptr);

    gl->glBindTexture(GL_TEXTURE_2D, boostTexture);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->glTexImage2D(
      GL_TEXTURE_2D, 0, GL_R32F,
      static_cast<GLsizei>(columns), static_cast<GLsizei>(rows), 0,
      GL_RED, GL_FLOAT, nullptr);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (gl->glGetError() != GL_NO_ERROR) {
      gl->glDeleteTextures(1, &stateTexture);
      gl->glDeleteTextures(1, &boostTexture);
      stateTexture = boostTexture = 0;
      stateColumns = stateRows = 0;
      DrainErrors();
      SetError("Unable to allocate rain state textures");
      return false;
    }
    stateColumns = columns;
    stateRows = rows;
    zeroBoost.assign(static_cast<std::size_t>(columns) * rows, 0.0f);
    return true;
  }

  [[nodiscard]] bool UploadLayer(const RainLayerView& layer) {
    if (layer.columns == 0 || layer.rows == 0) return false;
    if (layer.columns > static_cast<std::uint32_t>(std::numeric_limits<GLsizei>::max()) ||
        layer.rows > static_cast<std::uint32_t>(std::numeric_limits<GLsizei>::max())) return false;
    const std::uint64_t cells = static_cast<std::uint64_t>(layer.columns) * layer.rows;
    if (cells > std::numeric_limits<std::size_t>::max() / 4u ||
        layer.state.size() != static_cast<std::size_t>(cells) * 4u) return false;
    if (!layer.brightnessBoost.empty() && layer.brightnessBoost.size() != cells) return false;
    if (!EnsureCellTextures(layer.columns, layer.rows)) return false;

    gl->glActiveTexture(GL_TEXTURE0);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->glBindTexture(GL_TEXTURE_2D, stateTexture);
    gl->glTexSubImage2D(
      GL_TEXTURE_2D, 0, 0, 0,
      static_cast<GLsizei>(layer.columns), static_cast<GLsizei>(layer.rows),
      GL_RGBA, GL_UNSIGNED_BYTE, layer.state.data());
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    gl->glBindTexture(GL_TEXTURE_2D, boostTexture);
    gl->glTexSubImage2D(
      GL_TEXTURE_2D, 0, 0, 0,
      static_cast<GLsizei>(layer.columns), static_cast<GLsizei>(layer.rows),
      GL_RED, GL_FLOAT,
      layer.brightnessBoost.empty() ? zeroBoost.data() : layer.brightnessBoost.data());
    return true;
  }

  [[nodiscard]] bool EnsureAtlas(const Controls& controls) {
    if (atlasReady && atlasMode == controls.glyphMode && atlasFont == controls.glyphFont &&
        atlasMirror == controls.mirror) return true;
    const GlyphAtlasBitmap bitmap = BuildGlyphAtlas(controls);
    if (bitmap.width == 0 || bitmap.height == 0 || bitmap.coverage.empty() ||
        bitmap.blankCellCount != 0) {
      SetError("Unable to build a complete native glyph atlas");
      return false;
    }
    GLuint nextTexture = 0;
    gl->glActiveTexture(GL_TEXTURE0);
    gl->glGenTextures(1, &nextTexture);
    if (nextTexture == 0) return false;
    gl->glBindTexture(GL_TEXTURE_2D, nextTexture);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->glTexImage2D(
      GL_TEXTURE_2D, 0, GL_R8,
      static_cast<GLsizei>(bitmap.width), static_cast<GLsizei>(bitmap.height), 0,
      GL_RED, GL_UNSIGNED_BYTE, bitmap.coverage.data());
    gl->glGenerateMipmap(GL_TEXTURE_2D);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (gl->glGetError() != GL_NO_ERROR) {
      gl->glDeleteTextures(1, &nextTexture);
      DrainErrors();
      SetError("Unable to upload the native glyph atlas");
      return false;
    }
    if (atlasTexture != 0) gl->glDeleteTextures(1, &atlasTexture);
    atlasTexture = nextTexture;
    atlasColumns = bitmap.columns;
    atlasRows = bitmap.rows;
    atlasMode = controls.glyphMode;
    atlasFont = controls.glyphFont;
    atlasMirror = controls.mirror;
    atlasReady = true;
    return true;
  }

  [[nodiscard]] bool EnsureOverlayTexture(
      OverlayTexture& cache,
      const TextOverlayBitmap& bitmap,
      const std::string_view text,
      const std::uint32_t requestedOutputWidth,
      const std::uint32_t requestedOutputHeight,
      const float requestedDpiScale,
      const std::array<float, 3>& accent) {
    if (bitmap.width == 0 || bitmap.height == 0 ||
        bitmap.rgba.size() != static_cast<std::size_t>(bitmap.width) * bitmap.height * 4u) return false;
    if (cache.texture == 0) gl->glGenTextures(1, &cache.texture);
    if (cache.texture == 0) return false;
    gl->glActiveTexture(GL_TEXTURE0);
    gl->glBindTexture(GL_TEXTURE_2D, cache.texture);
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RGBA8,
      static_cast<GLsizei>(bitmap.width), static_cast<GLsizei>(bitmap.height), 0,
      GL_RGBA, GL_UNSIGNED_BYTE, bitmap.rgba.data());
    gl->glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (gl->glGetError() != GL_NO_ERROR) {
      DrainErrors();
      return false;
    }
    cache.text = text;
    cache.accent = accent;
    cache.outputWidth = requestedOutputWidth;
    cache.outputHeight = requestedOutputHeight;
    cache.dpiScale = requestedDpiScale;
    cache.width = bitmap.width;
    cache.height = bitmap.height;
    cache.originX = bitmap.originX;
    cache.originY = bitmap.originY;
    return true;
  }

  [[nodiscard]] bool EnsureIntroOverlay(
      const FrameParameters& parameters, const float dpiScale) {
    if (parameters.overlayText.empty()) return false;
    if (introOverlay.texture != 0 && introOverlay.text == parameters.overlayText &&
        introOverlay.outputWidth == outputWidth && introOverlay.outputHeight == outputHeight &&
        introOverlay.dpiScale == dpiScale && introOverlay.accent == parameters.palette.bright) return true;
    return EnsureOverlayTexture(
      introOverlay,
      BuildIntroOverlayBitmap(
        parameters.overlayText, outputWidth, outputHeight, dpiScale, parameters.palette.bright),
      parameters.overlayText, outputWidth, outputHeight, dpiScale, parameters.palette.bright);
  }

  [[nodiscard]] bool EnsureHudOverlay(const FrameParameters& parameters, const float dpiScale) {
    if (parameters.hudText.empty()) return false;
    if (hudOverlay.texture != 0 && hudOverlay.text == parameters.hudText &&
        hudOverlay.outputWidth == outputWidth && hudOverlay.outputHeight == outputHeight &&
        hudOverlay.dpiScale == dpiScale) return true;
    constexpr std::array<float, 3> hudAccent{0.0f, 1.0f, 65.0f / 255.0f};
    return EnsureOverlayTexture(
      hudOverlay,
      BuildHudOverlayBitmap(parameters.hudText, outputWidth, outputHeight, dpiScale),
      parameters.hudText, outputWidth, outputHeight, dpiScale, hudAccent);
  }

  [[nodiscard]] bool EnsureToastOverlay(const FrameParameters& parameters, const float dpiScale) {
    if (parameters.toastText.empty()) return false;
    if (toastOverlay.texture != 0 && toastOverlay.text == parameters.toastText &&
        toastOverlay.outputWidth == outputWidth && toastOverlay.outputHeight == outputHeight &&
        toastOverlay.dpiScale == dpiScale && toastOverlay.accent == parameters.palette.bright) return true;
    return EnsureOverlayTexture(
      toastOverlay,
      BuildToastOverlayBitmap(
        parameters.toastText, outputWidth, outputHeight, dpiScale, parameters.palette.bright),
      parameters.toastText, outputWidth, outputHeight, dpiScale, parameters.palette.bright);
  }

  void BindTexture(const GLenum unit, const GLuint texture) {
    gl->glActiveTexture(unit);
    gl->glBindTexture(GL_TEXTURE_2D, texture);
  }

  void RunTexturePass(
      const GLuint program,
      const Target& input,
      const Target& output,
      const char* samplerName,
      const float directionX = 0.0f,
      const float directionY = 0.0f) {
    gl->glBindFramebuffer(GL_FRAMEBUFFER, output.framebuffer);
    gl->glViewport(0, 0, static_cast<GLsizei>(output.width), static_cast<GLsizei>(output.height));
    gl->glDisable(GL_BLEND);
    gl->glUseProgram(program);
    BindTexture(GL_TEXTURE0, input.texture);
    Set1i(program, samplerName, 0);
    Set2f(program, "uDir", directionX, directionY);
    DrawFullscreen();
  }

  void DrawOverlay(const OverlayTexture& overlay, const float opacity, const float yOffset) {
    if (overlay.texture == 0 || opacity <= 0.0f) return;
    gl->glUseProgram(overlayProgram);
    BindTexture(GL_TEXTURE0, overlay.texture);
    Set1i(overlayProgram, "uOverlay", 0);
    Set2f(overlayProgram, "uOutputSize", static_cast<float>(outputWidth), static_cast<float>(outputHeight));
    Set2f(overlayProgram, "uOverlayOrigin", overlay.originX, overlay.originY + yOffset);
    Set2f(overlayProgram, "uOverlaySize", static_cast<float>(overlay.width), static_cast<float>(overlay.height));
    Set1f(overlayProgram, "uOverlayOpacity", std::clamp(opacity, 0.0f, 1.0f));
    gl->glEnable(GL_BLEND);
    gl->glBlendEquation(GL_FUNC_ADD);
    gl->glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    DrawFullscreen();
    gl->glDisable(GL_BLEND);
  }
};

OpenGLRenderer::OpenGLRenderer() : impl_(std::make_unique<Impl>()) {}

OpenGLRenderer::~OpenGLRenderer() {
  if (impl_ != nullptr && impl_->IsCurrent()) impl_->DeleteResources();
}

bool OpenGLRenderer::Initialize(QOpenGLContext* context) {
  if (context == nullptr || QOpenGLContext::currentContext() != context) {
    impl_->SetError("OpenGLRenderer::Initialize requires the supplied context to be current");
    return false;
  }
  if (impl_->diagnostics.initialized && impl_->context == context) return true;
  if (impl_->IsCurrent()) impl_->DeleteResources();
  impl_ = std::make_unique<Impl>();
  impl_->context = context;
  impl_->gl = context->extraFunctions();
  if (impl_->gl == nullptr) {
    impl_->SetError("Qt could not initialize the OpenGL function table");
    return false;
  }
  impl_->gl->initializeOpenGLFunctions();

  const QSurfaceFormat format = context->format();
  impl_->diagnostics.openGles = context->isOpenGLES();
  const bool versionSupported = impl_->diagnostics.openGles
    ? format.majorVersion() >= 3
    : format.majorVersion() > 3 || (format.majorVersion() == 3 && format.minorVersion() >= 3);
  if (!versionSupported) {
    impl_->SetError("Matrix Code requires OpenGL 3.3 Core or OpenGL ES 3.0");
    return false;
  }
  impl_->diagnostics.vendor = GlString(impl_->gl, GL_VENDOR);
  impl_->diagnostics.renderer = GlString(impl_->gl, GL_RENDERER);
  impl_->diagnostics.version = GlString(impl_->gl, GL_VERSION);
  impl_->diagnostics.shadingLanguageVersion = GlString(impl_->gl, GL_SHADING_LANGUAGE_VERSION);
  GLint maximumTextureSize = 0;
  impl_->gl->glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximumTextureSize);
  if (maximumTextureSize <= 0) {
    impl_->SetError("OpenGL did not report a usable maximum texture size");
    return false;
  }
  impl_->diagnostics.maximumTextureSize = static_cast<std::uint32_t>(maximumTextureSize);
  impl_->diagnostics.deviceKind = LooksSoftwareRendered(impl_->diagnostics.renderer)
    ? DeviceKind::Software
    : DeviceKind::Hardware;

  if (!impl_->CreateFullscreenTriangle() || !impl_->CreatePrograms()) {
    if (impl_->diagnostics.lastError.empty()) {
      impl_->SetError("Unable to create the OpenGL render pipeline");
    }
    impl_->DeleteResources();
    return false;
  }
  impl_->gl->glDisable(GL_DEPTH_TEST);
  impl_->gl->glDisable(GL_CULL_FACE);
  impl_->diagnostics.initialized = true;
  impl_->diagnostics.lastError.clear();
  return true;
}

void OpenGLRenderer::Cleanup() noexcept {
  if (impl_ != nullptr) impl_->DeleteResources();
}

bool OpenGLRenderer::Resize(
    const std::uint32_t backingWidth, const std::uint32_t backingHeight) {
  if (!impl_->IsCurrent() || !impl_->diagnostics.initialized ||
      backingWidth == 0 || backingHeight == 0) return false;
  if (impl_->outputWidth == backingWidth && impl_->outputHeight == backingHeight) return true;
  impl_->outputWidth = backingWidth;
  impl_->outputHeight = backingHeight;
  impl_->DeleteTargets();
  return true;
}

bool OpenGLRenderer::Render(
    const std::span<const RainLayerView> layers,
    const FrameParameters& parameters,
    const std::uint32_t outputFramebuffer) {
  if (!impl_->IsCurrent() || !impl_->diagnostics.initialized || layers.empty() ||
      impl_->outputWidth == 0 || impl_->outputHeight == 0) return false;

  struct OutputFramebufferGuard {
    Impl* renderer = nullptr;
    GLuint framebuffer = 0;
    ~OutputFramebufferGuard() {
      if (renderer != nullptr && renderer->IsCurrent()) {
        renderer->gl->glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
      }
    }
  } outputGuard{impl_.get(), outputFramebuffer};

  impl_->DrainErrors();
  impl_->gl->glDisable(GL_DEPTH_TEST);
  impl_->gl->glDisable(GL_CULL_FACE);
  impl_->gl->glDisable(GL_SCISSOR_TEST);
  impl_->gl->glDisable(GL_STENCIL_TEST);
  impl_->gl->glEnable(GL_DITHER);
  impl_->gl->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  if (!impl_->EnsureAtlas(parameters.controls)) return false;

  const float adaptiveScale = std::isfinite(parameters.adaptiveScale)
    ? std::clamp(parameters.adaptiveScale, 0.5f, 1.0f)
    : 1.0f;
  const std::uint32_t sceneWidth = std::min(
    impl_->diagnostics.maximumTextureSize,
    std::max(1u, static_cast<std::uint32_t>(std::floor(impl_->outputWidth * adaptiveScale))));
  const std::uint32_t sceneHeight = std::min(
    impl_->diagnostics.maximumTextureSize,
    std::max(1u, static_cast<std::uint32_t>(std::floor(impl_->outputHeight * adaptiveScale))));
  const std::size_t bloomLevels = parameters.controls.quality == QualityTier::Low ? 1u :
    parameters.controls.quality == QualityTier::Medium ? 2u : 3u;
  if (!impl_->EnsureTargets(sceneWidth, sceneHeight, bloomLevels)) return false;

  impl_->gl->glBindFramebuffer(GL_FRAMEBUFFER, impl_->scene.framebuffer);
  impl_->gl->glViewport(0, 0, static_cast<GLsizei>(sceneWidth), static_cast<GLsizei>(sceneHeight));
  impl_->gl->glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  impl_->gl->glClear(GL_COLOR_BUFFER_BIT);
  impl_->gl->glEnable(GL_BLEND);
  impl_->gl->glBlendEquation(GL_FUNC_ADD);
  impl_->gl->glBlendFunc(GL_ONE, GL_ONE);

  impl_->gl->glUseProgram(impl_->glyphProgram);
  impl_->Set1i(impl_->glyphProgram, "uState", 0);
  impl_->Set1i(impl_->glyphProgram, "uAtlas", 1);
  impl_->Set1i(impl_->glyphProgram, "uBrightnessBoost", 2);
  impl_->Set2f(
    impl_->glyphProgram, "uOutputSize",
    static_cast<float>(impl_->outputWidth), static_cast<float>(impl_->outputHeight));
  impl_->Set2f(
    impl_->glyphProgram, "uLogicalPerPixel",
    std::max(0.001f, parameters.logicalPerPixelX),
    std::max(0.001f, parameters.logicalPerPixelY));
  impl_->Set2f(
    impl_->glyphProgram, "uVirtualOrigin", parameters.virtualOriginX, parameters.virtualOriginY);
  impl_->Set2f(
    impl_->glyphProgram, "uAtlasGrid",
    static_cast<float>(impl_->atlasColumns), static_cast<float>(impl_->atlasRows));
  impl_->Set1f(impl_->glyphProgram, "uCellPixels", std::max(0.001f, parameters.cellPixels));
  impl_->Set1f(
    impl_->glyphProgram, "uLeadBrightness", static_cast<float>(parameters.controls.leadBrightness));
  impl_->Set1f(
    impl_->glyphProgram, "uGoldSparkle",
    parameters.controls.preset == "gold" ? kGoldSparkleStrength : 0.0f);
  impl_->Set3f(impl_->glyphProgram, "uTail", parameters.palette.tail);
  impl_->Set3f(impl_->glyphProgram, "uBody", parameters.palette.body);
  impl_->Set3f(impl_->glyphProgram, "uBright", parameters.palette.bright);
  impl_->Set3f(impl_->glyphProgram, "uHead", parameters.palette.head);

  std::size_t renderedLayers = 0;
  for (const RainLayerView& layer : layers) {
    if (layer.weight <= 0.0f || !impl_->UploadLayer(layer)) continue;
    impl_->BindTexture(GL_TEXTURE0, impl_->stateTexture);
    impl_->BindTexture(GL_TEXTURE1, impl_->atlasTexture);
    impl_->BindTexture(GL_TEXTURE2, impl_->boostTexture);
    impl_->Set2f(
      impl_->glyphProgram, "uGrid", static_cast<float>(layer.columns), static_cast<float>(layer.rows));
    impl_->Set1f(impl_->glyphProgram, "uColOffset", layer.offsetCells);
    impl_->DrawFullscreen();
    ++renderedLayers;
  }
  impl_->gl->glDisable(GL_BLEND);
  if (renderedLayers == 0) {
    impl_->SetError("No valid rain layer was supplied to the OpenGL renderer");
    return false;
  }

  impl_->RunTexturePass(
    impl_->brightPassProgram, impl_->scene, impl_->bloomMain[0], "uScene");
  for (std::size_t level = 0; level < impl_->bloomLevelCount; ++level) {
    Target& main = impl_->bloomMain[level];
    Target& temporary = impl_->bloomTemporary[level];
    impl_->RunTexturePass(
      impl_->blurProgram, main, temporary, "uTex", kBlurSpread / main.width, 0.0f);
    impl_->RunTexturePass(
      impl_->blurProgram, temporary, main, "uTex", 0.0f, kBlurSpread / main.height);
    if (level + 1 < impl_->bloomLevelCount) {
      impl_->RunTexturePass(
        impl_->copyProgram, main, impl_->bloomMain[level + 1], "uTex");
    }
  }

  impl_->gl->glEnable(GL_BLEND);
  impl_->gl->glBlendEquation(GL_FUNC_ADD);
  impl_->gl->glBlendFunc(GL_ONE, GL_ONE);
  for (std::size_t level = impl_->bloomLevelCount; level > 1; --level) {
    Target& input = impl_->bloomMain[level - 1];
    Target& output = impl_->bloomMain[level - 2];
    impl_->gl->glBindFramebuffer(GL_FRAMEBUFFER, output.framebuffer);
    impl_->gl->glViewport(0, 0, static_cast<GLsizei>(output.width), static_cast<GLsizei>(output.height));
    impl_->gl->glUseProgram(impl_->copyProgram);
    impl_->BindTexture(GL_TEXTURE0, input.texture);
    impl_->Set1i(impl_->copyProgram, "uTex", 0);
    impl_->DrawFullscreen();
  }
  impl_->gl->glDisable(GL_BLEND);

  impl_->gl->glBindFramebuffer(GL_FRAMEBUFFER, outputFramebuffer);
  impl_->gl->glViewport(
    0, 0, static_cast<GLsizei>(impl_->outputWidth), static_cast<GLsizei>(impl_->outputHeight));
  impl_->gl->glUseProgram(impl_->compositeProgram);
  impl_->BindTexture(GL_TEXTURE0, impl_->scene.texture);
  impl_->BindTexture(GL_TEXTURE1, impl_->bloomMain[0].texture);
  impl_->Set1i(impl_->compositeProgram, "uScene", 0);
  impl_->Set1i(impl_->compositeProgram, "uBloom", 1);
  impl_->Set3f(impl_->compositeProgram, "uBackground", parameters.palette.background);
  impl_->Set1f(impl_->compositeProgram, "uGlow", static_cast<float>(parameters.controls.glow));
  impl_->Set1f(
    impl_->compositeProgram, "uScanline", parameters.controls.scanlines ? 0.12f : 0.0f);
  impl_->Set1f(
    impl_->compositeProgram, "uVignette", static_cast<float>(parameters.controls.vignette));
  impl_->Set2f(
    impl_->compositeProgram, "uResolution",
    static_cast<float>(impl_->outputWidth), static_cast<float>(impl_->outputHeight));
  impl_->DrawFullscreen();

  const float overlayDpiScale = std::clamp(
    1.0f / std::max(0.001f, parameters.logicalPerPixelX), 0.5f, 8.0f);
  if (parameters.overlayOpacity > 0.0f && impl_->EnsureIntroOverlay(parameters, overlayDpiScale)) {
    impl_->DrawOverlay(impl_->introOverlay, parameters.overlayOpacity, 0.0f);
  }
  if (parameters.toastOpacity > 0.0f && impl_->EnsureToastOverlay(parameters, overlayDpiScale)) {
    impl_->DrawOverlay(
      impl_->toastOverlay, parameters.toastOpacity,
      parameters.toastOffsetDips * overlayDpiScale);
  }
  if (!parameters.hudText.empty() && impl_->EnsureHudOverlay(parameters, overlayDpiScale)) {
    impl_->DrawOverlay(impl_->hudOverlay, 1.0f, 0.0f);
  }

  impl_->lastOutputFramebuffer = outputFramebuffer;
  impl_->gl->glBindVertexArray(0);
  impl_->gl->glUseProgram(0);
  impl_->gl->glActiveTexture(GL_TEXTURE0);
  impl_->gl->glBindTexture(GL_TEXTURE_2D, 0);
  const GLenum error = impl_->gl->glGetError();
  if (error != GL_NO_ERROR) {
    impl_->SetError(HexError(error));
    return false;
  }
  impl_->diagnostics.lastError.clear();
  return true;
}

QImage OpenGLRenderer::CaptureFrame() const {
  if (!impl_->IsCurrent() || !impl_->diagnostics.initialized ||
      impl_->outputWidth == 0 || impl_->outputHeight == 0) return {};
  QImage image(
    static_cast<int>(impl_->outputWidth),
    static_cast<int>(impl_->outputHeight),
    QImage::Format_RGBA8888);
  if (image.isNull()) return {};
  impl_->DrainErrors();
  GLint previousReadFramebuffer = 0;
  GLint previousPackAlignment = 4;
  impl_->gl->glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
  impl_->gl->glGetIntegerv(GL_PACK_ALIGNMENT, &previousPackAlignment);
  impl_->gl->glBindFramebuffer(GL_READ_FRAMEBUFFER, impl_->lastOutputFramebuffer);
  impl_->gl->glPixelStorei(GL_PACK_ALIGNMENT, 1);
  impl_->gl->glReadPixels(
    0, 0,
    static_cast<GLsizei>(impl_->outputWidth), static_cast<GLsizei>(impl_->outputHeight),
    GL_RGBA, GL_UNSIGNED_BYTE, image.bits());
  impl_->gl->glPixelStorei(GL_PACK_ALIGNMENT, previousPackAlignment);
  impl_->gl->glBindFramebuffer(
    GL_READ_FRAMEBUFFER, static_cast<GLuint>(previousReadFramebuffer));
  return impl_->gl->glGetError() == GL_NO_ERROR ? image.mirrored(false, true) : QImage{};
}

bool OpenGLRenderer::IsInitialized() const noexcept {
  return impl_ != nullptr && impl_->diagnostics.initialized;
}

const RendererDiagnostics& OpenGLRenderer::Diagnostics() const noexcept {
  return impl_->diagnostics;
}

}  // namespace matrixcode::render
