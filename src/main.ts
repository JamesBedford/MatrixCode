import "./styles.css";
import { mountMatrixRain } from "./app.ts";
import { bootstrapNativeHost, installNativeLifecycle } from "./platform/nativeHost.ts";

bootstrapNativeHost();
const container = document.getElementById("app");
if (container) {
  void mountMatrixRain(container).then((handle) => {
    installNativeLifecycle(handle.setActive);
  });
}
