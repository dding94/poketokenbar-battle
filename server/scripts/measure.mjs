#!/usr/bin/env node
// PR 05 measurement load for a deployed league (Appendix C). Node 24, no dependencies.
//
//   read -rs OPERATOR_SECRET; export OPERATOR_SECRET
//   node server/scripts/measure.mjs <baseUrl> [--members 30] [--hold-minutes 10]
//     [--churn 5] [--redeploy-wait-minutes 0] [--ping-seconds 30] [--cleanup]
//
// Creates one measurement group, joins N fake members (mNN@measure.invalid, N ≤ 99), opens one
// WebSocket per member that sends `ping` every --ping-seconds, then holds, churns sockets to
// produce presence traffic, and optionally waits for a redeploy while reconnecting with the
// Appendix C backoff. Prints a JSON summary on stdout; progress goes to stderr.
//
// Keys, codes, the operator secret and emails stay in memory: they are never printed, written
// to a file or put in a URL. The summary names the target by the Worker's first host label
// only, never the account's workers.dev subdomain.

import process from "node:process";
import {
  Member,
  Stats,
  increment,
  parseArgs,
  releaseSetup,
  revokeInvite,
  runSetup,
  summarize,
  summaryOptions,
} from "./measure-lib.mjs";

const HTTP_TIMEOUT_MS = 15_000;
const CHURN_GAP_MS = 2_000;
const SETTLE_MS = 3_000;

const progress = (text) => process.stderr.write(`[measure] ${text}\n`);

const stats = new Stats();

/** @type {import("./measure-lib.mjs").MemberEnv} */
const memberEnv = {
  WebSocket,
  now: () => performance.now(),
  random: Math.random,
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
  setInterval: (fn, ms) => setInterval(fn, ms),
  clearInterval: (id) => clearInterval(id),
};

function apiFor(baseUrl) {
  return async (method, path, { key, body, signal } = {}) => {
    const headers = { accept: "application/json" };
    if (key) headers.authorization = `Bearer ${key}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const started = performance.now();
    const route = stats.route(`${method} ${path}`);
    const timeout = AbortSignal.timeout(HTTP_TIMEOUT_MS);
    try {
      const res = await fetch(`${baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: signal ? AbortSignal.any([timeout, signal]) : timeout,
      });
      route.latencies.push(Math.round(performance.now() - started));
      increment(route.statuses, String(res.status));
      const json = await res.json().catch(() => null);
      if (!res.ok) increment(stats.errors, `http_${res.status}_${json?.error?.code ?? "unknown"}`);
      return { status: res.status, json };
    } catch (error) {
      increment(stats.errors, `network_${error?.name ?? "error"}`);
      return { status: 0, json: null };
    }
  };
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    progress(`usage error: ${error.message}`);
    process.exitCode = 2;
    return;
  }
  const secret = process.env.OPERATOR_SECRET;
  if (!secret) {
    progress("OPERATOR_SECRET is not set (read -rs OPERATOR_SECRET; export OPERATOR_SECRET)");
    process.exitCode = 2;
    return;
  }
  const api = apiFor(options.baseUrl);

  // The first Ctrl-C stops setup, connecting and every wait, then cleans up and prints the
  // summary. A second one exits at once.
  const interrupt = new AbortController();
  const interrupted = () => interrupt.signal.aborted;
  process.on("SIGINT", () => {
    if (interrupted()) process.exit(130);
    progress("interrupted; cleaning up (Ctrl-C again to exit now)");
    interrupt.abort();
  });
  const untilInterrupted = new Promise((resolve) => interrupt.signal.addEventListener("abort", resolve, { once: true }));
  const wait = (ms) => {
    let timer;
    return Promise.race([new Promise((resolve) => (timer = setTimeout(resolve, ms))), untilInterrupted]).finally(() => clearTimeout(timer));
  };

  const startedAt = new Date();
  const summary = { startedAt: startedAt.toISOString(), options: summaryOptions(options), completed: false };
  let members = [];
  let state = null;

  try {
    progress(`creating a measurement group and ${options.members} members`);
    state = await runSetup(api, options, secret, interrupt.signal, () => new Date().toISOString());
    if (state.host) summary.groupId = state.host.groupId;
    if (state.error) {
      summary.setupError = state.error;
      process.exitCode = 1;
      return;
    }
    members = state.joined.map((joined) => new Member(joined.accessKey, options, stats, memberEnv));

    stats.phase = "connect";
    progress("opening sockets");
    // Each connect settles on open, close or its own timeout.
    await Promise.race([Promise.all(members.map((m) => m.connect())), untilInterrupted]);
    if (!interrupted()) await wait(SETTLE_MS);

    if (!interrupted()) {
      stats.phase = "hold";
      progress(`holding for ${options.holdMinutes} min`);
      await wait(options.holdMinutes * 60_000);
    }

    if (!interrupted() && options.churn > 0) {
      stats.phase = "churn";
      progress(`dropping and reopening ${options.churn} sockets`);
      const before = { ...stats.messages };
      for (const member of members.slice(0, options.churn)) {
        if (interrupted()) break;
        member.close();
        await wait(CHURN_GAP_MS);
        if (interrupted()) break;
        await Promise.race([member.connect(), untilInterrupted]);
        await wait(CHURN_GAP_MS);
      }
      await wait(SETTLE_MS);
      const others = members.filter((m) => m.open).length - 1;
      summary.churn = {
        expectedPresencePerSide: options.churn * Math.max(0, others),
        presenceOnline: (stats.messages.presence_online ?? 0) - (before.presence_online ?? 0),
        presenceOffline: (stats.messages.presence_offline ?? 0) - (before.presence_offline ?? 0),
      };
    }

    if (!interrupted() && options.redeployWaitMinutes > 0) {
      stats.phase = "redeploy";
      progress(`waiting ${options.redeployWaitMinutes} min: redeploy the Worker now`);
      await wait(options.redeployWaitMinutes * 60_000);
      summary.redeploy = {
        stillDisconnected: members.filter((m) => !m.open && !m.stopped).length,
      };
    }
    summary.completed = !interrupted();
  } catch (error) {
    // Only the error's kind: a message could quote a response value.
    summary.failure = error?.name ?? "error";
    process.exitCode = 1;
  } finally {
    stats.phase = "cleanup";
    summary.interrupted = interrupted();
    if (summary.interrupted) process.exitCode = 130;
    summary.membersOpenAtEnd = members.filter((m) => m.open).length;
    for (const member of members) member.close();
    if (state !== null) {
      if (state.error !== null || options.cleanup) {
        // A partial setup is always undone; a finished one only with --cleanup.
        progress("revoking the invite and making the members leave");
        summary.cleanup = { ...(await releaseSetup(api, state)), note: "the host stays (host_must_transfer); the group remains" };
      } else if (state.inviteId !== null) {
        summary.cleanup = { inviteRevoked: await revokeInvite(api, state).catch(() => false) };
      }
    }
    printSummary(summary, startedAt);
  }
}

