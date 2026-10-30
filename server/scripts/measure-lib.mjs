// Pure parts of measure.mjs. Not implemented yet.

export const BACKOFF_CAP_MS = 0;
export const STABLE_MS = 0;

/** @param {number} _attempt */
export function backoffCeilingMs(_attempt) {
  return 0;
}

/** @param {number} _attempt @param {() => number} _random */
export function backoffDelayMs(_attempt, _random) {
  return -1;
}

/** @param {number} _attempt @param {number} _connectedMs */
export function nextAttempt(_attempt, _connectedMs) {
  return 0;
}

/** @param {number} _code */
export function reconnectDecision(_code) {
  return "";
}

/** @param {string[]} _argv @returns {Record<string, unknown>} */
export function parseArgs(_argv) {
  return {};
}

/** @param {number} _index */
export function memberEmail(_index) {
  return "";
}

/** @param {number[]} _values @returns {Record<string, number>} */
export function summarize(_values) {
  return {};
}
