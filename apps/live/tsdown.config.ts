import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["src/start.ts", "src/fork-pages/rebase.worker.ts"],
  outDir: "dist",
  format: ["esm"],
  dts: false,
  clean: true,
  sourcemap: false,
  exports: false,
});
