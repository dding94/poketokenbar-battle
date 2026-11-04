import { defineConfig } from "vitest/config";
import base from "./vitest.config.ts";
// Explicit measurements only: not skipped tests in the normal CI suite.
export default defineConfig({
  ...base,
  test: { include: ["measure/**/*.test.ts"], isolate: false, fileParallelism: false, testTimeout: 180_000 },
});
