#include "matrixcode/render/D3D11Renderer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <sstream>
#include <string_view>
#include <utility>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_3.h>
#include <wincodec.h>
#include <wrl/client.h>

#include "EmbeddedShader.h"
#include "matrixcode/core/GlyphSet.h"
#include "matrixcode/core/Utf8.h"
#include "matrixcode/render/GlyphAtlas.h"
#include "matrixcode/render/IntroOverlay.h"

namespace matrixcode::render {
namespace {

using Microsoft::WRL::ComPtr;

struct Target {
  ComPtr<ID3D11Texture2D> texture;
  ComPtr<ID3D11RenderTargetView> target;
  ComPtr<ID3D11ShaderResourceView> resource;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

struct alignas(16) GlyphConstants {
  float sceneSize[2]{};
  float virtualOrigin[2]{};
  float logicalPerPixel[2]{1.0f, 1.0f};
  float gridSize[2]{};
  float cellPixels = 18.0f;
  float laneOffset = 0.0f;
  float laneWeight = 1.0f;
  float leadBrightness = 1.6f;
  float goldSparkle = 0.0f;
  float elapsedSeconds = 0.0f;
  float padAlignment[2]{};
  float background[3]{};
  float pad0 = 0.0f;
  float tail[3]{};
  float pad1 = 0.0f;
  float body[3]{};
  float pad2 = 0.0f;
  float bright[3]{};
  float pad3 = 0.0f;
  float head[3]{};
  float pad4 = 0.0f;
};

struct alignas(16) PostConstants {
  float sourceTexel[2]{};
  float outputSize[2]{};
  float glow = 0.9f;
  float vignette = 0.0f;
  float scanlines = 0.0f;
  float bloomLevels = 3.0f;
  float background[3]{};
  float pad = 0.0f;
};

struct alignas(16) OverlayConstants {
  float origin[2]{};
  float size[2]{};
  float opacity = 0.0f;
  float padding[3]{};
};

[[nodiscard]] bool CreateTarget(
    ID3D11Device* device,
    const std::uint32_t width,
    const std::uint32_t height,
    const DXGI_FORMAT format,
    Target& output) {
  D3D11_TEXTURE2D_DESC description{};
  description.Width = std::max(1u, width);
  description.Height = std::max(1u, height);
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = format;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  Target target;
  if (FAILED(device->CreateTexture2D(&description, nullptr, &target.texture)) ||
      FAILED(device->CreateRenderTargetView(target.texture.Get(), nullptr, &target.target)) ||
      FAILED(device->CreateShaderResourceView(target.texture.Get(), nullptr, &target.resource))) {
    return false;
  }
  target.width = description.Width;
  target.height = description.Height;
  output = std::move(target);
  return true;
}

[[nodiscard]] ComPtr<ID3DBlob> CompileShader(
    const char* entryPoint, const char* target, std::string& diagnostics) {
  UINT flags = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_WARNINGS_ARE_ERRORS;
#if defined(_DEBUG)
  flags |= D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
#else
  flags |= D3DCOMPILE_OPTIMIZATION_LEVEL3;
#endif
  ComPtr<ID3DBlob> code;
  ComPtr<ID3DBlob> errors;
  const HRESULT result = D3DCompile(
    kMatrixCodeShaderSource,
    std::strlen(kMatrixCodeShaderSource),
    "MatrixCode.hlsl",
    nullptr,
    nullptr,
    entryPoint,
    target,
    flags,
    0,
    &code,
    &errors);
  if (errors != nullptr && errors->GetBufferSize() > 0) {
    diagnostics.append(
      static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize());
    OutputDebugStringA(diagnostics.c_str());
  }
  return SUCCEEDED(result) ? code : nullptr;
}

template <typename T>
[[nodiscard]] bool CreateConstantBuffer(ID3D11Device* device, ComPtr<ID3D11Buffer>& output) {
  static_assert(sizeof(T) % 16 == 0);
  D3D11_BUFFER_DESC description{};
  description.ByteWidth = static_cast<UINT>(sizeof(T));
  description.Usage = D3D11_USAGE_DYNAMIC;
  description.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  description.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  return SUCCEEDED(device->CreateBuffer(&description, nullptr, &output));
}

template <typename T>
void UpdateConstant(ID3D11DeviceContext* context, ID3D11Buffer* buffer, const T& value) {
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (SUCCEEDED(context->Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
    std::memcpy(mapped.pData, &value, sizeof(value));
    context->Unmap(buffer, 0);
  }
}

void SetViewport(ID3D11DeviceContext* context, const std::uint32_t width, const std::uint32_t height) {
  const D3D11_VIEWPORT viewport{
    0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f};
  context->RSSetViewports(1, &viewport);
}

void UnbindResources(ID3D11DeviceContext* context) {
  std::array<ID3D11ShaderResourceView*, 4> empty{};
  context->PSSetShaderResources(0, static_cast<UINT>(empty.size()), empty.data());
}

}  // namespace

struct D3D11Renderer::Impl {
  HWND window = nullptr;
  DeviceKind kind = DeviceKind::Hardware;
  HRESULT lastError = S_OK;
  std::string shaderDiagnostics;
  bool suspended = false;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t sceneWidth = 0;
  std::uint32_t sceneHeight = 0;
  bool captureEnabled = false;

  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGISwapChain1> swapChain;
  ComPtr<IDXGISwapChain2> swapChain2;
  ComPtr<ID3D11Texture2D> backBufferTexture;
  ComPtr<ID3D11RenderTargetView> backBufferTarget;
  ComPtr<ID3D11Texture2D> captureTexture;

