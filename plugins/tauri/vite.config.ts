import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// https://vitejs.dev/config/
export default defineConfig(async () => ({
  plugins: [svelte()],

  // Tauri expects a fixed port; fail fast if it's in use
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      // Tell vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },

  envPrefix: ["VITE_", "TAURI_ENV_*"],

  build: {
    // Tauri supports Chromium (blink); target modern ES + Chrome 105+
    target: process.env.TAURI_ENV_PLATFORM === "windows"
      ? "chrome105"
      : process.env.TAURI_ENV_PLATFORM === "darwin"
        ? ["es2021", "safari13"]
        : ["es2021", "chrome105"],

    // Don't minify in debug builds for easier DevTools inspection
    minify: !process.env.TAURI_ENV_DEBUG ? "esbuild" : false,

    // Produce sourcemaps in debug builds
    sourcemap: !!process.env.TAURI_ENV_DEBUG,
  },
}));