function printSummary(summary, startedAt) {
  summary.finishedAt = new Date().toISOString();
  summary.durationS = Math.round((Date.now() - startedAt.getTime()) / 1000);
  summary.http = Object.fromEntries(
    Object.entries(stats.http).map(([route, r]) => [route, { statuses: r.statuses, latencyMs: summarize(r.latencies) }]),
  );
  summary.connects = { attempts: stats.connects.attempts, opened: stats.connects.opened, latencyMs: summarize(stats.connects.latencies) };
  summary.messages = stats.messages;
  summary.pings = { sent: stats.pings.sent, pongs: stats.pings.pongs, rttMs: summarize(stats.pings.rtt) };
  summary.closesByPhase = stats.closes;
  summary.unexpectedDrops = {
    count: stats.unexpectedDrops.length,
    byPhaseAndCode: stats.unexpectedDrops.reduce((acc, d) => (increment(acc, `${d.phase}:${d.code}`), acc), {}),
    connectedForMs: summarize(stats.unexpectedDrops.map((d) => d.connectedForMs)),
  };
  summary.reconnects = {
    scheduled: stats.reconnects.length,
    delayMs: summarize(stats.reconnects.map((r) => r.delayMs)),
    redeployDelayMs: summarize(stats.reconnects.filter((r) => r.phase === "redeploy").map((r) => r.delayMs)),
    outages: stats.outages.length,
    outageMs: summarize(stats.outages.map((o) => o.durationMs)),
    redeployOutageMs: summarize(stats.outages.filter((o) => o.phase === "redeploy").map((o) => o.durationMs)),
    attemptsPerOutage: summarize(stats.outages.map((o) => o.attempts)),
    pollingFallbacks: stats.pollingFallbacks,
    stoppedByCode: stats.stopped,
  };
  summary.errors = stats.errors;
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
}

await main();
// Timers of members that are still reconnecting must not keep the process alive.
process.exit(process.exitCode ?? 0);
