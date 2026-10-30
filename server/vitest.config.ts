import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Obviously fake, low-entropy test values. Real secrets never live in the repo.
const TEST_OPERATOR_SECRET = "operator-test-value-xxxxxxxxxxxxxxxxxxxx";
const TEST_CODE_PEPPER = "pepper-test-value-xxxxxxxx";

const WEBSOCKET_TESTS = "test/ws/**/*.test.ts";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          OPERATOR_SECRET: TEST_OPERATOR_SECRET,
          CODE_PEPPER: TEST_CODE_PEPPER,
        },
      },
    }),
  ],
  test: {
    projects: [
      {
        // HTTP API and pure tests: one Miniflare (and League storage) per test file.
        extends: true,
        test: { name: "api", include: ["test/**/*.test.ts"], exclude: [WEBSOCKET_TESTS], sequence: { groupOrder: 0 } },
      },
      {
        // WebSocket tests. The Workers Vitest integration does not support WebSockets with
        // Durable Objects under per-file storage isolation; its documented workaround is
        // shared storage, one file at a time. Every test here builds its own group, and each
        // file closes its sockets in afterAll (see test/ws/socket.ts).
        extends: true,
        test: { name: "ws", include: [WEBSOCKET_TESTS], isolate: false, fileParallelism: false, sequence: { groupOrder: 1 } },
      },
    ],
  },
});
