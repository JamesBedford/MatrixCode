import "./styles.css";
import { mountMatrixRain } from "./app.ts";
import { startBench } from "./bench/benchHarness.ts";

const container = document.getElementById("app");
if (container) {
  // `?bench` swaps in the deterministic benchmark harness; everything else mounts the
  // live rain. The harness is inert (never executed) on the normal path.
  if (new URLSearchParams(location.search).has("bench")) {
    void startBench(container, new URLSearchParams(location.search));
  } else {
    void mountMatrixRain(container);
  }
}
