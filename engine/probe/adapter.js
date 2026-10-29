// PTB engine probe adapter. Bundled with esbuild into a single IIFE exposing globalThis.PTBEngine.
// No Node built-ins, no timers, no TextEncoder. Everything synchronous.
import {Battle, BattleStreams, State} from '@pkmn/sim';

const FORMAT = 'gen5customgame';
const TURN_CAP = 200;

// ---------- policy PRNG (independent of the battle PRNG) ----------
function mulberry32(a) {
  a >>>= 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------- SHA-256 (pure JS, UTF-8) ----------
function utf8(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
      const d = str.charCodeAt(i + 1);
      if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
    }
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
function sha256(str) {
  const bytes = utf8(str);
  const len = bytes.length;
  bytes.push(0x80);
  while ((bytes.length % 64) !== 56) bytes.push(0);
  const bitLenHi = Math.floor(len / 0x20000000), bitLenLo = (len * 8) >>> 0;
  bytes.push((bitLenHi >>> 24) & 255, (bitLenHi >>> 16) & 255, (bitLenHi >>> 8) & 255, bitLenHi & 255,
    (bitLenLo >>> 24) & 255, (bitLenLo >>> 16) & 255, (bitLenLo >>> 8) & 255, bitLenLo & 255);
  const H = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const W = new Uint32Array(64);
  for (let off = 0; off < bytes.length; off += 64) {
    for (let i = 0; i < 16; i++) {
      W[i] = (bytes[off + 4 * i] << 24) | (bytes[off + 4 * i + 1] << 16) | (bytes[off + 4 * i + 2] << 8) | bytes[off + 4 * i + 3];
    }
    for (let i = 16; i < 64; i++) {
      const w15 = W[i - 15], w2 = W[i - 2];
      const s0 = ((w15 >>> 7) | (w15 << 25)) ^ ((w15 >>> 18) | (w15 << 14)) ^ (w15 >>> 3);
      const s1 = ((w2 >>> 17) | (w2 << 15)) ^ ((w2 >>> 19) | (w2 << 13)) ^ (w2 >>> 10);
      W[i] = (W[i - 16] + s0 + W[i - 7] + s1) >>> 0;
    }
    let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (let i = 0; i < 64; i++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + W[i]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] += a; H[1] += b; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
  }
  let hex = '';
  for (let i = 0; i < 8; i++) hex += (H[i] >>> 0).toString(16).padStart(8, '0');
  return hex;
}

// ---------- helpers ----------
function normalizeLog(log) {
  // Drop wall-clock timestamp lines (`|t:|<unix seconds>`), added in Battle constructor and nextTurn().
  return log.filter(line => !line.startsWith('|t:|'));
}

// Deterministic choice policy reading only the request object (what a client would get as |request| JSON).
function pickChoice(req, rand) {
  if (!req || req.wait) return null;
  if (req.teamPreview) return 'team 1';
  if (req.forceSwitch) return 'pass'; // 1v1: no bench; Showdown normally doesn't ask, but be safe
  const active = req.active && req.active[0];
  if (!active) return 'default';
  const legal = [];
  active.moves.forEach((m, i) => { if (!m.disabled) legal.push(i + 1); });
  if (!legal.length) return 'default';
  return 'move ' + legal[Math.floor(rand() * legal.length)];
}

function makeBattle(spec) {
  return new Battle({
    formatid: FORMAT,
    seed: spec.seed,
    p1: {name: 'p1', team: spec.p1},
    p2: {name: 'p2', team: spec.p2},
  });
}

function stepBattle(battle, rands, stats) {
  // One decision round: each side with a pending request submits its choice.
  if (battle.turn > TURN_CAP && !battle.ended) {
    battle.forceWin(); // no side -> tie; records `>forcetie` in inputLog
    return;
  }
  for (let i = 0; i < 2; i++) {
    const side = battle.sides[i];
    // Round-trip through JSON so the policy sees exactly what a client would receive.
    const req = side.activeRequest ? JSON.parse(JSON.stringify(side.activeRequest)) : null;
    const choice = pickChoice(req, rands[i]);
    if (choice === null) continue;
    if (stats && req && req.active && req.active[0] && req.active[0].moves.length === 1 &&
        (req.active[0].moves[0].id === 'recharge' || req.active[0].moves[0].id === 'struggle' || req.active[0].trapped)) {
      stats.forced++;
    }
    if (!battle.choose(side.id, choice)) {
      if (stats) { stats.choiceErrors++; if (!stats.firstError) stats.firstError = 'T' + battle.turn + ' ' + side.id + ' ' + choice + ': ' + side.choice.error + ' req=' + JSON.stringify(req.active && req.active[0]); }
      battle.choose(side.id, 'default');
    }
    if (battle.ended) return;
  }
}

function finish(battle, extra) {
  const log = normalizeLog(battle.log);
  const text = log.join('\n');
  return Object.assign({
    winner: battle.winner === undefined ? null : battle.winner, // 'p1' | 'p2' | '' (tie)
    turns: battle.turn,
    ended: battle.ended,
    hash: sha256(text),
    lines: log.length,
    log: text,
    inputLog: battle.inputLog.join('\n'),
  }, extra || {});
}

function runBattle(spec, opts) {
  opts = opts || {};
  const battle = makeBattle(spec);
  const rands = [mulberry32(spec.policySeed), mulberry32((spec.policySeed ^ 0x9E3779B9) >>> 0)];
  const stats = {forced: 0, choiceErrors: 0, rounds: 0};
  let resumed = battle;
  let serializedAt = -1;
  while (!resumed.ended) {
    stepBattle(resumed, rands, stats);
    stats.rounds++;
    if (stats.rounds > 5000) throw new Error('runaway battle');
    if (opts.serializeAtTurn && serializedAt < 0 && resumed.turn === opts.serializeAtTurn && !resumed.ended) {
      // State round-trip mid-battle: serialize to JSON string, rebuild, keep playing on the copy.
      const json = JSON.stringify(State.serializeBattle(resumed));
      resumed = State.deserializeBattle(json);
      serializedAt = resumed.turn;
    }
  }
  return finish(resumed, {forced: stats.forced, choiceErrors: stats.choiceErrors, firstError: stats.firstError, serializedAt});
}

// Rebuild purely from an input log (the reconnect/resync path), using Showdown's own line handler.
function replay(inputLog) {
  const stream = new BattleStreams.BattleStream({noCatch: true});
  stream._writeLines(inputLog);
  return finish(stream.battle);
}

function runCorpus(corpusJSON, opts) {
  opts = opts || {};
  const corpus = typeof corpusJSON === 'string' ? JSON.parse(corpusJSON) : corpusJSON;
  const now = opts.now || (() => 0);
  const out = [];
  const tStart = now();
  let tFirst = 0;
  for (let i = 0; i < corpus.length; i++) {
    const spec = corpus[i];
    let r;
    try {
      r = runBattle(spec);
    } catch (e) {
      r = {error: String(e && e.stack || e), hash: 'ERROR', log: '', inputLog: ''};
    }
    if (i === 0) tFirst = now();
    const rec = {id: spec.id, winner: r.winner, turns: r.turns, hash: r.hash, lines: r.lines,
      forced: r.forced, choiceErrors: r.choiceErrors, firstChoiceError: r.firstError, error: r.error};
    if (opts.withLogs) { rec.log = r.log; rec.inputLog = r.inputLog; }
    if (opts.replay && !r.error) {
      try {
        const rp = replay(r.inputLog);
        rec.replayHash = rp.hash;
        rec.replayOk = rp.hash === r.hash && rp.log === r.log;
      } catch (e) { rec.replayOk = false; rec.replayError = String(e); }
    }
    if (opts.serializeAtTurn && !r.error) {
      try {
        const sr = runBattle(spec, {serializeAtTurn: opts.serializeAtTurn});
        rec.stateHash = sr.hash;
        rec.stateOk = sr.hash === r.hash;
        rec.serializedAt = sr.serializedAt;
      } catch (e) { rec.stateOk = false; rec.stateError = String(e); }
    }
    out.push(rec);
  }
  const tEnd = now();
  return {results: out, timing: {firstBattleMs: tFirst - tStart, restMs: tEnd - tFirst, n: corpus.length}};
}

globalThis.PTBEngine = {runBattle, replay, runCorpus, sha256, normalizeLog, FORMAT, TURN_CAP};
