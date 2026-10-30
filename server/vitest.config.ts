import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Obviously fake, low-entropy test values. Real secrets never live in the repo.
const TEST_OPERATOR_SECRET = "operator-test-value-xxxxxxxxxxxxxxxxxxxx";
const TEST_CODE_PEPPER = "pepper-test-value-xxxxxxxx";

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
    include: ["test/**/*.test.ts"],
  },
});
