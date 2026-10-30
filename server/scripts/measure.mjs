#!/usr/bin/env node
// PR 05 measurement load for a deployed league (Appendix C). Node 24, no dependencies.
//
//   OPERATOR_SECRET=… node server/scripts/measure.mjs <baseUrl> [--members 30] [--hold-minutes 10]
//     [--churn 5] [--redeploy-wait-minutes 0] [--ping-seconds 30] [--cleanup]
//
// Creates one measurement group, joins N fake members (mNN@measure.invalid), opens one
// WebSocket per member that sends `ping` every --ping-seconds, then holds, churns sockets to
// produce presence traffic, and optionally waits for a redeploy while reconnecting with the
// Appendix C backoff. Prints a JSON summary on stdout; progress goes to stderr.
//
// Keys, codes, the operator secret and emails stay in memory: they are never printed, written
// to a file or put in a URL.

import process from "node:process";
import {
  backoffDelayMs,
  memberEmail,
  nextAttempt,
  parseArgs,
  reconnectDecision,
  summarize,
} from "./measure-lib.mjs";

const POLLING_AFTER_FAILURES = 3;
const POLLING_RETRY_MS = 10 * 60_000;
const HTTP_TIMEOUT_MS = 15_000;
const CHURN_GAP_MS = 2_000;
const SETTLE_MS = 3_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const progress = (text) => process.stderr.write(`[measure] ${text}\n`);

function increment(counter, key, by = 1) {
  counter[key] = (counter[key] ?? 0) + by;
}

class Stats {
  phase = "setup";
  http = {}; // route -> { latencies: [], statuses: {} }
  errors = {}; // kind -> count
  connects = { attempts: 0, opened: 0, latencies: [] };
  messages = {}; // type -> count, presence split by online/offline
  pings = { sent: 0, pongs: 0, rtt: [] };
  closes = {}; // phase -> code -> count
  unexpectedDrops = []; // { phase, code, connectedForMs }
  reconnects = []; // { phase, attempt, delayMs }
  outages = []; // { phase, durationMs | null, attempts }
  pollingFallbacks = 0;
  stopped = {}; // close code -> members that stopped reconnecting

  route(name) {
    this.http[name] ??= { latencies: [], statuses: {} };
    return this.http[name];
  }
}

const stats = new Stats();

