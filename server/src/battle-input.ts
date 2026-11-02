import { ApiError, type Body } from "./http";
import type { ErrorCode } from "./contract";

export const RULES_VERSION = "gen9-notera-noitems-v1";
export const POLICY_VERSION = "auto-v2";
export const RELAY_VERSION = "relay-v1";
export type Side = "p1" | "p2";
export type BattleMode = "manual" | "auto";
export interface Snapshot {
  instanceId: string;
  set: { speciesNum: number; form: string | null; level: number; gender: "male" | "female" | "genderless"; nature: string; ability: string; moves: string[]; ivs: Record<string, number>; shiny: boolean };
  public: { speciesNum: number; species: string; level: number; types: string[]; stats: Record<string, number> & { hp: number } };
  hp: number;
}
export type BattleAction = "create" | "update" | "accept" | "confirm" | "decline" | "cancel" | "ready" | "start" | "choices" | "advance" | "report" | "rematch";
export interface BattleInput {
  requestId?: string; targetTrainerId?: string; mode?: BattleMode; snapshot?: Snapshot; revision?: number;
  connectionId?: string; engineHash?: string; rulesVersion?: string; policyVersion?: string; readyToken?: string;
  roundSeq?: number; choice?: string; processedRoundSeq?: number; report?: Report;
}
export interface Report {
  readyToken: string; engineHash: string; terminalSeq: number; winner: Side | "draw";
  logHash: string; journalHash: string; finalHp: { p1: number; p2: number };
}
const ID = /^[A-Za-z0-9_-]+$/;
const SLUG = /^[a-z0-9-]+$/;
const HASH = /^[0-9a-f]{64}$/;
const TYPES = new Set("Normal Fire Water Electric Grass Ice Fighting Poison Ground Flying Psychic Bug Rock Ghost Dragon Dark Steel Fairy".split(" "));
function reject(code: ErrorCode): never { throw new ApiError(code); }
function object(value: unknown, keys: string[], optional: string[] = [], code: ErrorCode = "bad_request"): Body {
  if (!value || typeof value !== "object" || Array.isArray(value)) return reject(code);
  const obj = value as Body;
  if (keys.some(k => !Object.hasOwn(obj, k)) || Object.keys(obj).some(k => !keys.includes(k) && !optional.includes(k))) return reject(code);
  return obj;
}
function integer(value: unknown, min: number, max: number, code: ErrorCode = "bad_request"): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) return reject(code);
  return value;
}
function string(value: unknown, max: number, pattern?: RegExp, code: ErrorCode = "bad_request"): string {
  if (typeof value !== "string" || value.length < 1 || value.length > max || (pattern && !pattern.test(value))) return reject(code);
  return value;
}
export function parseSnapshot(value: unknown): Snapshot {
  const code = "invalid_snapshot";
  const snap = object(value, ["instanceId", "set", "public", "hp"], [], code);
  const set = object(snap.set, ["speciesNum", "level", "gender", "nature", "ability", "moves", "ivs", "shiny"], ["form"], code);
  const pub = object(snap.public, ["speciesNum", "species", "level", "types", "stats"], [], code);
  const ivs = object(set.ivs, ["hp", "attack", "defense", "special-attack", "special-defense", "speed"], [], code);
  const stats = object(pub.stats, ["hp", "atk", "def", "spa", "spd", "spe"], [], code);
  const speciesNum = integer(set.speciesNum, 1, 649, code), level = integer(set.level, 1, 100, code);
  if (pub.speciesNum !== speciesNum || pub.level !== level) return reject(code);
  if (!["male", "female", "genderless"].includes(set.gender as string) || typeof set.shiny !== "boolean") return reject(code);
  if (!Array.isArray(set.moves) || set.moves.length < 1 || set.moves.length > 4) return reject(code);
  if (!Array.isArray(pub.types) || pub.types.length < 1 || pub.types.length > 2 || new Set(pub.types).size !== pub.types.length || pub.types.some(t => typeof t !== "string" || !TYPES.has(t))) return reject(code);
  const species = string(pub.species, 80, undefined, code);
  if (/[\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}\u2800]/u.test(species)) return reject(code);
  const parsedStats = Object.fromEntries(Object.entries(stats).map(([k, v]) => [k, integer(v, 1, 999, code)])) as Snapshot["public"]["stats"];
  const hp = integer(snap.hp, 0, parsedStats.hp, code);
  if (hp === 0) return reject("fainted");
  return {
    instanceId: string(snap.instanceId, 128, ID, code),
    set: { speciesNum, form: set.form === undefined || set.form === null ? null : string(set.form, 64, SLUG, code), level, gender: set.gender as Snapshot["set"]["gender"], nature: string(set.nature, 64, SLUG, code), ability: string(set.ability, 64, SLUG, code), moves: set.moves.map(v => string(v, 64, SLUG, code)), ivs: Object.fromEntries(Object.entries(ivs).map(([k, v]) => [k, integer(v, 0, 31, code)])), shiny: set.shiny },
    public: { speciesNum, species, level, types: pub.types as string[], stats: parsedStats }, hp,
  };
}
export function parseBattleInput(action: BattleAction, value: unknown): BattleInput {
  const keys: Record<BattleAction, string[]> = {
    create: ["requestId", "targetTrainerId", "mode", "snapshot"], update: ["revision", "snapshot"], accept: ["revision", "snapshot"],
    confirm: ["revision"], decline: ["revision"], cancel: ["revision"],
    ready: ["revision", "connectionId", "engineHash", "rulesVersion", "policyVersion"], start: ["revision", "connectionId", "readyToken", "engineHash"],
    choices: ["roundSeq", "choice"], advance: ["processedRoundSeq"], rematch: ["requestId", "snapshot"],
    report: ["readyToken", "engineHash", "terminalSeq", "winner", "logHash", "journalHash", "finalHp"],
  };
  const b = object(value, keys[action]); const out: BattleInput = {};
  if ("snapshot" in b) out.snapshot = parseSnapshot(b.snapshot);
  if ("revision" in b) out.revision = integer(b.revision, 1, Number.MAX_SAFE_INTEGER);
  if ("requestId" in b) out.requestId = string(b.requestId, 64, ID);
  if ("targetTrainerId" in b) out.targetTrainerId = string(b.targetTrainerId, 128, ID);
  if ("mode" in b) { if (b.mode !== "manual" && b.mode !== "auto") return reject("bad_request"); out.mode = b.mode; }
  if ("connectionId" in b) out.connectionId = string(b.connectionId, 128, ID);
  if ("readyToken" in b) out.readyToken = string(b.readyToken, 128, ID);
  if ("engineHash" in b) out.engineHash = string(b.engineHash, 64, HASH);
  if ("rulesVersion" in b) out.rulesVersion = string(b.rulesVersion, 64, SLUG);
  if ("policyVersion" in b) out.policyVersion = string(b.policyVersion, 64, SLUG);
  if ("roundSeq" in b) out.roundSeq = integer(b.roundSeq, 1, 200);
  if ("processedRoundSeq" in b) out.processedRoundSeq = integer(b.processedRoundSeq, 1, 200);
  if ("choice" in b) { if (typeof b.choice !== "string" || !/^move [1-4]$/.test(b.choice)) return reject("invalid_choice"); out.choice = b.choice; }
  if (action === "report") {
    if (b.winner !== "p1" && b.winner !== "p2" && b.winner !== "draw") return reject("bad_request");
    const hp = object(b.finalHp, ["p1", "p2"]);
    out.report = { readyToken: out.readyToken!, engineHash: out.engineHash!, terminalSeq: integer(b.terminalSeq, 1, 200), winner: b.winner, logHash: string(b.logHash, 64, HASH), journalHash: string(b.journalHash, 64, HASH), finalHp: { p1: integer(hp.p1, 0, 999), p2: integer(hp.p2, 0, 999) } };
  }
  return out;
}
/** Stable object-key order for retries; array order remains meaningful. */
export function canonical(value: unknown): string {
  const sort = (v: any): any => Array.isArray(v) ? v.map(sort) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sort(v[k])])) : v;
  return JSON.stringify(sort(value));
}