  ComPtr<ID3D11VertexShader> fullscreenVertex;
  ComPtr<ID3D11PixelShader> glyphPixel;
  ComPtr<ID3D11PixelShader> brightPassPixel;
  ComPtr<ID3D11PixelShader> copyPixel;
  ComPtr<ID3D11PixelShader> blurHorizontalPixel;
  ComPtr<ID3D11PixelShader> blurVerticalPixel;
  ComPtr<ID3D11PixelShader> compositePixel;
  ComPtr<ID3D11PixelShader> overlayPixel;
  ComPtr<ID3D11Buffer> glyphConstants;
  ComPtr<ID3D11Buffer> postConstants;
  ComPtr<ID3D11Buffer> overlayConstants;
  ComPtr<ID3D11SamplerState> pointSampler;
  ComPtr<ID3D11SamplerState> linearSampler;
  ComPtr<ID3D11BlendState> additiveBlend;
  ComPtr<ID3D11BlendState> alphaBlend;
  ComPtr<ID3D11BlendState> opaqueBlend;

  ComPtr<ID3D11Texture2D> stateTexture;
  ComPtr<ID3D11ShaderResourceView> stateResource;
  ComPtr<ID3D11Texture2D> boostTexture;
  ComPtr<ID3D11ShaderResourceView> boostResource;
  std::uint32_t stateColumns = 0;
  std::uint32_t stateRows = 0;
  ComPtr<ID3D11Texture2D> atlasTexture;
  ComPtr<ID3D11ShaderResourceView> atlasResource;
  GlyphMode atlasMode = GlyphMode::Matrix;
  GlyphFont atlasFont = GlyphFont::Matrix;
  bool atlasMirror = true;
  ComPtr<ID3D11Texture2D> overlayTexture;
  ComPtr<ID3D11ShaderResourceView> overlayResource;
  std::string overlayText;
  std::array<float, 3> overlayAccent{};
  std::uint32_t overlayOutputWidth = 0;
  std::uint32_t overlayOutputHeight = 0;
  float overlayDpiScale = 0.0f;
  std::uint32_t overlayWidth = 0;
  std::uint32_t overlayHeight = 0;
  float overlayOriginX = 0.0f;
  float overlayOriginY = 0.0f;
  ComPtr<ID3D11Texture2D> hudTexture;
  ComPtr<ID3D11ShaderResourceView> hudResource;
  std::string hudText;
  std::uint32_t hudOutputWidth = 0;
  std::uint32_t hudOutputHeight = 0;
  float hudDpiScale = 0.0f;
  std::uint32_t hudWidth = 0;
  std::uint32_t hudHeight = 0;
  float hudOriginX = 0.0f;
  float hudOriginY = 0.0f;
  ComPtr<ID3D11Texture2D> toastTexture;
  ComPtr<ID3D11ShaderResourceView> toastResource;
  std::string toastText;
  std::array<float, 3> toastAccent{};
  std::uint32_t toastOutputWidth = 0;
  std::uint32_t toastOutputHeight = 0;
  float toastDpiScale = 0.0f;
  std::uint32_t toastWidth = 0;
  std::uint32_t toastHeight = 0;
  float toastOriginX = 0.0f;
  float toastOriginY = 0.0f;

  Target scene;
  std::array<Target, 3> bloomA;
  std::array<Target, 3> bloomB;

  [[nodiscard]] bool CreateDevice(const bool forceWarp) {
    constexpr std::array<D3D_FEATURE_LEVEL, 4> levels{
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
    };
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(_DEBUG)
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
    D3D_FEATURE_LEVEL selected{};
    auto create = [&](const D3D_DRIVER_TYPE driver, const UINT createFlags) {
      return D3D11CreateDevice(
        nullptr, driver, nullptr, createFlags, levels.data(), static_cast<UINT>(levels.size()),
        D3D11_SDK_VERSION, &device, &selected, &context);
    };
    lastError = create(forceWarp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE, flags);
#if defined(_DEBUG)
    if (lastError == DXGI_ERROR_SDK_COMPONENT_MISSING) {
      lastError = create(forceWarp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
        flags & ~D3D11_CREATE_DEVICE_DEBUG);
    }
#endif
    if (FAILED(lastError) && !forceWarp) {
      device.Reset();
      context.Reset();
      lastError = create(D3D_DRIVER_TYPE_WARP, flags & ~D3D11_CREATE_DEVICE_DEBUG);
      kind = DeviceKind::Warp;
    } else {
      kind = forceWarp ? DeviceKind::Warp : DeviceKind::Hardware;
    }
    return SUCCEEDED(lastError);
  }

