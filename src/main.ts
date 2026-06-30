import "./styles.css";
import { mountMatrixRain } from "./app.ts";

const container = document.getElementById("app");
if (container) {
  void mountMatrixRain(container);
}
