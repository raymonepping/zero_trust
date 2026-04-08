import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const vitePort = Number.parseInt(env.VITE_PORT || "5173", 10);

  return {
    plugins: [react()],
    server: {
      host: true,
      port: Number.isNaN(vitePort) ? 5173 : vitePort,
      proxy: {
        // Auth token proxy — no timeout needed, Keycloak responds fast
        "/api/auth": {
          target: env.VITE_API_URL || "http://backend:3000",
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api/, ""),
          configure: (proxy) => {
            proxy.on("error", (err, _req, res) => {
              const body = JSON.stringify({ error: "backend_unavailable", detail: err.message });
              res.writeHead(503, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
              res.end(body);
            });
          },
        },
        // Streaming endpoint — no timeout (Ollama can take many seconds per response)
        "/api/ask": {
          target: env.VITE_API_URL || "http://backend:3000",
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api/, ""),
          configure: (proxy) => {
            proxy.on("error", (err, _req, res) => {
              const body = JSON.stringify({ error: "backend_unavailable", detail: err.message });
              res.writeHead(503, {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body),
              });
              res.end(body);
            });
          },
        },
        // All other API routes — short timeout so backend-down errors surface quickly
        "/api": {
          target: env.VITE_API_URL || "http://backend:3000",
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api/, ""),
          proxyTimeout: 5000,
          timeout: 5000,
          configure: (proxy) => {
            proxy.on("error", (err, _req, res) => {
              const body = JSON.stringify({ error: "backend_unavailable", detail: err.message });
              res.writeHead(503, {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body),
              });
              res.end(body);
            });
          },
        },
      },
    },
  };
});
