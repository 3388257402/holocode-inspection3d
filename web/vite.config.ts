import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// 为什么不用 vite 的 proxy 代替 CORS：
// 真机上 Unity 也直连 Go，后端本来就必须允许跨域；前端再走 proxy 等于把"跨域"这件事
// 藏起来，换一台机器/换一个端口就复现成"白屏"。让浏览器直连，问题在开发期就暴露。
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, host: true },
});
