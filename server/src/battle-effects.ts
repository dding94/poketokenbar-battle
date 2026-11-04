import type { Battle } from "./battle-store";
export interface BattleEffect { recipients: string[]; groupId?: string; message: Record<string, unknown> }
export function battleChanged(b: Battle): BattleEffect { return { recipients: [b.p1, b.p2], message: { type: "battle_changed", battleId: b.battleId, state: b.state, revision: b.revision, roundSeq: b.roundSeq, deadline: b.state === "RUNNING" ? b.relay.current?.deadline ?? null : null } }; }