async function api(baseUrl, method, path, { key, body } = {}) {
  const headers = { accept: "application/json" };
  if (key) headers.authorization = `Bearer ${key}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  const started = performance.now();
  const route = stats.route(`${method} ${path}`);
  try {
    const res = await fetch(`${baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
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
}

class Member {
  socket = null;
  openedAt = 0;
  attempt = 0;
  failures = 0;
  intentionalClose = false;
  stopped = false;
  pingTimer = null;
  pingsInFlight = [];
  outage = null; // { startedAt, phase, attempts }

  constructor(index, trainerId, accessKey, options) {
    this.index = index;
    this.trainerId = trainerId;
    this.accessKey = accessKey;
    this.options = options;
  }

  get open() {
    return this.socket !== null && this.socket.readyState === WebSocket.OPEN;
  }

  connect() {
    if (this.stopped) return Promise.resolve(false);
    const url = `${this.options.baseUrl.replace(/^http/, "ws")}/v1/connect`;
    const started = performance.now();
    stats.connects.attempts += 1;
    this.intentionalClose = false;
    return new Promise((resolve) => {
      let settled = false;
      const settle = (value) => {
        if (!settled) {
          settled = true;
          resolve(value);
        }
      };
      const ws = new WebSocket(url, { headers: { authorization: `Bearer ${this.accessKey}` } });
      this.socket = ws;
      ws.addEventListener("open", () => {
        stats.connects.opened += 1;
        stats.connects.latencies.push(Math.round(performance.now() - started));
        this.openedAt = Date.now();
        this.failures = 0;
        if (this.outage) {
          stats.outages.push({
            phase: this.outage.phase,
            durationMs: Date.now() - this.outage.startedAt,
            attempts: this.outage.attempts,
          });
          this.outage = null;
        }
        this.startPings();
        settle(true);
      });
      ws.addEventListener("message", (event) => this.onMessage(event.data));
      ws.addEventListener("error", () => increment(stats.errors, "ws_error"));
      ws.addEventListener("close", (event) => {
        this.stopPings();
        const wasOpen = this.openedAt > 0;
        const connectedForMs = wasOpen ? Date.now() - this.openedAt : 0;
        this.openedAt = 0;
        stats.closes[stats.phase] ??= {};
        increment(stats.closes[stats.phase], String(event.code));
        settle(false);
        if (this.intentionalClose) return;
        if (wasOpen) stats.unexpectedDrops.push({ phase: stats.phase, code: event.code, connectedForMs });
        else this.failures += 1;
        this.scheduleReconnect(event.code, connectedForMs);
      });
    });
  }

  scheduleReconnect(code, connectedForMs) {
    if (reconnectDecision(code) === "stop") {
      this.stopped = true;
      increment(stats.stopped, String(code));
      return;
    }
    this.outage ??= { startedAt: Date.now(), phase: stats.phase, attempts: 0 };
    this.outage.attempts += 1;
    this.attempt = nextAttempt(this.attempt, connectedForMs);
    let delayMs = backoffDelayMs(this.attempt, Math.random);
    if (this.failures >= POLLING_AFTER_FAILURES) {
      // The app would poll now and retry the socket every ten minutes.
      if (this.failures === POLLING_AFTER_FAILURES) stats.pollingFallbacks += 1;
      delayMs = POLLING_RETRY_MS;
    }
    stats.reconnects.push({ phase: stats.phase, attempt: this.attempt, delayMs });
    setTimeout(() => void this.connect(), delayMs).unref?.();
  }

  onMessage(data) {
    if (data === "pong") {
      stats.pings.pongs += 1;
      const sentAt = this.pingsInFlight.shift();
      if (sentAt !== undefined) stats.pings.rtt.push(Math.round(performance.now() - sentAt));
      return;
    }
    let message = null;
    try {
      message = JSON.parse(String(data));
    } catch {
      increment(stats.messages, "unparseable");
      return;
    }
    const type = typeof message?.type === "string" ? message.type : "unknown";
    if (type === "presence") increment(stats.messages, message.online ? "presence_online" : "presence_offline");
    else increment(stats.messages, type);
  }

  startPings() {
    this.stopPings();
    this.pingTimer = setInterval(() => {
      if (!this.open) return;
      this.pingsInFlight.push(performance.now());
      stats.pings.sent += 1;
      this.socket.send("ping");
    }, this.options.pingSeconds * 1000);
  }

  stopPings() {
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = null;
    this.pingsInFlight = [];
  }

  close() {
    this.intentionalClose = true;
    this.stopPings();
    try {
      this.socket?.close(1000, "measure");
    } catch {
      // Already closed.
    }
  }
}

async function setup(options, secret) {
  const created = await api(options.baseUrl, "POST", "/v1/groups", {
    body: {
      operatorSecret: secret,
      groupName: `measure ${new Date().toISOString().slice(0, 16)}`,
      displayEmail: "host@measure.invalid",
    },
  });
  if (created.status !== 200) throw new Error(`group creation failed with HTTP ${created.status}`);
  const host = { key: created.json.accessKey, groupId: created.json.group.groupId };

  const invite = await api(options.baseUrl, "POST", "/v1/invites", {
    key: host.key,
    body: { ttlSeconds: 3600, maxUses: options.members },
  });
  if (invite.status !== 200) throw new Error(`invite failed with HTTP ${invite.status}`);

  const members = [];
  for (let i = 1; i <= options.members; i += 1) {
    const joined = await api(options.baseUrl, "POST", "/v1/join", {
      body: { inviteCode: invite.json.inviteCode, displayEmail: memberEmail(i) },
    });
    if (joined.status !== 200) throw new Error(`join ${i} failed with HTTP ${joined.status}`);
    members.push(new Member(i, joined.json.trainer.trainerId, joined.json.accessKey, options));
  }
  // Leave no usable invite behind.
  await api(options.baseUrl, "POST", "/v1/invites/revoke", { key: host.key, body: { inviteId: invite.json.invite.inviteId } });
  return { host, members };
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
    progress("OPERATOR_SECRET is not set in the environment");
    process.exitCode = 2;
    return;
  }

  const startedAt = new Date();
  const summary = { startedAt: startedAt.toISOString(), options, completed: false };
  let members = [];
  let host = null;
  let interrupted = false;
  process.once("SIGINT", () => {
    interrupted = true;
    progress("interrupted; finishing the current phase");
  });
  const wait = async (ms) => {
    const until = Date.now() + ms;
    while (!interrupted && Date.now() < until) await sleep(Math.min(1000, until - Date.now()));
  };

  try {
    progress(`creating a measurement group and ${options.members} members`);
    ({ host, members } = await setup(options, secret));
    summary.groupId = host.groupId;

    stats.phase = "connect";
    progress("opening sockets");
    await Promise.all(members.map((m) => m.connect()));
    await sleep(SETTLE_MS);

    stats.phase = "hold";
    progress(`holding for ${options.holdMinutes} min`);
    await wait(options.holdMinutes * 60_000);

    if (!interrupted && options.churn > 0) {
      stats.phase = "churn";
      progress(`dropping and reopening ${options.churn} sockets`);
      const before = { ...stats.messages };
      for (const member of members.slice(0, options.churn)) {
        member.close();
        await sleep(CHURN_GAP_MS);
        await member.connect();
        await sleep(CHURN_GAP_MS);
      }
      await sleep(SETTLE_MS);
      const others = members.filter((m) => m.open).length - 1;
      summary.churn = {
        expectedPresencePerSide: options.churn * Math.max(0, others),
        presenceOnline: (stats.messages.presence_online ?? 0) - (before.presence_online ?? 0),
        presenceOffline: (stats.messages.presence_offline ?? 0) - (before.presence_offline ?? 0),
      };
    }

    if (!interrupted && options.redeployWaitMinutes > 0) {
      stats.phase = "redeploy";
      progress(`waiting ${options.redeployWaitMinutes} min: redeploy the Worker now`);
      await wait(options.redeployWaitMinutes * 60_000);
      summary.redeploy = {
        stillDisconnected: members.filter((m) => !m.open && !m.stopped).length,
      };
    }
    summary.completed = !interrupted;
  } catch (error) {
    summary.setupError = error.message;
    process.exitCode = 1;
  } finally {
    stats.phase = "cleanup";
    for (const member of members) member.close();
    if (options.cleanup && members.length > 0) {
      progress("members leaving the group");
      let left = 0;
      for (const member of members) if ((await api(options.baseUrl, "POST", "/v1/leave", { key: member.accessKey })).status === 200) left += 1;
      summary.cleanup = { membersLeft: left, note: "the host stays (host_must_transfer); the group remains" };
    }
  }

  summary.finishedAt = new Date().toISOString();
  summary.durationS = Math.round((Date.now() - startedAt.getTime()) / 1000);
  summary.membersOpenAtEnd = members.filter((m) => m.open).length;
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
  // Timers of members that are still reconnecting must not keep the process alive.
  process.exit(process.exitCode ?? 0);
}

await main();
