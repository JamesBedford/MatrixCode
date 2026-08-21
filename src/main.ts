import "./styles.css";
import { mountMatrixRain } from "./app.ts";
import { bootstrapNativeHost, installNativeLifecycle } from "./platform/nativeHost.ts";
import { createWallpaperEngineBridge } from "./platform/wallpaperEngine.ts";

// Wallpaper Engine invokes this global listener shortly after page creation, so install it before
// native bootstrap or app mounting. Ordinary browsers mount immediately and keep their normal stores.
const wallpaperBridge = createWallpaperEngineBridge();

async function start(): Promise<void> {
  const wallpaperHosted = wallpaperBridge.isLikelyHosted();
  if (wallpaperHosted) await wallpaperBridge.waitForInitialProperties(1500);
  else bootstrapNativeHost();

  const container = document.getElementById("app");
  if (!container) return;
  const handle = await mountMatrixRain(
    container,
    undefined,
    wallpaperHosted ? { wallpaperEngine: wallpaperBridge } : undefined,
  );
  if (!wallpaperHosted) installNativeLifecycle(handle.setActive);
}

void start();
