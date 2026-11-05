// Runs in plain Node (node --test), because workerd cannot host a local server for fetch to follow.
// The scripts send the operator secret in a request body and access keys in a header. A redirect
// answered by anything on the way must never carry them to a second address.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { bootstrapGroup, parseArgs } from "./bootstrap-group-lib.mjs";

const SECRET = "fake-operator-secret-for-redirect-tests";

/** @param {(req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse) => void} handler */
async function listen(handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(undefined)));
  const address = /** @type {import("node:net").AddressInfo} */ (server.address());
  return { server, url: `http://127.0.0.1:${address.port}` };
}

/** @type {{ server: import("node:http").Server, url: string }} */
let elsewhere;
/** @type {string[]} */
let received = [];

before(async () => {
  elsewhere = await listen((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      received.push(`${req.method} ${req.url} ${req.headers.authorization ?? ""} ${body}`);
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
});
after(() => elsewhere.server.close());

/** @param {number} status */
async function redirecting(status) {
  received = [];
  return listen((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(status, { location: `${elsewhere.url}${req.url}` }).end());
  });
}

for (const status of [301, 302, 307, 308]) {
  test(`the group bootstrap refuses a ${status} and sends the secret nowhere else`, async () => {
    const origin = await redirecting(status);
    try {
      const options = parseArgs([origin.url, "Arena", "Host"], { OPERATOR_SECRET: SECRET });
      const result = await bootstrapGroup(options, fetch);
      assert.equal(result.ok, false);
      assert.deepEqual(received, []);
      assert.ok(!result.text.includes(SECRET));
    } finally {
      origin.server.close();
    }
  });
}

test("the measurement script refuses a redirect and sends the secret nowhere else", async () => {
  const origin = await redirecting(307);
  try {
    const script = fileURLToPath(new URL("./measure.mjs", import.meta.url));
    const child = spawn(process.execPath, [script, origin.url, "--members", "1", "--hold-minutes", "0", "--churn", "0"], {
      env: { ...process.env, OPERATOR_SECRET: SECRET },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    await new Promise((resolve) => child.on("close", resolve));
    assert.deepEqual(received, []);
    assert.ok(!output.includes(SECRET));
  } finally {
    origin.server.close();
  }
});
