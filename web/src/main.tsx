import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

const root = document.getElementById("root");
// 挂载点缺失时明确报错：静默什么也不做会表现为"白屏 + 无报错"，最难查。
if (!root) throw new Error("index.html 缺少 #root 挂载点");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