  [[nodiscard]] bool CreateSwapChain() {
    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    if (FAILED(device.As(&dxgiDevice)) || FAILED(dxgiDevice->GetAdapter(&adapter)) ||
        FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;
    DXGI_SWAP_CHAIN_DESC1 description{};
    description.Width = width;
    description.Height = height;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    description.BufferCount = 2;
    description.Scaling = DXGI_SCALING_STRETCH;
    description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    description.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    lastError = factory->CreateSwapChainForHwnd(
      device.Get(), window, &description, nullptr, nullptr, &swapChain);
    if (FAILED(lastError)) return false;
    factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
    if (SUCCEEDED(swapChain.As(&swapChain2))) swapChain2->SetMaximumFrameLatency(1);
    return CreateBackBuffer();
  }

  [[nodiscard]] bool CreateBackBuffer() {
    backBufferTexture.Reset();
    captureTexture.Reset();
    lastError = swapChain->GetBuffer(0, IID_PPV_ARGS(&backBufferTexture));
    if (FAILED(lastError)) return false;
    lastError = device->CreateRenderTargetView(backBufferTexture.Get(), nullptr, &backBufferTarget);
    if (FAILED(lastError)) return false;
    D3D11_TEXTURE2D_DESC description{};
    backBufferTexture->GetDesc(&description);
    if (!captureEnabled) return true;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = 0;
    description.CPUAccessFlags = 0;
    description.MiscFlags = 0;
    lastError = device->CreateTexture2D(&description, nullptr, &captureTexture);
    return SUCCEEDED(lastError);
  }

  [[nodiscard]] bool CreateShadersAndStates() {
    const auto vertex = CompileShader("FullscreenVs", "vs_5_0", shaderDiagnostics);
    const auto glyph = CompileShader("GlyphPs", "ps_5_0", shaderDiagnostics);
    const auto brightPass = CompileShader("BrightPassPs", "ps_5_0", shaderDiagnostics);
    const auto copy = CompileShader("CopyPs", "ps_5_0", shaderDiagnostics);
    const auto blurH = CompileShader("BlurHPs", "ps_5_0", shaderDiagnostics);
    const auto blurV = CompileShader("BlurVPs", "ps_5_0", shaderDiagnostics);
    const auto composite = CompileShader("CompositePs", "ps_5_0", shaderDiagnostics);
    const auto overlay = CompileShader("OverlayPs", "ps_5_0", shaderDiagnostics);
    if (vertex == nullptr || glyph == nullptr || brightPass == nullptr || copy == nullptr || blurH == nullptr ||
        blurV == nullptr || composite == nullptr || overlay == nullptr) return false;
    if (FAILED(device->CreateVertexShader(
          vertex->GetBufferPointer(), vertex->GetBufferSize(), nullptr, &fullscreenVertex)) ||
        FAILED(device->CreatePixelShader(
          glyph->GetBufferPointer(), glyph->GetBufferSize(), nullptr, &glyphPixel)) ||
        FAILED(device->CreatePixelShader(
          brightPass->GetBufferPointer(), brightPass->GetBufferSize(), nullptr, &brightPassPixel)) ||
        FAILED(device->CreatePixelShader(
          copy->GetBufferPointer(), copy->GetBufferSize(), nullptr, &copyPixel)) ||
        FAILED(device->CreatePixelShader(
          blurH->GetBufferPointer(), blurH->GetBufferSize(), nullptr, &blurHorizontalPixel)) ||
        FAILED(device->CreatePixelShader(
          blurV->GetBufferPointer(), blurV->GetBufferSize(), nullptr, &blurVerticalPixel)) ||
        FAILED(device->CreatePixelShader(
          composite->GetBufferPointer(), composite->GetBufferSize(), nullptr, &compositePixel)) ||
        FAILED(device->CreatePixelShader(
          overlay->GetBufferPointer(), overlay->GetBufferSize(), nullptr, &overlayPixel)) ||
        !CreateConstantBuffer<GlyphConstants>(device.Get(), glyphConstants) ||
        !CreateConstantBuffer<PostConstants>(device.Get(), postConstants) ||
        !CreateConstantBuffer<OverlayConstants>(device.Get(), overlayConstants)) return false;

    D3D11_SAMPLER_DESC sampler{};
    sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler.MaxLOD = D3D11_FLOAT32_MAX;
    if (FAILED(device->CreateSamplerState(&sampler, &pointSampler))) return false;
    sampler.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    if (FAILED(device->CreateSamplerState(&sampler, &linearSampler))) return false;

    D3D11_BLEND_DESC blend{};
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    blend.RenderTarget[1] = blend.RenderTarget[0];
    if (FAILED(device->CreateBlendState(&blend, &additiveBlend))) return false;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    if (FAILED(device->CreateBlendState(&blend, &alphaBlend))) return false;
    blend.RenderTarget[0].BlendEnable = FALSE;
    blend.RenderTarget[1].BlendEnable = FALSE;
    return SUCCEEDED(device->CreateBlendState(&blend, &opaqueBlend));
  }

  [[nodiscard]] bool EnsureOverlay(
      const std::string_view text,
      const std::uint32_t outputWidth,
      const std::uint32_t outputHeight,
      const float dpiScale,
      const std::array<float, 3>& accent) {
    if (text.empty()) return false;
    if (overlayTexture != nullptr && overlayText == text && overlayOutputWidth == outputWidth &&
        overlayOutputHeight == outputHeight && overlayDpiScale == dpiScale &&
        overlayAccent == accent) return true;
    const auto bitmap = BuildIntroOverlayBitmap(text, outputWidth, outputHeight, dpiScale, accent);
    if (bitmap.width == 0 || bitmap.height == 0 || bitmap.bgra.empty()) return false;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = bitmap.width;
    description.Height = bitmap.height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_IMMUTABLE;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{};
    data.pSysMem = bitmap.bgra.data();
    data.SysMemPitch = bitmap.width * 4u;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> resource;
    if (FAILED(device->CreateTexture2D(&description, &data, &texture)) ||
        FAILED(device->CreateShaderResourceView(texture.Get(), nullptr, &resource))) return false;
    overlayTexture = std::move(texture);
    overlayResource = std::move(resource);
    overlayText = text;
    overlayAccent = accent;
    overlayOutputWidth = outputWidth;
    overlayOutputHeight = outputHeight;
    overlayDpiScale = dpiScale;
    overlayWidth = bitmap.width;
    overlayHeight = bitmap.height;
    overlayOriginX = bitmap.originX;
    overlayOriginY = bitmap.originY;
    return true;
  }

  [[nodiscard]] bool EnsureHud(
      const std::string_view text,
      const std::uint32_t outputWidth,
      const std::uint32_t outputHeight,
      const float dpiScale) {
    if (text.empty()) return false;
    if (hudTexture != nullptr && hudText == text && hudOutputWidth == outputWidth &&
        hudOutputHeight == outputHeight && hudDpiScale == dpiScale) return true;
    const auto bitmap = BuildHudOverlayBitmap(text, outputWidth, outputHeight, dpiScale);
    if (bitmap.width == 0 || bitmap.height == 0 || bitmap.bgra.empty()) return false;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = bitmap.width;
    description.Height = bitmap.height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_IMMUTABLE;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{};
    data.pSysMem = bitmap.bgra.data();
    data.SysMemPitch = bitmap.width * 4u;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> resource;
    if (FAILED(device->CreateTexture2D(&description, &data, &texture)) ||
        FAILED(device->CreateShaderResourceView(texture.Get(), nullptr, &resource))) return false;
    hudTexture = std::move(texture);
    hudResource = std::move(resource);
    hudText = text;
    hudOutputWidth = outputWidth;
    hudOutputHeight = outputHeight;
    hudDpiScale = dpiScale;
    hudWidth = bitmap.width;
    hudHeight = bitmap.height;
    hudOriginX = bitmap.originX;
    hudOriginY = bitmap.originY;
    return true;
  }

  [[nodiscard]] bool EnsureToast(
      const std::string_view text,
      const std::uint32_t outputWidth,
      const std::uint32_t outputHeight,
      const float dpiScale,
      const std::array<float, 3>& accent) {
    if (text.empty()) return false;
    if (toastTexture != nullptr && toastText == text && toastOutputWidth == outputWidth &&
        toastOutputHeight == outputHeight && toastDpiScale == dpiScale &&
        toastAccent == accent) return true;
    const auto bitmap = BuildToastOverlayBitmap(text, outputWidth, outputHeight, dpiScale, accent);
    if (bitmap.width == 0 || bitmap.height == 0 || bitmap.bgra.empty()) return false;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = bitmap.width;
    description.Height = bitmap.height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_IMMUTABLE;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{};
    data.pSysMem = bitmap.bgra.data();
    data.SysMemPitch = bitmap.width * 4u;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> resource;
    if (FAILED(device->CreateTexture2D(&description, &data, &texture)) ||
        FAILED(device->CreateShaderResourceView(texture.Get(), nullptr, &resource))) return false;
    toastTexture = std::move(texture);
    toastResource = std::move(resource);
    toastText = text;
    toastAccent = accent;
    toastOutputWidth = outputWidth;
    toastOutputHeight = outputHeight;
    toastDpiScale = dpiScale;
    toastWidth = bitmap.width;
    toastHeight = bitmap.height;
    toastOriginX = bitmap.originX;
    toastOriginY = bitmap.originY;
    return true;
  }

  [[nodiscard]] bool EnsureStateTexture(const std::uint32_t columns, const std::uint32_t rows) {
    if (stateTexture != nullptr && stateColumns == columns && stateRows == rows) return true;
    stateTexture.Reset();
    stateResource.Reset();
    boostTexture.Reset();
    boostResource.Reset();
    D3D11_TEXTURE2D_DESC description{};
    description.Width = columns;
    description.Height = rows;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DYNAMIC;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(device->CreateTexture2D(&description, nullptr, &stateTexture)) ||
        FAILED(device->CreateShaderResourceView(stateTexture.Get(), nullptr, &stateResource))) return false;
    description.Format = DXGI_FORMAT_R32_FLOAT;
    if (FAILED(device->CreateTexture2D(&description, nullptr, &boostTexture)) ||
        FAILED(device->CreateShaderResourceView(boostTexture.Get(), nullptr, &boostResource))) return false;
    stateColumns = columns;
    stateRows = rows;
    return true;
  }

