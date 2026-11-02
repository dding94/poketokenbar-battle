import type { BattleAction, Side } from "./battle-input";
import { PRESTART, type BattleState } from "./battle-store";
/** Explicit room transition table. Readiness additionally checks consent, versions and sessions. */
export function permitsRoomAction(action: BattleAction, state: BattleState, side: Side): boolean {
  switch (action) {
    case "update": return state === "PENDING" && side === "p1";
    case "accept": case "decline": return state === "PENDING" && side === "p2";
    case "confirm": return state === "ACCEPTED" && side === "p1";
    case "cancel": return PRESTART.has(state);
    case "ready": return state === "ACCEPTED" || state === "READY";
    case "start": return state === "READY" || state === "RUNNING";
    default: return false;
  }
}
