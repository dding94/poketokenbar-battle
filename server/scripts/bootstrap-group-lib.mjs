// Testable parts of bootstrap-group.mjs. No Node APIs: fetch is injected.

export const USAGE =
  "usage: OPERATOR_SECRET is read from the environment (read -rs OPERATOR_SECRET; export OPERATOR_SECRET)\n" +
  "  node server/scripts/bootstrap-group.mjs <baseUrl> <groupName> <hostNickname>";

/**
 * @param {string[]} argv
 * @param {Record<string, string | undefined>} env
 * @returns {{ baseUrl: string, groupName: string, nickname: string, operatorSecret: string }}
 */
export function parseArgs(argv, env) {
  return { baseUrl: "", groupName: "", nickname: "", operatorSecret: "" };
}

/**
 * @param {{ baseUrl: string, groupName: string, nickname: string, operatorSecret: string }} options
 * @returns {{ url: string, init: RequestInit }}
 */
export function buildRequest(options) {
  return { url: "", init: {} };
}

/** @param {unknown} body */
export function formatSuccess(body) {
  return "";
}

/**
 * @param {number} status
 * @param {unknown} body
 */
export function formatFailure(status, body) {
  return "";
}

/**
 * @param {{ baseUrl: string, groupName: string, nickname: string, operatorSecret: string }} options
 * @param {typeof fetch} fetchImpl
 * @returns {Promise<{ ok: boolean, text: string }>}
 */
export async function bootstrapGroup(options, fetchImpl) {
  return { ok: false, text: "" };
}