  [[nodiscard]] bool UploadState(const RainLayerView& layer) {
    if (layer.columns == 0 || layer.rows == 0 ||
        layer.state.size() != static_cast<std::size_t>(layer.columns) * layer.rows * 4 ||
        !EnsureStateTexture(layer.columns, layer.rows)) return false;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(stateTexture.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    const std::size_t sourceStride = static_cast<std::size_t>(layer.columns) * 4;
    for (std::uint32_t row = 0; row < layer.rows; ++row) {
      std::memcpy(
        static_cast<std::uint8_t*>(mapped.pData) + static_cast<std::size_t>(row) * mapped.RowPitch,
        layer.state.data() + static_cast<std::size_t>(row) * sourceStride,
        sourceStride);
    }
    context->Unmap(stateTexture.Get(), 0);
    if (FAILED(context->Map(boostTexture.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    const bool hasBoost = layer.brightnessBoost.size() ==
      static_cast<std::size_t>(layer.columns) * layer.rows;
    const std::size_t boostStride = static_cast<std::size_t>(layer.columns) * sizeof(float);
    for (std::uint32_t row = 0; row < layer.rows; ++row) {
      auto* destination = static_cast<std::uint8_t*>(mapped.pData) +
        static_cast<std::size_t>(row) * mapped.RowPitch;
      if (hasBoost) {
        std::memcpy(
          destination,
          layer.brightnessBoost.data() + static_cast<std::size_t>(row) * layer.columns,
          boostStride);
      } else {
        std::memset(destination, 0, boostStride);
      }
    }
    context->Unmap(boostTexture.Get(), 0);
    return true;
  }

  [[nodiscard]] bool EnsureAtlas(const Controls& controls) {
    if (atlasTexture != nullptr && atlasMode == controls.glyphMode &&
        atlasFont == controls.glyphFont && atlasMirror == controls.mirror) return true;
    const auto bitmap = BuildGlyphAtlas(controls);
    if (bitmap.width == 0 || bitmap.height == 0 || bitmap.bgra.empty()) return false;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = bitmap.width;
    description.Height = bitmap.height;
    description.MipLevels = 0;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    description.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> resource;
    if (FAILED(device->CreateTexture2D(&description, nullptr, &texture)) ||
        FAILED(device->CreateShaderResourceView(texture.Get(), nullptr, &resource))) return false;
    context->UpdateSubresource(
      texture.Get(), 0, nullptr, bitmap.bgra.data(), bitmap.width * 4, 0);
    context->GenerateMips(resource.Get());
    atlasTexture = std::move(texture);
    atlasResource = std::move(resource);
    atlasMode = controls.glyphMode;
    atlasFont = controls.glyphFont;
    atlasMirror = controls.mirror;
    return true;
  }

  [[nodiscard]] bool EnsureTargets(const std::uint32_t nextWidth, const std::uint32_t nextHeight) {
    const bool complete = scene.texture != nullptr &&
      std::all_of(bloomA.begin(), bloomA.end(), [](const Target& target) {
        return target.texture != nullptr;
      }) && std::all_of(bloomB.begin(), bloomB.end(), [](const Target& target) {
        return target.texture != nullptr;
      });
    if (complete && sceneWidth == nextWidth && sceneHeight == nextHeight) return true;
    const auto targetWidth = std::max(1u, nextWidth);
    const auto targetHeight = std::max(1u, nextHeight);
    Target nextScene;
    std::array<Target, 3> nextBloomA;
    std::array<Target, 3> nextBloomB;
    if (!CreateTarget(
          device.Get(), targetWidth, targetHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, nextScene)) {
      return false;
    }
    std::uint32_t levelWidth = std::max(1u, targetWidth / 2);
    std::uint32_t levelHeight = std::max(1u, targetHeight / 2);
    for (std::size_t level = 0; level < nextBloomA.size(); ++level) {
      if (!CreateTarget(device.Get(), levelWidth, levelHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, nextBloomA[level]) ||
          !CreateTarget(device.Get(), levelWidth, levelHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, nextBloomB[level])) {
        return false;
      }
      levelWidth = std::max(1u, levelWidth / 2);
      levelHeight = std::max(1u, levelHeight / 2);
    }
    scene = std::move(nextScene);
    bloomA = std::move(nextBloomA);
    bloomB = std::move(nextBloomB);
    sceneWidth = targetWidth;
    sceneHeight = targetHeight;
    return true;
  }

  void DrawFullscreen(ID3D11PixelShader* shader) {
    context->VSSetShader(fullscreenVertex.Get(), nullptr, 0);
    context->PSSetShader(shader, nullptr, 0);
    context->IASetInputLayout(nullptr);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->Draw(3, 0);
  }

  void RunPass(
      ID3D11ShaderResourceView* input,
      Target& output,
      ID3D11PixelShader* shader,
      PostConstants constants) {
    UnbindResources(context.Get());
    ID3D11RenderTargetView* target = output.target.Get();
    context->OMSetRenderTargets(1, &target, nullptr);
    SetViewport(context.Get(), output.width, output.height);
    constants.sourceTexel[0] = input == nullptr ? 0.0f : 1.0f / static_cast<float>(output.width);
    constants.sourceTexel[1] = input == nullptr ? 0.0f : 1.0f / static_cast<float>(output.height);
    UpdateConstant(context.Get(), postConstants.Get(), constants);
    ID3D11Buffer* post = postConstants.Get();
    context->PSSetConstantBuffers(1, 1, &post);
    context->PSSetShaderResources(0, 1, &input);
    DrawFullscreen(shader);
  }
};

D3D11Renderer::D3D11Renderer() : impl_(std::make_unique<Impl>()) {}
D3D11Renderer::~D3D11Renderer() = default;
D3D11Renderer::D3D11Renderer(D3D11Renderer&&) noexcept = default;
D3D11Renderer& D3D11Renderer::operator=(D3D11Renderer&&) noexcept = default;

bool D3D11Renderer::Initialize(HWND window, const bool forceWarp) {
  RECT client{};
  GetClientRect(window, &client);
  const auto width = static_cast<std::uint32_t>(std::max<LONG>(1, client.right - client.left));
  const auto height = static_cast<std::uint32_t>(std::max<LONG>(1, client.bottom - client.top));
  const auto initialize = [window, width, height](Impl& implementation, const bool warp) {
    implementation.window = window;
    implementation.width = width;
    implementation.height = height;
    return implementation.CreateDevice(warp) &&
      implementation.CreateSwapChain() &&
      implementation.CreateShadersAndStates();
  };
  if (initialize(*impl_, forceWarp)) return true;
  if (forceWarp) return false;

  // Device creation can succeed on feature level 10 while this renderer's SM5 shaders cannot.
  // Tear the partial hardware graph down before creating a second swap chain for the same HWND.
  const bool captureEnabled = impl_->captureEnabled;
  impl_ = std::make_unique<Impl>();
  impl_->captureEnabled = captureEnabled;
  return initialize(*impl_, true);
}

bool D3D11Renderer::Resize(const std::uint32_t width, const std::uint32_t height) {
  if (width == 0 || height == 0 || impl_->swapChain == nullptr) return false;
  impl_->context->OMSetRenderTargets(0, nullptr, nullptr);
  impl_->backBufferTexture.Reset();
  impl_->backBufferTarget.Reset();
  impl_->captureTexture.Reset();
  impl_->width = width;
  impl_->height = height;
  impl_->lastError = impl_->swapChain->ResizeBuffers(
    0, width, height, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
  return SUCCEEDED(impl_->lastError) && impl_->CreateBackBuffer();
}

void D3D11Renderer::EnableFrameCapture(const bool enabled) noexcept {
  impl_->captureEnabled = enabled;
  if (!enabled) impl_->captureTexture.Reset();
}

bool D3D11Renderer::Render(
    const std::span<const RainLayerView> layers, const FrameParameters& parameters) {
  if (impl_->suspended || layers.empty() || impl_->backBufferTarget == nullptr ||
      !impl_->EnsureAtlas(parameters.controls)) return false;
  const auto sceneWidth = std::max(1u, static_cast<std::uint32_t>(
    std::floor(static_cast<float>(impl_->width) * std::clamp(parameters.adaptiveScale, 0.5f, 1.0f))));
  const auto sceneHeight = std::max(1u, static_cast<std::uint32_t>(
    std::floor(static_cast<float>(impl_->height) * std::clamp(parameters.adaptiveScale, 0.5f, 1.0f))));
  if (!impl_->EnsureTargets(sceneWidth, sceneHeight)) return false;

  constexpr float clearBlack[4]{0, 0, 0, 0};
  impl_->context->ClearRenderTargetView(impl_->scene.target.Get(), clearBlack);
  ID3D11RenderTargetView* sceneTarget = impl_->scene.target.Get();
  impl_->context->OMSetRenderTargets(1, &sceneTarget, nullptr);
  SetViewport(impl_->context.Get(), sceneWidth, sceneHeight);
  const float blendFactor[4]{1, 1, 1, 1};
  impl_->context->OMSetBlendState(impl_->additiveBlend.Get(), blendFactor, 0xffffffffu);

  PostConstants post{};
  post.outputSize[0] = static_cast<float>(impl_->width);
  post.outputSize[1] = static_cast<float>(impl_->height);
  post.glow = static_cast<float>(parameters.controls.glow);
  post.vignette = static_cast<float>(parameters.controls.vignette);
  post.scanlines = parameters.controls.scanlines ? 0.12f : 0.0f;
  post.bloomLevels = static_cast<float>(
    parameters.controls.quality == QualityTier::Low ? 1 :
    parameters.controls.quality == QualityTier::Medium ? 2 : 3);
  std::copy(parameters.palette.background.begin(), parameters.palette.background.end(), post.background);
  UpdateConstant(impl_->context.Get(), impl_->postConstants.Get(), post);
  ID3D11Buffer* postBuffer = impl_->postConstants.Get();
  impl_->context->PSSetConstantBuffers(1, 1, &postBuffer);

  ID3D11SamplerState* samplers[2]{impl_->pointSampler.Get(), impl_->linearSampler.Get()};
  impl_->context->PSSetSamplers(0, 2, samplers);
  for (const auto& layer : layers) {
    if (!impl_->UploadState(layer)) continue;
    GlyphConstants glyph{};
    glyph.sceneSize[0] = static_cast<float>(sceneWidth);
    glyph.sceneSize[1] = static_cast<float>(sceneHeight);
    glyph.virtualOrigin[0] = parameters.virtualOriginX;
    glyph.virtualOrigin[1] = parameters.virtualOriginY;
    glyph.logicalPerPixel[0] = parameters.logicalPerPixelX;
    glyph.logicalPerPixel[1] = parameters.logicalPerPixelY;
    glyph.gridSize[0] = static_cast<float>(layer.columns);
    glyph.gridSize[1] = static_cast<float>(layer.rows);
    glyph.cellPixels = parameters.cellPixels;
    glyph.laneOffset = layer.offsetCells;
    glyph.laneWeight = layer.weight;
    glyph.leadBrightness = static_cast<float>(parameters.controls.leadBrightness);
    glyph.goldSparkle = parameters.controls.preset == "gold" ? 0.18f : 0.0f;
    glyph.elapsedSeconds = parameters.elapsedSeconds;
    std::copy(parameters.palette.background.begin(), parameters.palette.background.end(), glyph.background);
    std::copy(parameters.palette.tail.begin(), parameters.palette.tail.end(), glyph.tail);
    std::copy(parameters.palette.body.begin(), parameters.palette.body.end(), glyph.body);
    std::copy(parameters.palette.bright.begin(), parameters.palette.bright.end(), glyph.bright);
    std::copy(parameters.palette.head.begin(), parameters.palette.head.end(), glyph.head);
    UpdateConstant(impl_->context.Get(), impl_->glyphConstants.Get(), glyph);
    ID3D11Buffer* glyphBuffer = impl_->glyphConstants.Get();
    impl_->context->PSSetConstantBuffers(0, 1, &glyphBuffer);
    ID3D11ShaderResourceView* resources[3]{
      impl_->stateResource.Get(), impl_->atlasResource.Get(), impl_->boostResource.Get()};
    impl_->context->PSSetShaderResources(0, 3, resources);
    impl_->DrawFullscreen(impl_->glyphPixel.Get());
  }

  impl_->context->OMSetBlendState(impl_->opaqueBlend.Get(), blendFactor, 0xffffffffu);
  ID3D11ShaderResourceView* bloomInput = impl_->scene.resource.Get();
  const auto levels = static_cast<std::size_t>(post.bloomLevels);
  for (std::size_t level = 0; level < levels; ++level) {
    impl_->RunPass(bloomInput, impl_->bloomA[level],
      level == 0 ? impl_->brightPassPixel.Get() : impl_->copyPixel.Get(), post);
    impl_->RunPass(impl_->bloomA[level].resource.Get(), impl_->bloomB[level],
      impl_->blurHorizontalPixel.Get(), post);
    impl_->RunPass(impl_->bloomB[level].resource.Get(), impl_->bloomA[level],
      impl_->blurVerticalPixel.Get(), post);
    bloomInput = impl_->bloomA[level].resource.Get();
  }

  impl_->context->OMSetBlendState(impl_->additiveBlend.Get(), blendFactor, 0xffffffffu);
  for (std::size_t level = levels; level > 1; --level) {
    impl_->RunPass(
      impl_->bloomA[level - 1].resource.Get(), impl_->bloomA[level - 2],
      impl_->copyPixel.Get(), post);
  }
  impl_->context->OMSetBlendState(impl_->opaqueBlend.Get(), blendFactor, 0xffffffffu);

  UnbindResources(impl_->context.Get());
  ID3D11RenderTargetView* backBuffer = impl_->backBufferTarget.Get();
  impl_->context->OMSetRenderTargets(1, &backBuffer, nullptr);
  SetViewport(impl_->context.Get(), impl_->width, impl_->height);
  UpdateConstant(impl_->context.Get(), impl_->postConstants.Get(), post);
  ID3D11ShaderResourceView* compositeResources[4]{
    impl_->scene.resource.Get(), impl_->bloomA[0].resource.Get(),
    impl_->bloomA[1].resource.Get(), impl_->bloomA[2].resource.Get()};
  impl_->context->PSSetShaderResources(0, 4, compositeResources);
  impl_->DrawFullscreen(impl_->compositePixel.Get());
  UnbindResources(impl_->context.Get());

  const float overlayDpiScale = std::clamp(
    1.0f / std::max(0.001f, parameters.logicalPerPixelX), 0.5f, 8.0f);
  if (parameters.overlayOpacity > 0.0f && impl_->EnsureOverlay(
        parameters.overlayText, impl_->width, impl_->height,
        overlayDpiScale, parameters.palette.bright)) {
    OverlayConstants overlay{};
    overlay.origin[0] = impl_->overlayOriginX;
    overlay.origin[1] = impl_->overlayOriginY;
    overlay.size[0] = static_cast<float>(impl_->overlayWidth);
    overlay.size[1] = static_cast<float>(impl_->overlayHeight);
    overlay.opacity = std::clamp(parameters.overlayOpacity, 0.0f, 1.0f);
    UpdateConstant(impl_->context.Get(), impl_->overlayConstants.Get(), overlay);
    ID3D11Buffer* overlayBuffer = impl_->overlayConstants.Get();
    impl_->context->PSSetConstantBuffers(2, 1, &overlayBuffer);
    ID3D11ShaderResourceView* overlayResource = impl_->overlayResource.Get();
    impl_->context->PSSetShaderResources(0, 1, &overlayResource);
    impl_->context->OMSetBlendState(impl_->alphaBlend.Get(), blendFactor, 0xffffffffu);
    impl_->DrawFullscreen(impl_->overlayPixel.Get());
    impl_->context->OMSetBlendState(impl_->opaqueBlend.Get(), blendFactor, 0xffffffffu);
    UnbindResources(impl_->context.Get());
  }

  if (parameters.toastOpacity > 0.0f && impl_->EnsureToast(
        parameters.toastText, impl_->width, impl_->height,
        overlayDpiScale, parameters.palette.bright)) {
    OverlayConstants overlay{};
    overlay.origin[0] = impl_->toastOriginX;
    overlay.origin[1] = impl_->toastOriginY + parameters.toastOffsetDips * overlayDpiScale;
    overlay.size[0] = static_cast<float>(impl_->toastWidth);
    overlay.size[1] = static_cast<float>(impl_->toastHeight);
    overlay.opacity = std::clamp(parameters.toastOpacity, 0.0f, 1.0f);
    UpdateConstant(impl_->context.Get(), impl_->overlayConstants.Get(), overlay);
    ID3D11Buffer* overlayBuffer = impl_->overlayConstants.Get();
    impl_->context->PSSetConstantBuffers(2, 1, &overlayBuffer);
    ID3D11ShaderResourceView* overlayResource = impl_->toastResource.Get();
    impl_->context->PSSetShaderResources(0, 1, &overlayResource);
    impl_->context->OMSetBlendState(impl_->alphaBlend.Get(), blendFactor, 0xffffffffu);
    impl_->DrawFullscreen(impl_->overlayPixel.Get());
    impl_->context->OMSetBlendState(impl_->opaqueBlend.Get(), blendFactor, 0xffffffffu);
    UnbindResources(impl_->context.Get());
  }

  if (!parameters.hudText.empty() && impl_->EnsureHud(
        parameters.hudText, impl_->width, impl_->height, overlayDpiScale)) {
    OverlayConstants overlay{};
    overlay.origin[0] = impl_->hudOriginX;
    overlay.origin[1] = impl_->hudOriginY;
    overlay.size[0] = static_cast<float>(impl_->hudWidth);
    overlay.size[1] = static_cast<float>(impl_->hudHeight);
    overlay.opacity = 1.0f;
    UpdateConstant(impl_->context.Get(), impl_->overlayConstants.Get(), overlay);
    ID3D11Buffer* overlayBuffer = impl_->overlayConstants.Get();
    impl_->context->PSSetConstantBuffers(2, 1, &overlayBuffer);
    ID3D11ShaderResourceView* overlayResource = impl_->hudResource.Get();
    impl_->context->PSSetShaderResources(0, 1, &overlayResource);
    impl_->context->OMSetBlendState(impl_->alphaBlend.Get(), blendFactor, 0xffffffffu);
    impl_->DrawFullscreen(impl_->overlayPixel.Get());
    impl_->context->OMSetBlendState(impl_->opaqueBlend.Get(), blendFactor, 0xffffffffu);
    UnbindResources(impl_->context.Get());
  }

  // A flip-discard Present rotates the swap-chain buffers. Preserve the completed frame before
  // presenting so the deterministic capture tool never reads an undefined post-Present buffer.
  if (impl_->captureTexture != nullptr && impl_->backBufferTexture != nullptr) {
    impl_->context->CopyResource(impl_->captureTexture.Get(), impl_->backBufferTexture.Get());
  }

  const bool nonBlocking = parameters.presentationMode == PresentationMode::NonBlocking;
  impl_->lastError = impl_->swapChain->Present(
    nonBlocking ? 0u : 1u,
    nonBlocking ? DXGI_PRESENT_DO_NOT_WAIT : 0u);
  if (impl_->lastError == DXGI_ERROR_WAS_STILL_DRAWING && nonBlocking) {
    // DWM still owns the previous frame. Dropping this presentation prevents one slow display
    // from serially throttling every other swap chain in a multi-monitor session.
    impl_->lastError = S_OK;
    return true;
  }
  if (impl_->lastError == DXGI_STATUS_OCCLUDED) return true;
  return SUCCEEDED(impl_->lastError);
}

bool D3D11Renderer::CapturePng(const std::filesystem::path& output) const {
  if (impl_->captureTexture == nullptr || impl_->device == nullptr || impl_->context == nullptr) return false;
  ID3D11Texture2D* source = impl_->captureTexture.Get();
  D3D11_TEXTURE2D_DESC description{};
  source->GetDesc(&description);
  description.Usage = D3D11_USAGE_STAGING;
  description.BindFlags = 0;
  description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  description.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(impl_->device->CreateTexture2D(&description, nullptr, &staging))) return false;
  impl_->context->CopyResource(staging.Get(), source);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(impl_->context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  bool success = SUCCEEDED(CoCreateInstance(
      CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) &&
    SUCCEEDED(factory->CreateStream(&stream)) &&
    SUCCEEDED(stream->InitializeFromFilename(output.c_str(), GENERIC_WRITE)) &&
    SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) &&
    SUCCEEDED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) &&
    SUCCEEDED(encoder->CreateNewFrame(&frame, &properties)) &&
    SUCCEEDED(frame->Initialize(properties.Get())) &&
    SUCCEEDED(frame->SetSize(description.Width, description.Height));
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  success = success && SUCCEEDED(frame->SetPixelFormat(&format)) && IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA) &&
    SUCCEEDED(frame->WritePixels(
      description.Height,
      mapped.RowPitch,
      mapped.RowPitch * description.Height,
      static_cast<BYTE*>(mapped.pData))) &&
    SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
  impl_->context->Unmap(staging.Get(), 0);
  return success;
}

HRESULT D3D11Renderer::ProbeOcclusion() noexcept {
  if (impl_->swapChain == nullptr || impl_->suspended) return impl_->lastError;
  impl_->lastError = impl_->swapChain->Present(0, DXGI_PRESENT_TEST);
  return impl_->lastError;
}

void D3D11Renderer::Suspend() noexcept { impl_->suspended = true; }
void D3D11Renderer::Resume() noexcept { impl_->suspended = false; }
DeviceKind D3D11Renderer::Kind() const noexcept { return impl_->kind; }
HRESULT D3D11Renderer::LastError() const noexcept { return impl_->lastError; }

std::wstring D3D11Renderer::DeviceDiagnostic() const {
  std::wostringstream stream;
  stream << (impl_->kind == DeviceKind::Hardware ? L"D3D11 hardware" : L"D3D11 WARP")
         << L" (HRESULT 0x" << std::hex << static_cast<unsigned long>(impl_->lastError) << L")";
  return stream.str();
}

}  // namespace matrixcode::render
